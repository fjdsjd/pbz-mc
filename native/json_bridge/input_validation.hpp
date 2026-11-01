#pragma once

#include <cstddef>
#include <stdexcept>
#include <string>
#include <string_view>

namespace PBZMC::Validation {
inline constexpr std::size_t advanced_path_limit = 4096;
inline constexpr std::wstring_view transient_prefix = L"/Engine/Transient.";
inline constexpr std::size_t preview_path_limit = 4096;

// Pure input guards, shared with the standalone offline test. Object lookup
// and engine type checks remain in the bridge's game-thread-only native path.
inline void advanced_subsystem_path(std::wstring_view path) {
    if (path.size() <= transient_prefix.size() || path.size() > advanced_path_limit ||
        !path.starts_with(transient_prefix)) {
        throw std::runtime_error("advanced subsystem path must be under /Engine/Transient. and at most 4096 characters");
    }
    if (path.find(L"Default__") != std::wstring_view::npos) {
        throw std::runtime_error("class default objects are not accepted");
    }
    for (const auto character : path) {
        if (character <= L' ' || character == L'\x7f') {
            throw std::runtime_error("subsystem paths must not contain NUL, whitespace, or control characters");
        }
    }
}

inline void advanced_subsystem_identity(std::wstring_view actual_full_name, std::wstring_view path) {
    if (actual_full_name != std::wstring(L"PBZSaveLoadSubsystem ") + std::wstring(path)) {
        throw std::runtime_error("path must identify exactly the current PBZSaveLoadSubsystem object");
    }
}

inline bool preview_space_or_control(wchar_t c) {
    return c <= L' ' || (c >= L'\x7f' && c <= L'\x9f') || c == L'\xa0' || c == L'\x1680' ||
           (c >= L'\x2000' && c <= L'\x200a') || c == L'\x2028' || c == L'\x2029' ||
           c == L'\x202f' || c == L'\x205f' || c == L'\x3000';
}

// Only the world/actor shape actually produced by this preview is accepted.
// This is an object/type boundary, not proof of mod ownership. The caller must
// verify its own current actor/component identity immediately before this call.
inline std::wstring preview_component_actor_path(std::wstring_view path) {
    constexpr std::wstring_view marker = L":PersistentLevel.SceneCapture2D_";
    if (path.empty() || path.size() > preview_path_limit || !path.starts_with(L"/Game/"))
        throw std::runtime_error("preview component path must be under /Game/ and contain 1..4096 characters");
    if (path.find(L"Default__") != std::wstring_view::npos)
        throw std::runtime_error("class default objects are not accepted");
    for (const auto c : path) {
        if (preview_space_or_control(c) || std::wstring_view(L"\\\"'(),;=[]*?#").find(c) != std::wstring_view::npos)
            throw std::runtime_error("preview paths must not contain controls, whitespace, or expression delimiters");
    }
    const auto at = path.find(marker);
    if (at == std::wstring_view::npos || at <= 6 || path.find(L':') != at ||
        path.find(marker, at + marker.size()) != std::wstring_view::npos)
        throw std::runtime_error("preview path must identify a numbered SceneCapture2D in PersistentLevel");
    const auto number = at + marker.size();
    const auto separator = path.find(L'.', number);
    if (separator == std::wstring_view::npos || separator == number || separator + 1 == path.size())
        throw std::runtime_error("preview path requires a numbered actor and a component name");
    for (auto i = number; i < separator; ++i)
        if (path[i] < L'0' || path[i] > L'9') throw std::runtime_error("preview actor suffix must be numeric");
    for (auto i = separator + 1; i < path.size(); ++i) {
        const auto c = path[i];
        if (!((c >= L'a' && c <= L'z') || (c >= L'A' && c <= L'Z') || (c >= L'0' && c <= L'9') || c == L'_'))
            throw std::runtime_error("preview component name must be one plain object-name token");
    }
    return std::wstring(path.substr(0, separator));
}

inline void preview_component_identity(std::wstring_view actual_full_name, std::wstring_view path) {
    if (actual_full_name != std::wstring(L"SceneCaptureComponent2D ") + std::wstring(path))
        throw std::runtime_error("path must identify exactly a SceneCaptureComponent2D object");
}

inline void preview_actor_identity(std::wstring_view actual_full_name, std::wstring_view actor_path) {
    if (actual_full_name != std::wstring(L"SceneCapture2D ") + std::wstring(actor_path))
        throw std::runtime_error("preview component must belong to exactly a SceneCapture2D actor");
}
} // namespace PBZMC::Validation
