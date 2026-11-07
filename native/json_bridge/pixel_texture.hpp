#pragma once

// UCanvasRenderTarget2D exposes UTexture::UpdateResource to reflection. Its
// zero-argument native thunk dispatches the inherited virtual, not canvas
// fields. Decode and validate that dispatch before using it on our transient
// UTexture2D. No fixed PBZ address or UTexture object layout is assumed.
namespace PixelTexture {
inline std::uint32_t dispatch_slot(std::span<const unsigned char> code) {
    constexpr unsigned char prefix[]{
        0x48,0x8b,0x42,0x20,0x45,0x33,0xc0,0x48,0x85,0xc0,
        0x41,0x0f,0x95,0xc0,0x4c,0x03,0xc0,0x4c,0x89,0x42,0x20,
        0x48,0x8b,0x01,0x48,0xff,0xa0};
    if (code.size()!=31 || !std::equal(std::begin(prefix),std::end(prefix),code.begin()))
        throw std::runtime_error("pixel texture UpdateResource thunk is incompatible; report this PBZ version");
    std::uint32_t slot{};std::memcpy(&slot,code.data()+sizeof(prefix),sizeof(slot));
    if (slot<0x100 || slot>0x1000 || slot%sizeof(void*)!=0)
        throw std::runtime_error("pixel texture UpdateResource virtual slot is invalid");
    return slot;
}

inline void readable(const void* p,std::size_t size) {
    MEMORY_BASIC_INFORMATION m{};
    require(VirtualQuery(p,&m,sizeof(m))==sizeof(m) && m.State==MEM_COMMIT &&
        !(m.Protect&(PAGE_NOACCESS|PAGE_GUARD)) &&
        reinterpret_cast<std::uintptr_t>(p)-reinterpret_cast<std::uintptr_t>(m.BaseAddress)+size<=m.RegionSize,
        "pixel texture resource memory is not readable");
}

inline std::uint32_t update_slot() {
    static const auto slot=[] {
        auto* object=find_object(L"/Script/Engine.CanvasRenderTarget2D:UpdateResource");
        require(object->GetFullName()==L"Function /Script/Engine.CanvasRenderTarget2D:UpdateResource",
                "pixel texture UpdateResource reflection changed");
        auto* fn=reinterpret_cast<UFunction*>(object);
        require(fn->GetParmsSize()==0 && fn->GetNumParms()==0 && fn->GetReturnValueOffset()==0xffff,
                "pixel texture UpdateResource signature changed");
        const auto module=GetModuleHandleW(nullptr);
        const auto native=reinterpret_cast<std::uintptr_t>(fn->GetFuncPtr());
        const auto base=reinterpret_cast<std::uintptr_t>(module);
        require(native>=base && native-base<=UINT32_MAX,"pixel texture thunk is outside PBZ");
        return dispatch_slot(PBZMC::Locator::live_bytes(module,static_cast<std::uint32_t>(native-base),31));
    }();
    return slot;
}

inline int refresh(const Lua& lua) {
    try {
        require(IsInGameThread(),"pixel texture refresh must run on the game thread");
        require(lua.get_stack_size()==1 && lua.is_string(1),"pixel texture refresh expects one transient texture path");
        const std::string path(lua.get_string(1));
        constexpr std::string_view prefix="/Engine/Transient.Texture2D_";
        require(path.starts_with(prefix) && path.size()>prefix.size() && path.size()<128 &&
            std::all_of(path.begin()+prefix.size(),path.end(),[](char c){return c>='0'&&c<='9';}),
            "pixel texture refresh only accepts imported transient Texture2D objects");
        auto* texture=find_object(from_utf8(path).c_str());
        require(!texture->IsUnreachable() && texture->GetFullName()==L"Texture2D "+from_utf8(path),
                "pixel texture identity is no longer valid");
        static const auto* filter=class_property(L"/Script/Engine.Texture",L"Filter");
        require(property_kind(filter)==L"ByteProperty" && filter->GetSize()==1 && filter->GetArrayDim()==1 &&
            filter->GetOffset_Internal()>0 && filter->GetOffset_Internal()<4096,"pixel texture filter schema changed");
        const auto* value=reinterpret_cast<const unsigned char*>(texture)+filter->GetOffset_Internal();
        readable(value,1);require(*value==0,"pixel texture must select nearest filtering before refresh");
        const auto slot=update_slot();
        readable(texture,sizeof(void*));const auto* table=*reinterpret_cast<const unsigned char* const*>(texture);
        readable(table+slot,sizeof(void*));std::uintptr_t target{};std::memcpy(&target,table+slot,sizeof(target));
        const auto module=GetModuleHandleW(nullptr);const auto base=reinterpret_cast<std::uintptr_t>(module);
        require(target>=base && target-base<=UINT32_MAX,"pixel texture update target is outside PBZ");
        PBZMC::Locator::live_bytes(module,static_cast<std::uint32_t>(target-base),1);
        reinterpret_cast<void (*)(UObject*)>(target)(texture);
        lua.set_bool(true);lua.set_nil();
    } catch(const std::exception& e) {
        lua.set_nil();lua.set_string(std::string("PBZMC pixel texture: ")+e.what());
    }
    return 2;
}
}
