#pragma once
#include <array>
#include <cstdint>
#include <limits>
#include <stdexcept>
#include <string>
#include <string_view>
#include "pointer_state.hpp"

// Engine-free state machine. The Win32 adapter serializes access externally.
// Callback paths mutate fixed-size POD storage only; serialization is outside
// the callback and outside the state lock.
namespace PBZMC::ItemInput {
constexpr std::size_t key_count = 24;
constexpr std::size_t queue_capacity = 512;
constexpr std::uint64_t heartbeat_limit_ms = 500;
using Bindings = std::array<std::uint16_t, key_count>;
enum class Context : std::uint8_t { inactive, game_pbz, game_mc, inventory, game_pbz_hotbar, game_mc_combat, game_fp, command, creative_pbz, motion_pbz };
inline bool mc_motion(Context c) noexcept { return c==Context::game_fp || c==Context::motion_pbz; }
inline const char* context_name(Context value) noexcept {
    switch (value) {
    case Context::game_pbz: return "game-pbz";
    case Context::game_mc: return "game-mc";
    case Context::inventory: return "inventory";
    case Context::game_pbz_hotbar: return "game-pbz-hotbar";
    case Context::game_mc_combat: return "game-mc-combat";
    case Context::game_fp: return "game-first-person";
    case Context::command: return "command";
    case Context::creative_pbz: return "game-creative-pbz";
    case Context::motion_pbz: return "game-motion-pbz";
    default: return "inactive";
    }
}
inline Context parse_context(std::string_view text) {
    if (text == "inactive") return Context::inactive;
    if (text == "game-pbz") return Context::game_pbz;
    if (text == "game-mc") return Context::game_mc;
    if (text == "inventory") return Context::inventory;
    if (text == "game-pbz-hotbar") return Context::game_pbz_hotbar;
    if (text == "game-mc-combat") return Context::game_mc_combat;
    if (text == "game-first-person") return Context::game_fp;
    if (text == "command") return Context::command;
    if (text == "game-creative-pbz") return Context::creative_pbz;
    if (text == "game-motion-pbz") return Context::motion_pbz;
    throw std::runtime_error("unsupported item input context");
}
inline Bindings parse_bindings(std::string_view text) {
    if (text.empty() || text.size() > 96) throw std::runtime_error("binding CSV must contain 1..96 ASCII bytes");
    constexpr std::array<unsigned,11> fixed{116,87,65,83,68,32,16,17,192,191,72};
    Bindings result{};
    std::size_t position{};
    for (std::size_t i = 0; i < result.size(); ++i) {
        const auto first = position;
        unsigned value{};
        while (position < text.size() && text[position] != ',') {
            const auto c = text[position++];
            if (c < '0' || c > '9' || position - first > 3) throw std::runtime_error("binding CSV requires canonical decimal VK values");
            value = value * 10 + static_cast<unsigned>(c - '0');
        }
        if (position == first || (position - first > 1 && text[first] == '0'))
            throw std::runtime_error("binding CSV has an empty or noncanonical VK");
        const bool allowed = (value >= 48 && value <= 57) || (value >= 65 && value <= 90) ||
                             (value >= 112 && value <= 123 && value != 116);
        if ((i == 1 && value != 27) || (i >= 13 && value != fixed[i-13]) || (i != 1 && i < 13 && !allowed))
            throw std::runtime_error("bindings allow A-Z, 0-9 and F1-F12 except F5; close is fixed Escape");
        for (std::size_t j = 0; j < i; ++j)
            if (result[j] == value) throw std::runtime_error("duplicate item bindings are not allowed");
        result[i] = static_cast<std::uint16_t>(value);
        // Older callers send the original thirteen keys. F5 stays reserved and
        // receives the new last bit without changing any existing bit index.
        if ((i == 12 || i == 13 || i == 20 || i == 21 || i == 22) && position == text.size()) {
            for (auto j=i+1;j<result.size();++j) {
                result[j]=static_cast<std::uint16_t>(fixed[j-13]);
                for (std::size_t k=0;k<j;++k) if(result[k]==result[j]) throw std::runtime_error("item binding conflicts with reserved first-person movement");
            }
            return result;
        }
        if (i + 1 < result.size()) {
            if (position == text.size()) throw std::runtime_error("binding CSV requires 13/14/21/22/23 legacy or 24 VK values");
            ++position;
        } else if (position != text.size()) throw std::runtime_error("binding CSV requires 13/14/21/22/23 legacy or 24 VK values");
    }
    return result;
}
inline bool consumes_key(Context context, unsigned index) noexcept {
    if (index >= key_count || context == Context::inactive) return false;
    if (context == Context::command) return true;
    if (index == 22 || index == 23) return context != Context::inventory;
    if (context == Context::creative_pbz) return index==0 || (index>=4 && index<=13) || (index>=18 && index<=20);
    if (index == 21) return mc_motion(context) || context == Context::game_mc_combat || context == Context::inventory;
    // Keep native WASD key state current while MC's controller movement lease
    // suppresses native locomotion. Returning to PBZ then needs no fake press
    // or user release/repress. Containers still own their directional input.
    if (index >= 14 && index <= 17) return context == Context::inventory;
    if (index >= 14) return mc_motion(context) || context == Context::inventory;
    if (context == Context::game_pbz) return index == 0 || index == 13;
    if (context == Context::game_pbz_hotbar) return index == 0 || index >= 4;
    return context == Context::inventory || index != 1;
}
inline bool gameplay_context(Context context) noexcept {
    return context!=Context::inactive && context!=Context::inventory && context!=Context::command;
}
constexpr std::uint32_t direction_keys = 0xfu << 14;
inline bool consumes_wheel(Context context) noexcept {
    return context == Context::game_mc || context == Context::inventory || context == Context::command ||
           context == Context::creative_pbz || context == Context::game_pbz_hotbar || context == Context::game_mc_combat || mc_motion(context);
}
inline bool consumes_button(Context context, unsigned index) noexcept {
    // Boat/glider controls can own motion and use/attack with a native slot.
    // The physical middle button still drives PBZ's IA_LockTarget.
    return index <= 2 && (context == Context::command || context == Context::inventory || context == Context::game_mc_combat ||
                         context == Context::game_fp || (context == Context::motion_pbz && index < 2) ||
                         (context == Context::game_mc && index == 2));
}
struct Environment {
    Pointer::State pointer{};
    std::uint32_t held_keys{};
    std::uint8_t held_buttons{}; // logical primary/secondary/middle, unlike 0.4
    bool identity_valid{}, swapped{}, modifiers_known{};
};
enum class Kind : std::uint8_t { move, key_down, key_up, button_down, button_up, wheel, modifiers, look, command_down, command_up };
inline std::uint64_t message_time64(std::uint64_t now, std::uint32_t message_time) noexcept {
    // MSG.time is the low 32 bits of the monotonic message timestamp. Retain
    // arrival intervals when several queued events are removed in one frame.
    const auto age = static_cast<std::uint32_t>(now) - message_time;
    return age <= static_cast<std::uint32_t>(std::numeric_limits<std::int32_t>::max()) && now >= age ? now - age : now;
}
struct Event {
    Kind kind{Kind::move};
    unsigned index{};
    bool repeat{}, system_key{};
    std::int16_t wheel{};
    std::uint32_t message_time{};
    std::int32_t dx{},dy{};
    Pointer::State pointer{};
};
struct Sample {
    Pointer::State pointer{};
    std::uint64_t epoch{}, seq{};
    std::int16_t wheel_delta{};
    std::int32_t dx{},dy{};
    unsigned command_key{};
};
struct Stats {
    std::uint64_t messages{}, consumed{}, ignored_peeks{}, foreign_messages{}, stale_messages{}, repeats{};
    std::uint64_t focus_resets{}, context_resets{}, timeout_resets{}, overflow_resets{}, identity_resets{}, swap_resets{}, quarantine_resets{};
    std::uint64_t coalesced_motion{};
};
struct Batch {
    std::array<Sample, queue_capacity> samples{};
    std::size_t count{};
    Sample latest{};
    Stats stats{};
    Context context{Context::inactive};
    std::uint64_t epoch{}, heartbeat_age_ms{};
    std::uint32_t blocked_keys{}, owned_keys{};
    std::uint8_t blocked_buttons{}, owned_buttons{};
    bool overflow{}, timed_out_since_read{}, heartbeat_expired{}, draining_owned_releases{}, identity_lost{};
};
class Core {
    std::array<Sample, queue_capacity> samples_{};
    std::size_t count_{};
    Sample latest_{};
    Stats stats_{};
    Context context_{Context::inactive};
    std::uint64_t epoch_{1}, sequence_{}, heartbeat_{}, barrier_{};
    std::uint32_t keys_{}, blocked_keys_{}, owned_keys_{};
    std::uint8_t buttons_{}, blocked_buttons_{}, owned_buttons_{};
    std::uint8_t legacy_raw_down_{}, legacy_raw_owned_{};
    std::array<std::uint64_t, key_count> down_times_{};
    std::array<std::uint64_t, 3> button_down_times_{};
    bool focused_{}, swapped_{}, expired_{}, overflow_{}, timeout_notice_{}, identity_lost_{}, started_{};
    bool look_tail_{};

