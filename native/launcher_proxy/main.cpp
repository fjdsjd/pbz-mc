// SPDX-License-Identifier: MIT
// DWM forwarding scheme adapted from UE4SS (cdbc0b66) proxy_generator,
// Copyright (c) 2022 Narknon. See LICENSE and README.md in this directory.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <Windows.h>
#include <shellapi.h>
#include <cstdint>
#include <string>
#include "launch_policy.hpp"
#include "proxy_exports.inc"

// Checked by the release packager; prevents packaging the always-on upstream
// proxy by mistake. This exported policy function has no side effects.
extern "C" __declspec(dllexport) const char* PBZMCLaunchPolicy() noexcept {
    return "PBZMC_LAUNCH_OPT_IN_V1";
}

[[noreturn]] static void fail(const wchar_t* message) {
    MessageBoxW(nullptr, message, L"PBZMC launcher", MB_OK | MB_ICONERROR);
    ExitProcess(ERROR_DLL_INIT_FAILED);
}

static std::wstring module_directory(HMODULE self) {
    std::wstring path(32768, L'\0');
    const DWORD length = GetModuleFileNameW(self, path.data(), static_cast<DWORD>(path.size()));
    if (!length || length >= path.size()) fail(L"Cannot resolve the PBZMC installation directory.");
    path.resize(length);
    const auto slash = path.find_last_of(L"\\/");
    if (slash == std::wstring::npos) fail(L"Cannot resolve the PBZMC installation directory.");
    path.resize(slash + 1);
    return path;
}

BOOL WINAPI DllMain(HMODULE self, DWORD reason, LPVOID) {
    if (reason != DLL_PROCESS_ATTACH) return TRUE;
    DisableThreadLibraryCalls(self);
    wchar_t system[MAX_PATH + 1]{};
    const UINT length = GetSystemDirectoryW(system, MAX_PATH + 1);
    if (!length || length > MAX_PATH) fail(L"Cannot locate the Windows DWM library.");
    const auto original = LoadLibraryW((std::wstring(system, length) + L"\\dwmapi.dll").c_str());
    if (!original || original == self) fail(L"Cannot load the Windows DWM library.");
    setup_forwarders(original);

    int argc = 0;
    auto argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    const bool enabled = argv && pbzmc::mod_launch_requested(argc, argv);
    if (argv) LocalFree(argv);
    if (!enabled) return TRUE;

    // Only the verified package beside this proxy may be loaded. Do not honor
    // override.txt, arbitrary working directories or --ue4ss-path overrides.
    const auto loader = module_directory(self) + L"ue4ss\\UE4SS.dll";
    if (!LoadLibraryW(loader.c_str())) {
        fail(L"PBZMC could not load ue4ss\\UE4SS.dll. Close the game and run Launch-PBZMC.cmd again to verify the installation. Steam Play can still start the unmodded game.");
    }
    return TRUE;
}
