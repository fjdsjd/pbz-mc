#pragma once
#include <Windows.h>
#include "campaign_json.hpp"

namespace PBZMC::JsonText {
enum class Use { probe, save };
inline void check_units(std::size_t units, Use use) {
    if (use == Use::save) Campaign::check_limit(units,Campaign::root_limit,"expanded save JSON (UTF-16 code units)");
    else Campaign::require(units<=256*1024,"native output exceeds the probe bound");
}
// Check the native length before dereferencing its character buffer. A bad
// FString or conversion is distinct from a valid save exceeding a budget.
template<class NativeString>
std::wstring_view view(const NativeString& value, Use use) {
    const auto length=value.Len();
    Campaign::require(length>=0,"native FString has a negative length");
    check_units(static_cast<std::size_t>(length),use);
    const auto* chars=*value;
    Campaign::require(chars || length==0,"native FString has a null character view");
    if (!length) return {};
    Campaign::require(chars[length]==L'\0',"native FString lacks its expected terminator");
    return {chars,static_cast<std::size_t>(length)};
}
inline std::string to_utf8(std::wstring_view text,Use use=Use::probe) {
    check_units(text.size(),use);
    const auto units=static_cast<int>(text.size());
    const int bytes=WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,text.data(),units,nullptr,0,nullptr,nullptr);
    Campaign::require(bytes>0,"native output is empty or invalid UTF-16");
    if (use==Use::save) Campaign::check_limit(bytes,Campaign::root_limit,"expanded save JSON (UTF-8 bytes)");
    std::string result(bytes,'\0');
    Campaign::require(WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,text.data(),units,result.data(),bytes,nullptr,nullptr)==bytes,
        "UTF-16 conversion failed");
    return result;
}
} // namespace PBZMC::JsonText
