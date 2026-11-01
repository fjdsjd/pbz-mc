#pragma once
#include <Windows.h>
#include <windowsx.h>
#include "item_input_core.hpp"

namespace PBZMC::ItemInput {
// Pure decode: callers must validate HC_ACTION/PM_REMOVE, process, HWND and
// foreground BEFORE passing message payloads here.
inline bool decode(UINT message, WPARAM wparam, LPARAM lparam, const Bindings& bindings, Event& event) noexcept {
    if (message == WM_KEYDOWN || message == WM_KEYUP || message == WM_SYSKEYDOWN || message == WM_SYSKEYUP) {
        const bool down = message == WM_KEYDOWN || message == WM_SYSKEYDOWN;
        for (unsigned i = 0; i < bindings.size(); ++i) if (wparam == bindings[i]) {
            event.kind = down ? Kind::key_down : Kind::key_up;
            event.index = i;
            event.repeat = down && (static_cast<std::uint64_t>(lparam) & (1ull << 30)) != 0;
            event.system_key = message == WM_SYSKEYDOWN || message == WM_SYSKEYUP;
            return true;
        }
        if (wparam == VK_SHIFT || wparam == VK_LSHIFT || wparam == VK_RSHIFT ||
            wparam == VK_CONTROL || wparam == VK_LCONTROL || wparam == VK_RCONTROL) {
            event.kind = Kind::modifiers; return true; // observed, never consumed
        }
        return false;
    }
    if (message == WM_MOUSEWHEEL) {
        event.kind = Kind::wheel;
        event.wheel = GET_WHEEL_DELTA_WPARAM(wparam);
        return true;
    }
    if (message == WM_MOUSEMOVE) { event.kind = Kind::move; return true; }
    switch (message) {
    case WM_LBUTTONDOWN: case WM_LBUTTONDBLCLK: event.kind = Kind::button_down; event.index = 0; return true;
    case WM_LBUTTONUP: event.kind = Kind::button_up; event.index = 0; return true;
    case WM_RBUTTONDOWN: case WM_RBUTTONDBLCLK: event.kind = Kind::button_down; event.index = 1; return true;
    case WM_RBUTTONUP: event.kind = Kind::button_up; event.index = 1; return true;
    case WM_MBUTTONDOWN: case WM_MBUTTONDBLCLK: event.kind = Kind::button_down; event.index = 2; return true;
    case WM_MBUTTONUP: event.kind = Kind::button_up; event.index = 2; return true;
    default: return false; // WM_INPUT, WM_*CHAR and non-client messages pass through.
    }
}
inline std::uint8_t logical_buttons(bool physical_left, bool physical_right, bool middle, bool swapped) noexcept {
    return static_cast<std::uint8_t>(((swapped ? physical_right : physical_left) ? 1 : 0) |
                                     ((swapped ? physical_left : physical_right) ? 2 : 0) | (middle ? 4 : 0));
}
inline bool removed_message(int code, WPARAM remove) noexcept { return code == HC_ACTION && remove == PM_REMOVE; }
inline void consume_message(MSG& message) noexcept { message.message = WM_NULL; message.wParam = 0; message.lParam = 0; }
} // namespace PBZMC::ItemInput
