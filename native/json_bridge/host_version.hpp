#pragma once
#include <Windows.h>
#include <cstdint>
#include <string>
#include <string_view>
#include <vector>
#pragma comment(lib,"version.lib")

namespace PBZMC::HostVersion {
// Use the translated strings declared by the executable, not the Windows UI
// language. Reject a renamed executable or an incompatible engine family.
inline std::uint32_t changelist(const wchar_t* path) {
    DWORD unused{};const auto size=GetFileVersionInfoSizeW(path,&unused);
    if(!size || size>1024*1024) return 0;
    std::vector<unsigned char> data(size);
    if(!GetFileVersionInfoW(path,0,size,data.data())) return 0;
    UINT n{};void* value{};
    if(!VerQueryValueW(data.data(),L"\\",&value,&n) || n<sizeof(VS_FIXEDFILEINFO)) return 0;
    const auto* info=static_cast<const VS_FIXEDFILEINFO*>(value);
    if(info->dwSignature!=VS_FFI_SIGNATURE || info->dwFileVersionMS!=MAKELONG(7,5)) return 0;
    struct Translation{WORD language,page;};
    if(!VerQueryValueW(data.data(),L"\\VarFileInfo\\Translation",&value,&n) || n<sizeof(Translation)) return 0;
    const auto first=*static_cast<const Translation*>(value);
    wchar_t prefix[48]{};
    swprintf_s(prefix,L"\\StringFileInfo\\%04x%04x\\",first.language,first.page);
    const auto field=[&](const wchar_t* name)->std::wstring_view {
        const auto key=std::wstring(prefix)+name;
        if(!VerQueryValueW(data.data(),key.c_str(),&value,&n) || n<1) return {};
        const auto* s=static_cast<const wchar_t*>(value);
        if(s[n-1]!=L'\0') return {};
        return {s,n-1};
    };
    if(field(L"ProductName")!=L"Phantom Blade Zero" || field(L"CompanyName")!=L"S-GAME" ||
       field(L"InternalName")!=L"ProjectPBZ" || field(L"OriginalFilename")!=L"PBZ.exe") return 0;
    const auto version=field(L"FileVersion");const auto split=version.find(L"_JKS-");
    if(!version.starts_with(L"CL-") || split==std::wstring_view::npos || split<=3 || split>12 || split+5>=version.size()) return 0;
    std::uint32_t cl{};
    for(auto c:version.substr(3,split-3)) {if(c<L'0'||c>L'9') return 0;cl=cl*10+c-L'0';}
    for(auto c:version.substr(split+5)) if(c<L'0'||c>L'9') return 0;
    return cl;
}
}
