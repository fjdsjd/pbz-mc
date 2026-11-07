#pragma once
#include "../../third_party/minhook-1.3.4/include/MinHook.h"

namespace PBZMC::ItemInput {
// Same-process public Win32 API, no PBZ offsets or executable patches. Capture
// pins this DLL before installation; the trampoline remains valid until exit.
// EndItemInput disables all work and filtering without racing live callbacks.
class RawInputHooks {
    using Read=UINT(WINAPI*)(PRAWINPUT,PUINT,UINT);
    using ReadData=UINT(WINAPI*)(HRAWINPUT,UINT,LPVOID,PUINT,UINT);
    inline static Read original_{};
    inline static ReadData original_data_{};
    inline static void* address_{};
    inline static void* data_address_{};
    inline static bool installed_{};
    static UINT WINAPI intercept(PRAWINPUT data,PUINT size,UINT header) noexcept {
        const UINT capacity=data && size ? *size : 0;
        const auto count=original_(data,size,header);
        const auto error=GetLastError();
        Capture::instance().filter_raw_buffer(data,capacity,count,header);
        SetLastError(error);
        return count;
    }
    static UINT WINAPI intercept_data(HRAWINPUT handle,UINT command,LPVOID data,PUINT size,UINT header) noexcept {
        const UINT capacity=data && size ? *size : 0;
        const auto bytes=original_data_(handle,command,data,size,header);
        const auto error=GetLastError();
        if(command==RID_INPUT)
            Capture::instance().filter_raw_data(handle,data,capacity,bytes,header,static_cast<DWORD>(GetMessageTime()));
        SetLastError(error);
        return bytes;
    }
public:
    static void ensure() {
        if(installed_)return;
        const auto init=MH_Initialize();
        if(init!=MH_OK && init!=MH_ERROR_ALREADY_INITIALIZED)throw std::runtime_error("PBZMC-INPUT: raw buffer hook initialize failed");
        if(!address_) {
            auto* address=reinterpret_cast<void*>(GetProcAddress(GetModuleHandleW(L"user32.dll"),"GetRawInputBuffer"));
            if(!address || MH_CreateHook(address,reinterpret_cast<void*>(&intercept),reinterpret_cast<void**>(&original_))!=MH_OK)
                throw std::runtime_error("PBZMC-INPUT: raw buffer capture unavailable; report UE4SS.log");
            address_=address;
        }
        if(!data_address_) {
            auto* address=reinterpret_cast<void*>(GetProcAddress(GetModuleHandleW(L"user32.dll"),"GetRawInputData"));
            if(!address || MH_CreateHook(address,reinterpret_cast<void*>(&intercept_data),reinterpret_cast<void**>(&original_data_))!=MH_OK)
                throw std::runtime_error("PBZMC-INPUT: raw mouse capture unavailable; report UE4SS.log");
            data_address_=address;
        }
        // Activate both without changing any other hooks in this process.
        if(MH_QueueEnableHook(address_)!=MH_OK || MH_QueueEnableHook(data_address_)!=MH_OK || MH_ApplyQueued()!=MH_OK)
            throw std::runtime_error("PBZMC-INPUT: raw mouse hooks enable failed");
        installed_=true;
    }
};
}
