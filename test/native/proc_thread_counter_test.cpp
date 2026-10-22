#include "proc_thread_counter.h"
#include <cassert>
#include <string>

std::string stat(const std::string& name, const std::string& user, const std::string& system, const std::string& start) {
    std::string result = "123 (" + name + ") S";
    for (int field = 4; field <= 22; ++field) {
        result += " ";
        result += field == 14 ? user : field == 15 ? system : field == 22 ? start : "0";
    }
    return result + " 4096 100\n";
}
int main() {
    ThreadCpuCounter counter{1, 2};
    assert(parse_thread_cpu_counter(stat("worker (nested) name)", "17", "23", "901").c_str(), counter));
    assert(counter.start == 901 && counter.ticks == 40);
    assert(parse_thread_cpu_counter(stat("zero CPU", "0", "0", "902").c_str(), counter));
    assert(counter.start == 902 && counter.ticks == 0);
    const auto valid = counter;
    for (const auto& invalid : {
        stat("bad", "-1", "3", "903"), stat("bad", "3x", "3", "903"),
        stat("bad", "18446744073709551616", "0", "903"),
        stat("bad", "18446744073709551615", "1", "903"),
        stat("bad", "0", "0", "0"), std::string("123 (truncated) S 0"), std::string("missing comm")}) {
        assert(!parse_thread_cpu_counter(invalid.c_str(), counter));
        assert(counter.start == valid.start && counter.ticks == valid.ticks);
    }
    assert(parse_thread_cpu_counter(stat("reused tid", "0", "1", "999").c_str(), counter));
    assert(counter.start == 999 && counter.ticks == 1);
}
