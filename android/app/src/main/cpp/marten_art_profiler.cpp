#include <jni.h>
#include <jvmti.h>
#include <unistd.h>
#include <sys/syscall.h>
#include <fcntl.h>
#include "proc_thread_counter.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <algorithm>
#include <atomic>
#include <map>
#include <sstream>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace {
jvmtiEnv* tooling = nullptr;
constexpr size_t kMaxMethods = 8192, kMaxFunctions = 4096, kMaxStacks = 256;
constexpr jint kDepth = 64, kMaxThreads = 512;
using Counter = ThreadCpuCounter;
struct CounterFile {
    int fd = -1;
    ~CounterFile() { if (fd >= 0) close(fd); }
    CounterFile() = default;
    CounterFile(const CounterFile&) = delete;
    CounterFile& operator=(const CounterFile&) = delete;
};
// Only the sampling thread owns these. Entries are retired after every poll
// when their exact task disappears; no thread-exit callback touches a descriptor.
std::unordered_map<int, CounterFile> counter_files;
struct Cost { uint64_t flat = 0, inclusive = 0; };
std::unordered_map<int, Counter> previous;
std::unordered_map<jmethodID, std::string> methods;
std::map<std::string, Cost> functions;
std::map<std::string, uint64_t> stacks;
uint64_t observed_us = 0, samples = 0, polls = 0, unmapped = 0, ended = 0;
uint64_t unresolved_us = 0, dropped = 0, cpu_read_failures = 0;
long hz = 100;
std::atomic<uint64_t> thread_starts{0}, thread_exits{0};

// The callback runs on the starting thread. Store an integer, never a pthread_t
// or a heap pointer that a concurrent ThreadEnd could invalidate.
void JNICALL thread_start(jvmtiEnv* env, JNIEnv*, jthread thread) {
    env->SetThreadLocalStorage(thread, reinterpret_cast<void*>(static_cast<intptr_t>(gettid())));
    thread_starts.fetch_add(1, std::memory_order_relaxed);
}
void JNICALL thread_end(jvmtiEnv*, JNIEnv*, jthread) {
    thread_exits.fetch_add(1, std::memory_order_relaxed);
}

bool read_counter(int tid, Counter& result) {
    char path[80], buffer[2048];
    auto& file = counter_files.try_emplace(tid).first->second;
    if (file.fd < 0) {
        std::snprintf(path, sizeof(path), "/proc/self/task/%d/stat", tid);
        file.fd = open(path, O_RDONLY | O_CLOEXEC);
    }
    if (file.fd < 0) return false;
    const ssize_t size = pread(file.fd, buffer, sizeof(buffer) - 1, 0);
    if (size <= 0 || size == sizeof(buffer) - 1) return false;
    buffer[size] = 0;
    return parse_thread_cpu_counter(buffer, result);
}

std::string symbol(JNIEnv* jni, jmethodID method) {
    const auto found = methods.find(method);
    if (found != methods.end()) return found->second;
    char* name = nullptr;
    char* signature = nullptr;
    jclass klass = nullptr;
    std::string value = "unknown_java_frame";
    if (tooling->GetMethodName(method, &name, nullptr, nullptr) == JVMTI_ERROR_NONE &&
        tooling->GetMethodDeclaringClass(method, &klass) == JVMTI_ERROR_NONE &&
        tooling->GetClassSignature(klass, &signature, nullptr) == JVMTI_ERROR_NONE) {
        value = signature;
        if (!value.empty() && value.front() == 'L') value.erase(0, 1);
        if (!value.empty() && value.back() == ';') value.pop_back();
        value += "::";
        value += name;
        for (char& c : value) {
            if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                  (c >= '0' && c <= '9') || std::string("_/$:<>()-").find(c) != std::string::npos)) c = '_';
        }
        if (value.size() > 240) value.resize(240);
    }
    if (name) tooling->Deallocate(reinterpret_cast<unsigned char*>(name));
    if (signature) tooling->Deallocate(reinterpret_cast<unsigned char*>(signature));
    if (klass) jni->DeleteLocalRef(klass);
    if (methods.size() < kMaxMethods) methods.emplace(method, value);
    return value;
}

