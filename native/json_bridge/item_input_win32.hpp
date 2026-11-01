#pragma once
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <mutex>
#include <thread>
#include "item_input_messages.hpp"

namespace PBZMC::ItemInput {
struct WindowIdentity {
    HWND window{};
    DWORD process{}, thread{};
    std::uintptr_t cookie{};
};
inline bool same_identity(const WindowIdentity& expected, HWND actual_window, DWORD actual_process,
                          DWORD actual_thread, std::uintptr_t actual_cookie, bool class_matches) noexcept {
    return expected.window && actual_window == expected.window && expected.process != 0 &&
           expected.thread != 0 && actual_process == expected.process && actual_thread == expected.thread &&
           expected.cookie != 0 && actual_cookie == expected.cookie && class_matches;
}
class Capture {
    // This object and its mutexes are intentionally process-lifetime after pin.
    // End/StopLua removes the hook and joins the worker, but never deletes this
    // callback-reachable state. A callback pending before Unhook is still safe.
    inline static constexpr wchar_t property_name[] = L"PBZMCJsonBridge.ItemInput.Owner.v05";
    inline static const wchar_t pin_anchor = L'P';
    std::mutex control_mutex_, state_mutex_, wake_mutex_;
    std::condition_variable wake_;
    std::thread worker_;
    std::atomic_bool enabled_{false}, stopping_{false}, failed_{false};
    std::atomic_uint64_t callback_entries_{}, stale_callbacks_{};
    WindowIdentity target_{};
    Bindings bindings_{};
    Core core_{};
    HHOOK hook_{};
    DWORD game_thread_{};
    std::uintptr_t next_cookie_{};
    bool pinned_{};
    std::uint64_t last_stop_{};

