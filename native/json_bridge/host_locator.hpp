#pragma once
#include <Windows.h>
#include <algorithm>
#include <array>
#include <cstdint>
#include <cstring>
#include <optional>
#include <span>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

namespace PBZMC::Locator {
inline void need(bool value,const char* why) { if (!value) throw std::runtime_error(why); }
using Bytes=std::span<const unsigned char>;
struct MaskRange { unsigned short offset,length; };
struct Fingerprint {
    unsigned short size,entry_offset;
    std::uint64_t fast;
    std::string_view sha256;
    std::span<const MaskRange> relocations;
};
#include "host_fingerprints.hpp"
inline constexpr const char* names[]{"TakeDamage","ApplyHealth","ModifyAttribute","TryActivateNewState","PendingState A","PendingState B"};
using Addresses=std::array<std::uint32_t,6>;

class FileMap {
    HANDLE file_{INVALID_HANDLE_VALUE},mapping_{};
    const unsigned char* data_{};
    std::size_t size_{};
    void close() { if(data_) UnmapViewOfFile(data_);if(mapping_) CloseHandle(mapping_);if(file_!=INVALID_HANDLE_VALUE) CloseHandle(file_); }
public:
    explicit FileMap(const wchar_t* path) {
        try {
            file_=CreateFileW(path,GENERIC_READ,FILE_SHARE_READ,nullptr,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,nullptr);
            LARGE_INTEGER n{};need(file_!=INVALID_HANDLE_VALUE && GetFileSizeEx(file_,&n) && n.QuadPart>0 && n.QuadPart<=UINT32_MAX,"cannot read PBZ executable");
            size_=static_cast<std::size_t>(n.QuadPart);
            mapping_=CreateFileMappingW(file_,nullptr,PAGE_READONLY,0,0,nullptr);need(mapping_!=nullptr,"cannot map PBZ executable");
            data_=static_cast<const unsigned char*>(MapViewOfFile(mapping_,FILE_MAP_READ,0,0,0));need(data_!=nullptr,"cannot view PBZ executable");
        } catch (...) {close();throw;}
    }
    FileMap(const FileMap&)=delete;
    FileMap& operator=(const FileMap&)=delete;
    ~FileMap() {close();}
    Bytes bytes() const {return {data_,size_};}
};

template<class T> T pod(Bytes file,std::size_t off) {
    need(off<=file.size() && sizeof(T)<=file.size()-off,"invalid PE metadata range");
    T out{};std::memcpy(&out,file.data()+off,sizeof(out));return out;
}
struct Section {std::uint32_t rva,raw,size,virtual_size,flags;};
class Image {
    Bytes file_;
    std::vector<Section> sections_;
public:
    Bytes functions;
    explicit Image(Bytes file):file_(file) {
        auto dos=pod<IMAGE_DOS_HEADER>(file,0);
        need(dos.e_magic==IMAGE_DOS_SIGNATURE && dos.e_lfanew>0,"invalid PBZ DOS header");
        const auto nt=static_cast<std::size_t>(dos.e_lfanew);
        const auto pe=pod<IMAGE_NT_HEADERS64>(file,nt);
        need(pe.Signature==IMAGE_NT_SIGNATURE && pe.FileHeader.Machine==IMAGE_FILE_MACHINE_AMD64 &&
             pe.OptionalHeader.Magic==IMAGE_NT_OPTIONAL_HDR64_MAGIC && pe.FileHeader.SizeOfOptionalHeader>=sizeof(IMAGE_OPTIONAL_HEADER64) &&
             pe.OptionalHeader.NumberOfRvaAndSizes>IMAGE_DIRECTORY_ENTRY_EXCEPTION &&
             pe.FileHeader.NumberOfSections>0 && pe.FileHeader.NumberOfSections<=96,"unsupported PBZ PE layout");
        const auto first=nt+offsetof(IMAGE_NT_HEADERS64,OptionalHeader)+pe.FileHeader.SizeOfOptionalHeader;
        for (unsigned i=0;i<pe.FileHeader.NumberOfSections;++i) {
            const auto s=pod<IMAGE_SECTION_HEADER>(file,first+i*sizeof(IMAGE_SECTION_HEADER));
            need(s.PointerToRawData<=file.size() && s.SizeOfRawData<=file.size()-s.PointerToRawData,"invalid PBZ section range");
            sections_.push_back({s.VirtualAddress,s.PointerToRawData,s.SizeOfRawData,s.Misc.VirtualSize,s.Characteristics});
        }
        const auto dir=pe.OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXCEPTION];
        need(dir.Size>0 && dir.Size%sizeof(RUNTIME_FUNCTION)==0 && dir.Size/sizeof(RUNTIME_FUNCTION)<=2000000,"invalid x64 function directory");
        functions=at(dir.VirtualAddress,dir.Size,false);need(!functions.empty(),"x64 function directory outside file");
    }
    Bytes at(std::uint32_t rva,std::size_t size,bool executable=true) const {
        for (const auto& s:sections_) {
            if(rva<s.rva || (executable && !(s.flags&IMAGE_SCN_MEM_EXECUTE))) continue;
            const auto d=rva-s.rva;
            if (d<=s.size && size<=s.size-d) return file_.subspan(static_cast<std::size_t>(s.raw)+d,size);
        }
        return {};
    }
    void loader_global(std::string_view name,std::span<const int> pattern,std::size_t anchor,
                       std::size_t instruction,int adjust) const {
        std::size_t count{};std::int64_t address{};
        for(const auto& section:sections_) {
            if(!(section.flags&IMAGE_SCN_MEM_EXECUTE) || section.size<pattern.size()) continue;
            auto code=file_.subspan(section.raw,section.size);
            std::size_t next=anchor;
            while(next<code.size()) {
                auto hit=static_cast<const unsigned char*>(std::memchr(code.data()+next,pattern[anchor],code.size()-next));
                if(!hit) break;
                next=static_cast<std::size_t>(hit-code.data())+1;
                const auto start=next-1-anchor;
                if(pattern.size()>code.size()-start) break;
                bool equal=true;
                for(std::size_t j=0;j<pattern.size();++j)
                    if(pattern[j]>=0 && code[start+j]!=pattern[j]) {equal=false;break;}
                if(equal) {
                    ++count;const auto op=start+instruction;
                    address=static_cast<std::int64_t>(section.rva)+static_cast<std::int64_t>(op)+7+pod<std::int32_t>(code,op+3)+adjust;
                }
            }
        }
        if(count!=1) throw std::runtime_error(std::string(name)+": expected 1 loader match, found "+std::to_string(count));
        for(const auto& s:sections_) if((s.flags&IMAGE_SCN_MEM_WRITE) && address>=s.rva &&
                address-s.rva<std::max(s.size,s.virtual_size)) return;
        throw std::runtime_error(std::string(name)+": expected writable engine global");
    }
};
// The two custom UE4SS signatures shipped in distribution/loader. Check
// before starting Steam, since an unsupported loader may never start Lua.
inline void check_loader(Bytes file) {
    static constexpr int natives[]{0x48,0x8d,5,-1,-1,-1,-1,0x48,0x39,5,-1,-1,-1,-1,0x48,0x8d,5,-1,-1,-1,-1,0x48,0x89,5,-1,-1,-1,-1,0x74,-1,0xc7,5,-1,-1,-1,-1,0,0,0,0,0xc3};
    static constexpr int objects[]{0x48,0x8d,0x0d,-1,-1,-1,-1,0xe8,-1,-1,-1,-1,0xe8,-1,-1,-1,-1,0xe8,-1,-1,-1,-1,0xc6,5,-1,-1,-1,-1,1};
    Image image(file);
    image.loader_global("GNatives",natives,std::size(natives)-1,0x15,0);
    image.loader_global("GUObjectArray",objects,22,0,-16);
}

