// Read-only preflight for a future game build, before UE4SS or PBZ starts.
#include <algorithm>
#include <iostream>
#include <Windows.h>
#include <bcrypt.h>
#include "host_locator.hpp"
#include "host_version.hpp"
#pragma comment(lib,"bcrypt.lib")
int wmain(int argc,wchar_t** argv) {
    std::uint32_t cl{};
    try {
        if(argc!=2) throw std::runtime_error("expected PBZ.exe path");
        cl=PBZMC::HostVersion::changelist(argv[1]);
        if(!cl) throw std::runtime_error("unrecognized game product or engine family");
        PBZMC::Locator::FileMap file(argv[1]);
        const auto bytes=file.bytes();
        PBZMC::Locator::check_loader(bytes);
        auto sha=[](std::string_view src) {
            std::array<unsigned char,32> result{};
            if(BCryptHash(BCRYPT_SHA256_ALG_HANDLE,nullptr,0,reinterpret_cast<PUCHAR>(const_cast<char*>(src.data())),
                static_cast<ULONG>(src.size()),result.data(),static_cast<ULONG>(result.size()))<0) throw std::runtime_error("cannot verify code SHA-256");
            static constexpr char hex[]="0123456789abcdef";std::string out;
            for(auto c:result) {out+=hex[c>>4];out+=hex[c&15];}return out;
        };
        auto locations=PBZMC::Locator::locate(bytes,nullptr,sha);
        std::cout<<"PBZMC-HOST: CL-"<<cl<<" matched both loader globals and all "<<locations.size()<<" native locations.\n";
        return 0;
    } catch(const std::exception& e) {
        std::cout<<"PBZMC-HOST: CL-"<<cl<<": "<<e.what()<<"\n";return 1;
    }
}