void poll(JNIEnv* jni) {
    if (!tooling) return;
    jthread* threads = nullptr;
    jint count = 0;
    if (tooling->GetAllThreads(&count, &threads) != JVMTI_ERROR_NONE) { ended++; return; }
    polls++;
    std::unordered_map<int, Counter> next;
    const int self = gettid();
    for (jint i = 0; i < count; ++i) {
        if (i >= kMaxThreads) { dropped++; jni->DeleteLocalRef(threads[i]); continue; }
        void* id = nullptr;
        if (tooling->GetThreadLocalStorage(threads[i], &id) != JVMTI_ERROR_NONE) {
            ended++; jni->DeleteLocalRef(threads[i]); continue;
        }
        const int tid = static_cast<int>(reinterpret_cast<intptr_t>(id));
        if (tid <= 0) { unmapped++; jni->DeleteLocalRef(threads[i]); continue; }
        Counter current;
        if (!read_counter(tid, current)) { cpu_read_failures++; jni->DeleteLocalRef(threads[i]); continue; }
        next[tid] = current;
        const auto old = previous.find(tid);
        if (tid == self || old == previous.end() || old->second.start != current.start || current.ticks <= old->second.ticks) {
            jni->DeleteLocalRef(threads[i]); continue;
        }
        const uint64_t cpu_us = (current.ticks - old->second.ticks) * 1000000ULL / static_cast<uint64_t>(hz);
        observed_us += cpu_us;
        jvmtiFrameInfo frames[kDepth];
        jint depth = 0;
        if (tooling->GetStackTrace(threads[i], 0, kDepth, frames, &depth) != JVMTI_ERROR_NONE || depth == 0) {
            unresolved_us += cpu_us; jni->DeleteLocalRef(threads[i]); continue;
        }
        // Recheck generation after the checkpoint; never charge a reused tid.
        Counter after;
        if (!read_counter(tid, after) || after.start != current.start) {
            unresolved_us += cpu_us; ended++; jni->DeleteLocalRef(threads[i]); continue;
        }
        samples++;
        std::unordered_set<std::string> seen;
        std::string chain;
        for (jint f = 0; f < depth; ++f) {
            const std::string name = symbol(jni, frames[f].method);
            auto entry = functions.find(name);
            if (entry == functions.end() && functions.size() >= kMaxFunctions) { dropped++; continue; }
            Cost& cost = functions[name];
            if (f == 0) cost.flat += cpu_us;
            if (seen.emplace(name).second) cost.inclusive += cpu_us;
            if (f < 12) { if (!chain.empty()) chain += " <- "; chain += name; }
        }
        if (stacks.size() < kMaxStacks || stacks.count(chain)) stacks[chain] += cpu_us;
        else dropped++;
        // Each thread's declaring-class locals are discarded, even on long runs.
        jni->DeleteLocalRef(threads[i]);
    }
    tooling->Deallocate(reinterpret_cast<unsigned char*>(threads));
    for (auto file = counter_files.begin(); file != counter_files.end();) {
        if (!next.count(file->first)) file = counter_files.erase(file);
        else ++file;
    }
    for (const auto& [tid, unused] : previous) {
        (void)unused;
        if (!next.count(tid)) ended++;
    }
    previous.swap(next);
}

std::string snapshot() {
    std::ostringstream out;
    out << "ART_PROFILE outcome=" << (samples ? "ready" : "no_samples")
        << " clock=thread_cpu_kernel records=" << samples << " total_observed_us=" << observed_us
        << " format=jvmti_kernel_cpu scope=sampled_java_and_native_entry_frames\n";
    out << "ART_COVERAGE polls=" << polls
        << " thread_starts=" << thread_starts.exchange(0, std::memory_order_relaxed)
        << " thread_exits=" << thread_exits.exchange(0, std::memory_order_relaxed) << " unmapped_thread_observations=" << unmapped
        << " ended_thread_observations=" << ended << " cpu_read_failures=" << cpu_read_failures
        << " unresolved_cpu_us=" << unresolved_us << " dropped_entries=" << dropped
        << " cpu_tick_us=" << 1000000 / hz
        << " attribution=interval_cpu_weighted_stack native_unattached=unavailable\n";
    for (const auto& [name, cost] : functions)
        out << "FUNCTION flat_us=" << cost.flat << " inclusive_us=" << cost.inclusive << " symbol=" << name << '\n';
    for (const auto& [chain, cost] : stacks)
        out << "STACK value_us=" << cost << " frames=" << chain << '\n';
    functions.clear(); stacks.clear();
    observed_us = samples = polls = unmapped = ended = unresolved_us = dropped = cpu_read_failures = 0;
    return out.str();
}
} // namespace

extern "C" JNIEXPORT jint JNICALL Agent_OnAttach(JavaVM* vm, char*, void*) {
    if (tooling) return JNI_OK;
    jvmtiEnv* env = nullptr;
    if (vm->GetEnv(reinterpret_cast<void**>(&env), JVMTI_VERSION_1_2) != JNI_OK || !env) return JNI_ERR;
    jvmtiEventCallbacks callbacks{};
    callbacks.ThreadStart = thread_start;
    callbacks.ThreadEnd = thread_end;
    if (env->SetEventCallbacks(&callbacks, sizeof(callbacks)) != JVMTI_ERROR_NONE ||
        env->SetEventNotificationMode(JVMTI_ENABLE, JVMTI_EVENT_THREAD_START, nullptr) != JVMTI_ERROR_NONE ||
        env->SetEventNotificationMode(JVMTI_ENABLE, JVMTI_EVENT_THREAD_END, nullptr) != JVMTI_ERROR_NONE) return JNI_ERR;
    hz = sysconf(_SC_CLK_TCK);
    if (hz <= 0) hz = 100;
    // The attaching main thread predates ThreadStart notifications.
    jthread current = nullptr;
    if (env->GetCurrentThread(&current) == JVMTI_ERROR_NONE) {
        env->SetThreadLocalStorage(current, reinterpret_cast<void*>(static_cast<intptr_t>(gettid())));
        JNIEnv* jni = nullptr;
        if (vm->GetEnv(reinterpret_cast<void**>(&jni), JNI_VERSION_1_6) == JNI_OK) jni->DeleteLocalRef(current);
    }
    tooling = env;
    return JNI_OK;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_app_marten_client_bg_ArtEnergyProfiler_nativeReady(JNIEnv*, jobject) { return tooling != nullptr; }

extern "C" JNIEXPORT void JNICALL
Java_app_marten_client_bg_ArtEnergyProfiler_nativePoll(JNIEnv* jni, jobject) {
    // GetMethodDeclaringClass produces JNI locals; bound them per sampling call.
    if (jni->PushLocalFrame(1024) != JNI_OK) return;
    poll(jni);
    jni->PopLocalFrame(nullptr);
}

extern "C" JNIEXPORT jstring JNICALL
Java_app_marten_client_bg_ArtEnergyProfiler_nativeSnapshot(JNIEnv* jni, jobject) {
    const auto text = snapshot();
    return jni->NewStringUTF(text.c_str());
}
