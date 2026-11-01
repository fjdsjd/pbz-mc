#pragma once
#include <array>
#include <cstdint>
#include <stdexcept>
#include <string>
#include <string_view>

namespace PBZMC::Pointer {
enum class Key : std::size_t { left, right, shift, control, e, escape, f, q, one, two, three, four, five, six, seven, eight, nine, count };
struct State {
    bool focused{}, inside{};
    std::int32_t x{}, y{}, width{}, height{};
    std::uint8_t buttons{};
    bool shift{}, ctrl{};
    std::uint32_t keys{};
    std::uint64_t time_ms{};
};
inline bool eligible(std::uintptr_t window, std::uint32_t process, std::uint32_t current,
                     std::wstring_view class_name, bool visible, bool minimized) {
    return window != 0 && process != 0 && process == current && class_name == L"UnrealWindow" && visible && !minimized;
}

// The API adapter owns the checked Win32 calls. Recheck focus before each of
// the fixed 17 samples and after the set; discard partial results on focus loss.
// This cannot make separate Win32 calls atomic with an external focus change.
template<class Api> State sample(Api& api) {
    const auto window = api.foreground();
    if (!window || !api.eligible_window(window)) return {};
    State result;
    if (!api.geometry(window, result) || result.width <= 0 || result.height <= 0 ||
        result.width > 65535 || result.height > 65535) return {};
    const auto still_focused = [&] { return api.foreground() == window && api.eligible_window(window); };
    std::array<bool, static_cast<std::size_t>(Key::count)> down{};
    for (std::size_t i = 0; i < down.size(); ++i) {
        if (!still_focused()) return {};
        down[i] = (static_cast<std::uint16_t>(api.key_state(static_cast<Key>(i))) & 0x8000u) != 0;
    }
    if (!still_focused()) return {};
    result.focused = true;
    result.inside = result.x >= 0 && result.y >= 0 && result.x < result.width && result.y < result.height;
    result.buttons = static_cast<std::uint8_t>((down[0] ? 1 : 0) | (down[1] ? 2 : 0));
    result.shift = down[2]; result.ctrl = down[3];
    for (std::size_t i = 4; i < down.size(); ++i)
        if (down[i]) result.keys |= static_cast<std::uint16_t>(1u << (i - 4));
    result.time_ms = api.milliseconds();
    return result;
}

inline std::string json(const State& s) {
    const auto boolean = [](bool value) { return value ? "true" : "false"; };
    std::string text = std::string("{\"focused\":") + boolean(s.focused) + ",\"inside\":" + boolean(s.inside) +
        ",\"x\":" + std::to_string(s.x) + ",\"y\":" + std::to_string(s.y) +
        ",\"width\":" + std::to_string(s.width) + ",\"height\":" + std::to_string(s.height) +
        ",\"buttons\":" + std::to_string(s.buttons) + ",\"shift\":" + boolean(s.shift) +
        ",\"ctrl\":" + boolean(s.ctrl) + ",\"keys\":" + std::to_string(s.keys);
    if (s.focused) text += ",\"time_ms\":" + std::to_string(s.time_ms);
    text += "}";
    if (text.size() > 512) throw std::runtime_error("pointer state JSON exceeds its fixed bound");
    return text;
}
} // namespace PBZMC::Pointer