template<class Digest> bool matches(Bytes b,const Fingerprint& key,Digest& digest) {
    if (b.size()!=key.size) return false;
    std::array<unsigned char,1024> normalized;
    need(b.size()<=normalized.size(),"invalid fingerprint size");
    std::memcpy(normalized.data(),b.data(),b.size());
    for(const auto& m:key.relocations) {
        need(m.offset<=b.size() && m.length<=b.size()-m.offset,"invalid fingerprint relocation");
        std::memset(normalized.data()+m.offset,0,m.length);
    }
    std::uint64_t quick=14695981039346656037ull;
    for(std::size_t i=0;i<b.size();++i) quick=(quick^normalized[i])*1099511628211ull;
    return quick==key.fast && digest(std::string_view(reinterpret_cast<const char*>(normalized.data()),b.size()))==key.sha256;
}
// A future executable must have one complete matching function range per
// entry. Before installing anything also verify the loaded bytes and both
// actual direct call targets. The file mapping is released after startup.
inline Bytes live_bytes(HMODULE module,std::uint32_t rva,std::size_t n) {
    auto ptr=reinterpret_cast<const unsigned char*>(module)+rva;
    MEMORY_BASIC_INFORMATION m{};
    need(VirtualQuery(ptr,&m,sizeof(m))==sizeof(m) && m.AllocationBase==module && m.State==MEM_COMMIT &&
         !(m.Protect&PAGE_GUARD) && (m.Protect&(PAGE_EXECUTE_READ|PAGE_EXECUTE_READWRITE|PAGE_EXECUTE_WRITECOPY)) &&
         reinterpret_cast<std::uintptr_t>(ptr)-reinterpret_cast<std::uintptr_t>(m.BaseAddress)+n<=m.RegionSize,"loaded PBZ code is not readable executable memory");
    return {ptr,n};
}
template<class Digest> Addresses locate(Bytes file,HMODULE loaded,Digest digest) {
    const Image image(file);Addresses out{};std::array<unsigned,6> counts{};
    for (std::size_t at=0;at<image.functions.size();at+=sizeof(RUNTIME_FUNCTION)) {
        const auto f=pod<RUNTIME_FUNCTION>(image.functions,at);
        if (f.EndAddress<=f.BeginAddress) continue;
        for (std::size_t k=0;k<out.size();++k) {
            const auto& signature=fingerprints[k];
            if (f.EndAddress-f.BeginAddress!=signature.size) continue;
            if (matches(image.at(f.BeginAddress,signature.size),signature,digest)) {
                ++counts[k];out[k]=f.BeginAddress+signature.entry_offset;
            }
        }
    }
    for(std::size_t k=0;k<out.size();++k) {
        if(counts[k]!=1) throw std::runtime_error(std::string(names[k])+": expected 1 match, found "+std::to_string(counts[k]));
        const auto& s=fingerprints[k];
        if(loaded && !matches(live_bytes(loaded,out[k]-s.entry_offset,s.size),s,digest))
            throw std::runtime_error(std::string(names[k])+": loaded code differs");
    }
    for(const auto k:{4,5}) {
        const auto verify_call=[&](Bytes b) {
            return b.size()==5 && b[0]==0xe8 && static_cast<std::int64_t>(out[k])+pod<std::int32_t>(b,1)==out[3];
        };
        if (!verify_call(image.at(out[k]-5,5)) || (loaded && !verify_call(live_bytes(loaded,out[k]-5,5))))
            throw std::runtime_error(std::string(names[k])+": state call target differs");
    }
    return out;
}
} // namespace PBZMC::Locator
