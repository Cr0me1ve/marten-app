#pragma once

#include <charconv>
#include <cstdint>
#include <cstring>

struct ThreadCpuCounter { uint64_t start = 0, ticks = 0; };

// /proc comm may contain spaces and ')'. Parse only numeric stat fields,
// without allocating strings or constructing a stream for every sampled thread.
inline bool parse_thread_cpu_counter(const char* text, ThreadCpuCounter& result) {
    const char* close = std::strrchr(text, ')');
    if (!close) return false;
    const char* cursor = close + 1;
    uint64_t user = 0, system = 0, start = 0;
    for (int field = 3; field <= 22; ++field) {
        while (*cursor == ' ') ++cursor;
        const char* end = cursor;
        while (*end && *end != ' ' && *end != '\n') ++end;
        if (end == cursor) return false;
        if (field == 14 || field == 15 || field == 22) {
            uint64_t value = 0;
            const auto parsed = std::from_chars(cursor, end, value);
            if (parsed.ec != std::errc{} || parsed.ptr != end) return false;
            if (field == 14) user = value;
            if (field == 15) system = value;
            if (field == 22) start = value;
        }
        cursor = end;
    }
    if (!start || user > UINT64_MAX - system) return false;
    result = {start, user + system};
    return true;
}
