#pragma once
#include "pointer_state.hpp"
#include <algorithm>
#include <vector>

namespace PBZMC::Pointer {
inline bool changed(const State& a, const State& b) {
    return a.focused != b.focused || a.inside != b.inside || a.x != b.x || a.y != b.y ||
        a.width != b.width || a.height != b.height || a.buttons != b.buttons || a.keys != b.keys ||
        a.shift != b.shift || a.ctrl != b.ctrl;
}
// Access is externally serialized. A full queue is explicitly invalidated;
// replaying half a gesture could otherwise duplicate or misplace a stack.
class Queue {
    std::vector<State> samples;
    State latest{};
    bool initialized{}, overflow{};
    std::uint64_t polls{}, max_interval{};
public:
    void push(State value) {
        if (initialized && value.focused && latest.focused && value.time_ms >= latest.time_ms)
            max_interval = (std::max)(max_interval, value.time_ms - latest.time_ms);
        ++polls;
        if (!initialized || changed(value, latest)) {
            if (samples.size() == 512) { samples.clear(); overflow = true; }
            samples.push_back(value);
        }
        latest = value; initialized = true;
    }
    std::string drain() {
        // Focus loss must not replay stale clicks from the former foreground.
        if (!latest.focused) { samples.clear(); overflow = true; }
        std::string result = std::string("{\"overflow\":") + (overflow ? "true" : "false") +
            ",\"polls\":" + std::to_string(polls) + ",\"max_interval_ms\":" + std::to_string(max_interval) + ",\"samples\":[";
        bool first = true;
        for (const auto& value : samples) { if (!first) result += ','; first = false; result += json(value); }
        result += "],\"latest\":" + json(latest) + '}';
        samples.clear(); overflow = false;
        if (result.size() > 256 * 1024) throw std::runtime_error("pointer event JSON exceeds its fixed bound");
        return result;
    }
};
} // namespace PBZMC::Pointer
