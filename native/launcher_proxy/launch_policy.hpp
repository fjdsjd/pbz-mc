// SPDX-License-Identifier: MIT
#pragma once
#include <string_view>

namespace pbzmc {
// Per-process opt-in. No registry, environment variable, marker file or cached
// state can enable a subsequent Steam launch. The upstream disable flag wins.
inline bool mod_launch_requested(int argc, const wchar_t* const* argv) noexcept {
    bool requested = false;
    for (int i = 1; i < argc; ++i) {
        const std::wstring_view arg = argv[i] ? argv[i] : L"";
        if (arg == L"--disable-ue4ss") return false;
        if (arg == L"--pbzmc") requested = true;
    }
    return requested;
}
}