    static bool unreal_class(HWND window) noexcept {
        wchar_t name[32]{};
        return GetClassNameW(window, name, static_cast<int>(std::size(name))) == 12 && std::wstring_view(name) == L"UnrealWindow";
    }
    bool identity_valid() const noexcept {
        if (!target_.window) return false;
        DWORD process{};
        const auto thread = GetWindowThreadProcessId(target_.window, &process);
        return process == GetCurrentProcessId() && same_identity(target_, target_.window, process, thread,
            reinterpret_cast<std::uintptr_t>(GetPropW(target_.window, property_name)), unreal_class(target_.window));
    }
    bool foreground_valid() const noexcept {
        return identity_valid() && GetForegroundWindow() == target_.window &&
               IsWindowVisible(target_.window) && !IsIconic(target_.window);
    }
    // Caller holds state mutex. No GetAsyncKeyState outside eligible PBZ.
    Environment environment(bool baseline) const noexcept {
        Environment result;
        result.identity_valid = identity_valid();
        if (!result.identity_valid || !foreground_valid()) return result;
        POINT point{}; RECT rectangle{};
        if (!GetCursorPos(&point) || !ScreenToClient(target_.window, &point) || !GetClientRect(target_.window, &rectangle)) return result;
        const auto width = static_cast<std::int64_t>(rectangle.right) - rectangle.left;
        const auto height = static_cast<std::int64_t>(rectangle.bottom) - rectangle.top;
        if (rectangle.left != 0 || rectangle.top != 0 || width <= 0 || height <= 0 || width > 65535 || height > 65535) return result;
        result.swapped = GetSystemMetrics(SM_SWAPBUTTON) != 0;
        result.pointer = {true, point.x >= 0 && point.y >= 0 && point.x < width && point.y < height,
                          point.x, point.y, static_cast<std::int32_t>(width), static_cast<std::int32_t>(height)};
        result.pointer.time_ms = GetTickCount64();
        if (baseline) {
            for (unsigned i = 0; i < bindings_.size(); ++i) {
                if (!foreground_valid()) { result.pointer = {}; result.held_keys = 0; return result; }
                if ((GetAsyncKeyState(bindings_[i]) & 0x8000) != 0) result.held_keys |= static_cast<std::uint32_t>(1u << i);
            }
            std::array<bool, 3> buttons{};
            constexpr std::array<int, 3> codes{VK_LBUTTON, VK_RBUTTON, VK_MBUTTON};
            for (unsigned i = 0; i < codes.size(); ++i) {
                if (!foreground_valid()) { result.pointer = {}; result.held_keys = 0; return result; }
                buttons[i] = (GetAsyncKeyState(codes[i]) & 0x8000) != 0;
            }
            result.held_buttons = logical_buttons(buttons[0], buttons[1], buttons[2], result.swapped);
            if (!foreground_valid()) { result.pointer = {}; result.held_keys = 0; result.held_buttons = 0; return result; }
            result.pointer.shift = (GetAsyncKeyState(VK_SHIFT) & 0x8000) != 0;
            if (!foreground_valid()) { result.pointer = {}; result.held_keys = 0; result.held_buttons = 0; return result; }
            result.pointer.ctrl = (GetAsyncKeyState(VK_CONTROL) & 0x8000) != 0;
            result.modifiers_known = true;
        }
        if (!foreground_valid()) { result.pointer = {}; result.held_keys = 0; result.held_buttons = 0; }
        return result;
    }
    void require_active() const {
        if (failed_.load()) throw std::runtime_error("item input callback or watchdog failed; EndItemInput is required");
        if (!hook_ || !enabled_.load()) throw std::runtime_error("item input is inactive; call BeginItemInput first");
    }
    void observe_locked(std::uint64_t now, bool force_baseline = false) noexcept {
        auto observed = environment(false);
        if (force_baseline || core_.needs_baseline(observed, now)) observed = environment(true);
        core_.observe(observed, now);
    }
    static LRESULT CALLBACK callback(int code, WPARAM remove, LPARAM data) noexcept {
        auto& self = instance();
        self.callback_entries_.fetch_add(1, std::memory_order_relaxed);
        if (!self.enabled_.load(std::memory_order_acquire)) {
            self.stale_callbacks_.fetch_add(1, std::memory_order_relaxed);
            return CallNextHookEx(nullptr, code, remove, data);
        }
        MSG raw_cleanup{};
        try {
            // No payload read, even its message id, before the remove gate.
            if (!removed_message(code, remove)) {
                if (code == HC_ACTION && remove == PM_NOREMOVE) {
                    std::lock_guard lock(self.state_mutex_); self.core_.note_peek();
                }
                return CallNextHookEx(nullptr, code, remove, data);
            }
            std::lock_guard lock(self.state_mutex_);
            if (self.enabled_.load(std::memory_order_relaxed) && GetCurrentThreadId() == self.target_.thread && data) {
                const auto now = GetTickCount64();
                auto observed = self.environment(false);
                if (self.core_.needs_baseline(observed, now)) observed = self.environment(true);
                self.core_.observe(observed, now);
                auto& message = *reinterpret_cast<MSG*>(data);
                // Read only routing hwnd when not our eligible foreground.
                if (!observed.pointer.focused || message.hwnd != self.target_.window) self.core_.note_foreign();
                else {
                    Event event;
                    bool decoded=false,raw_mouse=false;
                    if (self.core_.command() && (message.message==WM_KEYDOWN || message.message==WM_KEYUP)) {
                        event.kind=message.message==WM_KEYDOWN ? Kind::command_down : Kind::command_up;
                        event.index=static_cast<unsigned>(message.wParam);
                        event.repeat=(static_cast<std::uint64_t>(message.lParam)&(1ull<<30))!=0;
                        decoded=true;
                        if (message.message==WM_KEYUP) {
                            Event released;
                            if (decode(message.message,message.wParam,message.lParam,self.bindings_,released)) event=released;
                        }
                    } else if (self.core_.command() && (message.message==WM_CHAR || message.message==WM_DEADCHAR)) {
                        // Command text is a bounded ASCII grammar, never an engine console.
                        consume_message(message);
                    } else if (message.message==WM_INPUT && self.core_.filter_raw_mouse()) {
                        RAWINPUT raw{};UINT size=sizeof(raw);
                        const auto bytes=GetRawInputData(reinterpret_cast<HRAWINPUT>(message.lParam),RID_INPUT,&raw,&size,sizeof(RAWINPUTHEADER));
                        if (bytes==sizeof(raw) && raw.header.dwType==RIM_TYPEMOUSE) {
                            raw_mouse=true;event.kind=Kind::look;decoded=true;
                            if (!(raw.data.mouse.usFlags&MOUSE_MOVE_ABSOLUTE)) {
                                event.dx=raw.data.mouse.lLastX;event.dy=raw.data.mouse.lLastY;
                            }
                        }
                    } else decoded=decode(message.message, message.wParam, message.lParam, self.bindings_, event);
                    if (decoded) {
                        event.message_time = message.time; event.pointer = observed.pointer;
                        const bool key = event.kind == Kind::key_down || event.kind == Kind::key_up || event.kind == Kind::modifiers ||
                            event.kind == Kind::command_down || event.kind == Kind::command_up;
                        if (key) {
                            event.pointer.shift = (GetKeyState(VK_SHIFT) & 0x8000) != 0;
                            event.pointer.ctrl = (GetKeyState(VK_CONTROL) & 0x8000) != 0;
                        } else if (event.kind!=Kind::look) {
                            event.pointer.shift = (GET_KEYSTATE_WPARAM(message.wParam) & MK_SHIFT) != 0;
                            event.pointer.ctrl = (GET_KEYSTATE_WPARAM(message.wParam) & MK_CONTROL) != 0;
                            POINT point{GET_X_LPARAM(message.lParam), GET_Y_LPARAM(message.lParam)};
                            if (event.kind == Kind::wheel && !ScreenToClient(self.target_.window, &point)) observed.pointer = {};
                            event.pointer.x = point.x; event.pointer.y = point.y;
                            event.pointer.inside = point.x >= 0 && point.y >= 0 && point.x < event.pointer.width && point.y < event.pointer.height;
                        }
                        // A focus change during the scalar reads cancels this event.
                        if (!observed.pointer.focused || !self.foreground_valid()) { observed.pointer = {}; self.core_.observe(observed, now); }
                        else {
                            const auto consumed=self.core_.event(event, observed, now);
                            if (raw_mouse && self.core_.filter_raw_mouse()) {
                                // We own MC raw mouse only. Complete WM_INPUT's
                                // required default cleanup outside the mutex.
                                raw_cleanup=message;consume_message(message);
                            } else if (consumed) consume_message(message);
                        }
                    }
                }
            }
        } catch (...) {
            self.failed_.store(true); self.enabled_.store(false);
        }
        if (raw_cleanup.message==WM_INPUT && GET_RAWINPUT_CODE_WPARAM(raw_cleanup.wParam)==RIM_INPUT)
            DefWindowProcW(raw_cleanup.hwnd,WM_INPUT,raw_cleanup.wParam,raw_cleanup.lParam);
        // Outside state mutex: other hooks may reenter code in this process.
        return CallNextHookEx(nullptr, code, remove, data);
    }
    void stop_impl() {
        enabled_.store(false, std::memory_order_release);
        { std::lock_guard lock(state_mutex_); core_.stop(); }
        stopping_.store(true); wake_.notify_all();
        if (worker_.joinable()) worker_.join();
        if (hook_) {
            if (!UnhookWindowsHookEx(hook_))
                throw std::runtime_error("UnhookWindowsHookEx failed; callback remains disabled and DLL pinned; retry EndItemInput");
            hook_ = nullptr;
        }
        {
            std::lock_guard lock(state_mutex_);
            if (identity_valid()) {
                if (RemovePropW(target_.window, property_name) != reinterpret_cast<HANDLE>(target_.cookie))
                    throw std::runtime_error("removing the owned item-input window property failed; retry EndItemInput");
            }
            target_ = {}; last_stop_ = GetTickCount64();
        }
    }
public:
    Capture() = default;
    Capture(const Capture&) = delete;
    Capture& operator=(const Capture&) = delete;
    static Capture& instance() {
        static Capture* const persistent = new Capture();
        return *persistent; // intentionally never deleted; see pin/unhook boundary
    }
    void begin(const Bindings& bindings) {
        std::lock_guard control(control_mutex_);
        if (hook_ || worker_.joinable() || target_.window) throw std::runtime_error("item input already active or cleanup is incomplete");
        const auto now = GetTickCount64();
        if (last_stop_ && now <= last_stop_) throw std::runtime_error("item input restart must cross a clock tick; retry next frame");
        const auto window = GetForegroundWindow();
        DWORD process{}; const auto thread = GetWindowThreadProcessId(window, &process);
        if (!window || process != GetCurrentProcessId() || !thread || !unreal_class(window) || !IsWindowVisible(window) || IsIconic(window))
            throw std::runtime_error("item input requires this process's visible UnrealWindow foreground");
        if (GetPropW(window, property_name)) throw std::runtime_error("item input window ownership property already exists");
        if (!pinned_) {
            HMODULE module{};
            if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_PIN, &pin_anchor, &module) || !module)
                throw std::runtime_error("pinning callback DLL until process exit failed; hook was not installed");
            pinned_ = true;
        }
        try {
            {
                std::lock_guard lock(state_mutex_);
                ++next_cookie_; if (!next_cookie_) ++next_cookie_;
                target_ = {window, process, thread, next_cookie_}; bindings_ = bindings;
                if (!SetPropW(window, property_name, reinterpret_cast<HANDLE>(target_.cookie)))
                    throw std::runtime_error("cannot set owned item input window identity");
                const auto initial = environment(true);
                if (!initial.pointer.focused) throw std::runtime_error("game window changed while beginning item input");
                game_thread_ = GetCurrentThreadId(); core_.start(initial, now);
            }
            failed_.store(false); stopping_.store(false);
            hook_ = SetWindowsHookExW(WH_GETMESSAGE, &callback, nullptr, thread);
            if (!hook_) throw std::runtime_error("installing the current-process window-thread message hook failed");
            enabled_.store(true, std::memory_order_release);
            worker_ = std::thread([this] {
                try {
                    std::unique_lock wake_lock(wake_mutex_);
                    while (!wake_.wait_for(wake_lock, std::chrono::milliseconds(4), [this] { return stopping_.load(); })) {
                        std::lock_guard lock(state_mutex_);
                        if (enabled_.load()) observe_locked(GetTickCount64());
                    }
                } catch (...) { failed_.store(true); enabled_.store(false); }
            });
        } catch (...) {
            // Preserve the triggering exception unless cleanup itself failed.
            stop_impl();
            throw;
        }
    }
    void set_context(Context context) {
        std::lock_guard control(control_mutex_); require_active();
        std::lock_guard lock(state_mutex_);
        const auto observed = environment(true);
        if (!observed.identity_valid) throw std::runtime_error("item input window identity expired; EndItemInput and BeginItemInput are required");
        core_.set_context(context, observed, GetTickCount64());
    }
    std::string read() {
        Batch batch;
        DWORD game_thread{}, window_thread{};
        {
            std::lock_guard control(control_mutex_); require_active();
            std::lock_guard lock(state_mutex_);
            const auto now = GetTickCount64();
            auto observed = environment(false);
            if (core_.heartbeat_expired() || core_.needs_baseline(observed, now)) observed = environment(true);
            batch = core_.drain(observed, now);
            game_thread = game_thread_; window_thread = target_.thread;
        }
        return batch_json(batch, game_thread, window_thread, callback_entries_.load(), stale_callbacks_.load());
    }
    void end() { std::lock_guard control(control_mutex_); stop_impl(); }
    void stop_noexcept() noexcept {
        try { end(); }
        catch (...) { OutputDebugStringW(L"PBZMCJsonBridge: item-input stop failed; disabled hook/state remain pinned; cleanup requires retry or process exit.\n"); }
    }
};
} // namespace PBZMC::ItemInput