    void reset(const Environment& environment, std::uint64_t now) noexcept {
        ++epoch_; count_ = 0; barrier_ = now; look_tail_ = false;
        blocked_keys_ = static_cast<std::uint32_t>(environment.held_keys | keys_);
        blocked_buttons_ = static_cast<std::uint8_t>(environment.held_buttons | buttons_);
        keys_ = 0; buttons_ = 0;
        auto pointer = environment.pointer;
        if (!environment.identity_valid || identity_lost_) pointer = {};
        pointer.time_ms = now;
        pointer.keys = pointer.focused ? blocked_keys_ : 0;
        pointer.buttons = pointer.focused ? blocked_buttons_ : 0;
        latest_ = {pointer, epoch_, ++sequence_, 0};
        samples_[count_++] = latest_; // an explicit baseline arms the Lua controller
    }
    void refresh_latest(Pointer::State pointer) noexcept {
        pointer.keys = pointer.focused ? static_cast<std::uint32_t>(keys_ | blocked_keys_) : 0;
        pointer.buttons = pointer.focused ? static_cast<std::uint8_t>(buttons_ | blocked_buttons_) : 0;
        latest_ = {pointer, epoch_, sequence_, 0};
    }
    void quarantine(const Environment& environment, std::uint64_t now, std::uint32_t key, std::uint8_t button) noexcept {
        // A late discovery of a held/repeat/stale down cannot appear as a new
        // edge in latest after an already-armed baseline in the same epoch.
        auto held = environment;
        held.held_keys |= static_cast<std::uint32_t>(blocked_keys_ | key);
        held.held_buttons |= static_cast<std::uint8_t>(blocked_buttons_ | button);
        ++stats_.quarantine_resets; reset(held, now);
    }
    void push(Pointer::State pointer, std::int16_t wheel, const Environment& environment, std::uint64_t now,
              std::int32_t dx=0,std::int32_t dy=0,unsigned command_key=0,bool look=false) noexcept {
        pointer.keys = static_cast<std::uint32_t>(keys_ | blocked_keys_);
        pointer.buttons = static_cast<std::uint8_t>(buttons_ | blocked_buttons_);
        // High polling-rate mice can otherwise send hundreds of full JSON
        // objects per render frame. Merge only consecutive, same-millisecond,
        // same-direction motion. Preserve timestamp boundaries (Lua's legacy
        // mouse deduplication), pitch-clamp reversals and every action edge.
        if (look && look_tail_ && count_ != 0) {
            auto& tail = samples_[count_ - 1];
            const auto& p = tail.pointer;
            const auto sum_x = static_cast<std::int64_t>(tail.dx) + dx;
            const auto sum_y = static_cast<std::int64_t>(tail.dy) + dy;
            const auto same_direction = [](std::int32_t a, std::int32_t b) {
                return a == 0 || b == 0 || (a < 0) == (b < 0);
            };
            constexpr auto bound = std::int64_t{1} << 31;
            if (tail.epoch == epoch_ && p.time_ms == pointer.time_ms &&
                p.keys == pointer.keys && p.buttons == pointer.buttons &&
                p.shift == pointer.shift && p.ctrl == pointer.ctrl &&
                p.focused == pointer.focused && p.inside == pointer.inside &&
                p.x == pointer.x && p.y == pointer.y && p.width == pointer.width && p.height == pointer.height &&
                same_direction(tail.dx, dx) && same_direction(tail.dy, dy) &&
                sum_x > -bound && sum_x < bound && sum_y > -bound && sum_y < bound) {
                tail.dx = static_cast<std::int32_t>(sum_x); tail.dy = static_cast<std::int32_t>(sum_y);
                tail.seq = ++sequence_; ++stats_.coalesced_motion;
                latest_ = {pointer, epoch_, sequence_, 0};
                return;
            }
        }
        if (count_ == queue_capacity) {
            ++stats_.overflow_resets; overflow_ = true;
            reset(environment, now);
            refresh_latest(pointer);
            return;
        }
        samples_[count_++] = {pointer, epoch_, ++sequence_, wheel,dx,dy,command_key};
        look_tail_ = look;
        latest_ = {pointer, epoch_, sequence_, 0};
    }
public:
    void start(const Environment& environment, std::uint64_t now) noexcept {
        const auto next_epoch = epoch_ + 1;
        *this = {};
        epoch_ = next_epoch;
        started_ = true; focused_ = environment.pointer.focused; swapped_ = environment.swapped;
        heartbeat_ = now; barrier_ = now;
        blocked_keys_ = environment.held_keys; blocked_buttons_ = environment.held_buttons;
        refresh_latest(environment.pointer);
        latest_.seq = ++sequence_; samples_[count_++] = latest_;
    }
    void stop() noexcept {
        started_ = false; context_ = Context::inactive; ++epoch_; count_ = 0; look_tail_ = false;
        keys_ = blocked_keys_ = owned_keys_ = 0;
        buttons_ = blocked_buttons_ = owned_buttons_ = 0;
        focused_ = false; latest_ = {}; latest_.epoch = epoch_;
    }
    void note_peek() noexcept { ++stats_.ignored_peeks; }
    void note_foreign() noexcept { ++stats_.foreign_messages; }
    bool heartbeat_expired() const noexcept { return expired_; }
    bool first_person() const noexcept { return mc_motion(context_); }
    bool command() const noexcept { return context_==Context::command && !expired_ && focused_ && !identity_lost_; }
    bool raw_eligible() const noexcept { return started_ && focused_ && !expired_ && !identity_lost_; }
    bool filter_raw_mouse() const noexcept { return raw_eligible() && (first_person() || command() || context_==Context::creative_pbz); }
    bool filter_raw_button(unsigned index, bool up) noexcept {
        if (!raw_eligible() || index>=3) return false;
        // On legacy registrations WM_* and RAWMOUSE can arrive in either order.
        // Remember the owner of the raw down independently until its physical up.
        const auto bit=static_cast<std::uint8_t>(1u<<index);
        if (!up && !(legacy_raw_down_ & bit)) {
            legacy_raw_down_|=bit;
            if (consumes_button(context_,index)) legacy_raw_owned_|=bit;
        }
        const bool owned=(legacy_raw_owned_ & bit)!=0;
        if (up) { legacy_raw_down_&=static_cast<std::uint8_t>(~bit);legacy_raw_owned_&=static_cast<std::uint8_t>(~bit); }
        return owned;
    }
    bool filter_raw_wheel() const noexcept { return raw_eligible() && consumes_wheel(context_); }
    void retain_modifiers(Pointer::State& pointer) const noexcept {
        pointer.shift=latest_.pointer.shift;pointer.ctrl=latest_.pointer.ctrl;
    }
    bool needs_baseline(const Environment& environment, std::uint64_t now) const noexcept {
        return environment.pointer.focused != focused_ ||
               (environment.pointer.focused && environment.swapped != swapped_) ||
               (!environment.identity_valid && !identity_lost_) ||
               (!expired_ && now - heartbeat_ > heartbeat_limit_ms);
    }
    void observe(const Environment& environment, std::uint64_t now) noexcept {
        if (!started_) return;
        if (!environment.identity_valid && !identity_lost_) {
            identity_lost_ = true; ++stats_.identity_resets; reset(environment, now);
            legacy_raw_down_=legacy_raw_owned_=0;
            owned_keys_ = 0; owned_buttons_ = 0;
        }
        const bool focused = environment.pointer.focused && !identity_lost_;
        if (focused != focused_) {
            ++stats_.focus_resets; reset(environment, now); focused_ = focused;
            legacy_raw_down_=legacy_raw_owned_=0;
            // Other-window releases are never consumed. Return uses a fresh baseline.
            owned_keys_ = 0; owned_buttons_ = 0;
        }
        if (focused && environment.swapped != swapped_) {
            ++stats_.swap_resets; reset(environment, now); swapped_ = environment.swapped;
            legacy_raw_down_=legacy_raw_owned_=0;
            owned_buttons_ = 0;
        }
        if (!expired_ && now - heartbeat_ > heartbeat_limit_ms) {
            expired_ = true; timeout_notice_ = true; ++stats_.timeout_resets;
            legacy_raw_down_=legacy_raw_owned_=0;
            reset(environment, now); // retain owned pairs only until their releases
        }
        auto pointer = environment.pointer;
        if (!environment.modifiers_known) {
            pointer.shift = latest_.pointer.shift; pointer.ctrl = latest_.pointer.ctrl;
        }
        pointer.focused = focused;
        if (!focused) pointer = {};
        refresh_latest(pointer);
    }
    void service(const Environment& environment, std::uint64_t now) noexcept {
        observe(environment, now);
        if (expired_) { reset(environment, now); expired_ = false; }
        heartbeat_ = now;
        refresh_latest(latest_.pointer);
    }
    void set_context(Context value, const Environment& environment, std::uint64_t now) noexcept {
        const bool seamless = started_ && focused_ && environment.pointer.focused && environment.identity_valid && !identity_lost_ &&
            !expired_ && now-heartbeat_<=heartbeat_limit_ms && environment.swapped==swapped_ &&
            gameplay_context(context_) && gameplay_context(value);
        // Only previously accepted, still physically held directions survive.
        // Held keys inherited from a menu/focus/timeout baseline stay blocked.
        const auto directions = seamless ? keys_ & environment.held_keys & direction_keys : 0u;
        service(environment, now);
        if (context_ != value) {
            ++stats_.context_resets; reset(environment, now); context_ = value;
            keys_ |= directions;blocked_keys_ &= ~directions;
            samples_[0].pointer.keys = keys_ | blocked_keys_;
            refresh_latest(latest_.pointer);
        }
    }
    bool event(const Event& event, const Environment& environment, std::uint64_t now) noexcept {
        if (event.kind != Kind::look) look_tail_ = false;
        const auto previous_pointer = latest_.pointer;
        observe(environment, now);
        if (!started_ || !focused_ || identity_lost_) return false;
        ++stats_.messages;
        auto pointer = event.pointer;
        pointer.focused = true; pointer.time_ms = message_time64(now, event.message_time);
        const auto stamp_delta = static_cast<std::int32_t>(event.message_time - static_cast<std::uint32_t>(barrier_));
        const bool stale = stamp_delta <= 0; // boundary millisecond is intentionally quarantined
        if (stale) { ++stats_.stale_messages; look_tail_ = false; }
        bool consume{}, changed{}, emit_wheel{};
        if (event.kind == Kind::command_down || event.kind == Kind::command_up) {
            consume = command() && !event.system_key;
            changed = consume && event.kind == Kind::command_down && event.index < 256 &&
                (!event.repeat || event.index == 8 || event.index == 46 || (event.index >= 35 && event.index <= 40));
        } else if (event.kind == Kind::key_down || event.kind == Kind::key_up) {
            if (event.index >= key_count) return false;
            const auto bit = static_cast<std::uint32_t>(1u << event.index);
            const bool owned = (owned_keys_ & bit) != 0;
            if (event.kind == Kind::key_up) {
                if ((keys_ & bit) && pointer.time_ms < down_times_[event.index]) { ++stats_.stale_messages; return false; }
                consume = owned || command();
                changed = ((keys_ | blocked_keys_) & bit) != 0;
                owned_keys_ &= static_cast<std::uint32_t>(~bit);
                blocked_keys_ &= static_cast<std::uint32_t>(~bit);
                keys_ &= static_cast<std::uint32_t>(~bit);
            } else if (event.repeat || (keys_ & bit) || (blocked_keys_ & bit)) {
                ++stats_.repeats; consume = owned;
                if (!(keys_ & bit) && !(blocked_keys_ & bit)) quarantine(environment, now, bit, 0);
            } else if (expired_ || stale || event.system_key) {
                quarantine(environment, now, bit, 0); consume = owned;
            } else {
                keys_ |= bit; changed = true;
                down_times_[event.index] = pointer.time_ms;
                consume = consumes_key(context_, event.index);
                if (consume) owned_keys_ |= bit;
            }
        } else if (event.kind == Kind::button_down || event.kind == Kind::button_up) {
            if (event.index > 2) return false;
            const auto bit = static_cast<std::uint8_t>(1u << event.index);
            const bool owned = (owned_buttons_ & bit) != 0;
            if (event.kind == Kind::button_up) {
                if ((buttons_ & bit) && pointer.time_ms < button_down_times_[event.index]) { ++stats_.stale_messages; return false; }
                consume = owned; changed = ((buttons_ | blocked_buttons_) & bit) != 0;
                owned_buttons_ &= static_cast<std::uint8_t>(~bit);
                blocked_buttons_ &= static_cast<std::uint8_t>(~bit);
                buttons_ &= static_cast<std::uint8_t>(~bit);
            } else if ((buttons_ & bit) || (blocked_buttons_ & bit)) {
                consume = owned;
            } else if (expired_ || stale) {
                quarantine(environment, now, 0, bit); consume = owned;
            } else {
                buttons_ |= bit; changed = true;
                button_down_times_[event.index] = pointer.time_ms;
                consume = consumes_button(context_, event.index);
                if (consume) owned_buttons_ |= bit;
            }
        } else if (event.kind == Kind::wheel) {
            consume = !expired_ && !stale && consumes_wheel(context_);
            emit_wheel = !expired_ && !stale && event.wheel != 0;
        } else if (event.kind == Kind::look) {
            changed = (mc_motion(context_) || context_==Context::creative_pbz) && (event.dx != 0 || event.dy != 0);
        } else {
            changed = event.kind == Kind::move || pointer.x != previous_pointer.x || pointer.y != previous_pointer.y ||
                      pointer.inside != previous_pointer.inside || pointer.width != previous_pointer.width ||
                      pointer.height != previous_pointer.height || pointer.shift != previous_pointer.shift || pointer.ctrl != previous_pointer.ctrl;
        }
        if (consume) ++stats_.consumed;
        if (!expired_ && !stale && (changed || emit_wheel))
            push(pointer, emit_wheel ? event.wheel : 0, environment, now,
                 event.kind==Kind::look ? event.dx : 0,event.kind==Kind::look ? event.dy : 0,
                 event.kind==Kind::command_down ? event.index : 0,event.kind==Kind::look);
        else refresh_latest(pointer);
        return consume;
    }
    Batch drain(const Environment& environment, std::uint64_t now) noexcept {
        const auto service_age = now - heartbeat_;
        service(environment, now);
        Batch result;
        result.count = count_;
        for (std::size_t i = 0; i < count_; ++i) result.samples[i] = samples_[i];
        result.latest = latest_; result.stats = stats_; result.context = context_; result.epoch = epoch_;
        result.heartbeat_age_ms = service_age;
        result.blocked_keys = blocked_keys_; result.blocked_buttons = blocked_buttons_;
        result.owned_keys = owned_keys_; result.owned_buttons = owned_buttons_;
        result.overflow = overflow_; result.timed_out_since_read = timeout_notice_;
        result.heartbeat_expired = expired_; result.identity_lost = identity_lost_;
        // Includes release pairs retained across an epoch transition as well as timeout.
        result.draining_owned_releases = (owned_keys_ & ~keys_) != 0 || (owned_buttons_ & ~buttons_) != 0;
        count_ = 0; overflow_ = false; timeout_notice_ = false; look_tail_ = false;
        return result;
    }
};
inline std::string sample_json(const Sample& sample) {
    auto text = Pointer::json(sample.pointer);
    text.pop_back();
    if (!sample.pointer.focused) text += ",\"time_ms\":" + std::to_string(sample.pointer.time_ms);
    text += ",\"epoch\":" + std::to_string(sample.epoch) + ",\"seq\":" + std::to_string(sample.seq) +
            ",\"wheel_delta\":" + std::to_string(sample.wheel_delta) +
            ",\"look_dx\":" + std::to_string(sample.dx) + ",\"look_dy\":" + std::to_string(sample.dy) +
            ",\"command_key\":" + std::to_string(sample.command_key) + '}';
    return text;
}
inline std::string batch_json(const Batch& batch, std::uint32_t game_thread, std::uint32_t window_thread,
                              std::uint64_t callback_entries, std::uint64_t stale_callbacks) {
    const auto boolean = [](bool v) { return v ? "true" : "false"; };
    std::string text = "{\"protocol\":2,\"quick_help_controls\":true,\"command_controls\":true,\"creative_pbz_controls\":true,\"camera_key\":true,\"first_person_controls\":true,\"chain_mining_controls\":true,\"combat_message_capture\":true,\"raw_input_filtered\":" + std::string((mc_motion(batch.context) || batch.context==Context::creative_pbz || batch.context==Context::command) ? "true" : "false") + ",\"context\":\"" + std::string(context_name(batch.context)) + "\",\"epoch\":" + std::to_string(batch.epoch) +
        ",\"overflow\":" + boolean(batch.overflow) + ",\"timed_out_since_read\":" + boolean(batch.timed_out_since_read) +
        ",\"heartbeat_expired\":" + boolean(batch.heartbeat_expired) + ",\"draining_owned_releases\":" + boolean(batch.draining_owned_releases) +
        ",\"identity_lost\":" + boolean(batch.identity_lost) + ",\"heartbeat_limit_ms\":" + std::to_string(heartbeat_limit_ms) +
        ",\"heartbeat_age_ms\":" + std::to_string(batch.heartbeat_age_ms) + ",\"game_thread_id\":" + std::to_string(game_thread) +
        ",\"window_thread_id\":" + std::to_string(window_thread) + ",\"dll_pinned\":true,\"logical_buttons\":true" +
        ",\"blocked_keys\":" + std::to_string(batch.blocked_keys) + ",\"blocked_buttons\":" + std::to_string(batch.blocked_buttons) +
        ",\"owned_keys\":" + std::to_string(batch.owned_keys) + ",\"owned_buttons\":" + std::to_string(batch.owned_buttons) +
        ",\"callback_entries\":" + std::to_string(callback_entries) + ",\"stale_callbacks\":" + std::to_string(stale_callbacks);
    const auto counter = [&](const char* name, std::uint64_t n) { text += ",\"" + std::string(name) + "\":" + std::to_string(n); };
    counter("message_count", batch.stats.messages); counter("consumed_count", batch.stats.consumed);
    counter("ignored_peeks", batch.stats.ignored_peeks); counter("foreign_messages", batch.stats.foreign_messages);
    counter("stale_messages", batch.stats.stale_messages); counter("repeats", batch.stats.repeats);
    counter("focus_resets", batch.stats.focus_resets); counter("context_resets", batch.stats.context_resets);
    counter("timeout_resets", batch.stats.timeout_resets); counter("overflow_resets", batch.stats.overflow_resets);
    counter("identity_resets", batch.stats.identity_resets); counter("swap_resets", batch.stats.swap_resets);
    counter("quarantine_resets", batch.stats.quarantine_resets);
    counter("coalesced_motion", batch.stats.coalesced_motion);
    text += ",\"samples\":[";
    for (std::size_t i = 0; i < batch.count; ++i) { if (i) text += ','; text += sample_json(batch.samples[i]); }
    text += "],\"latest\":" + sample_json(batch.latest) + '}';
    if (text.size() > 256 * 1024) throw std::runtime_error("item input event JSON exceeds 256 KiB");
    return text;
}
} // namespace PBZMC::ItemInput
