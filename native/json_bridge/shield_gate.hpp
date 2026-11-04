// The pinned native AttributeComponent::TakeDamage entry, before calculation,
// HP modification and DamageTaken dispatch. ABI proof: shield-takedamage-*.json.
// No FFrame/Blueprint exec hook, global invulnerability or post-damage healing.
#pragma once

namespace ShieldGate {
struct Vector { double x,y,z; };
using Damage = void(*)(UObject*,const void*,const void*,const Vector*,const void*,const void*,const void*,UObject*,const Vector*,const Vector*,void*);
inline Damage original{};
inline std::mutex mutex;
inline UObject* owner{};
inline std::wstring owner_name;
inline std::string lease;
inline double facing_x{},facing_y{};
inline bool active{};
inline ULONGLONG heartbeat{};
inline DWORD game_thread{};
inline const FProperty* final_map{};
inline std::atomic_uint64_t blocked{},passed{},block_sounds{},sound_failures{};

inline void clear() noexcept { std::lock_guard lock(mutex);active=false;owner=nullptr;owner_name.clear();lease.clear(); }

inline void intercept(UObject* component,const void* source,const void* cause,const Vector* hit,const void* body,
    const void* attributes,const void* attack,UObject* calculator,const Vector* direction,const Vector* sweep,void* result) {
    bool block=false;
    {
        std::lock_guard lock(mutex);
        const int button=GetSystemMetrics(SM_SWAPBUTTON)?VK_LBUTTON:VK_RBUTTON;
        DWORD foreground_pid{};GetWindowThreadProcessId(GetForegroundWindow(),&foreground_pid);
        if(active && component==owner && GetCurrentThreadId()==game_thread && GetTickCount64()-heartbeat<=250
            && foreground_pid==GetCurrentProcessId() && (GetAsyncKeyState(button)&0x8000) && source && result && direction) {
            // PBZ supplies travel direction, so a frontal strike points against
            // the player's look vector. Vertical/environmental damage has no
            // horizontal incoming direction and is deliberately not blocked.
            const double length=std::hypot(direction->x,direction->y);
            block=std::isfinite(length) && length>1e-6 && std::isfinite(direction->z)
                && (direction->x*facing_x+direction->y*facing_y)/length < -1e-6
                && !component->IsUnreachable() && component->GetFullName()==owner_name;
        }
    }
    if(block && cause) {
        const auto tag=reinterpret_cast<const FName*>(cause)->ToString();
        if(tag==L"Damage.Cause.MCFall"||tag==L"Damage.Cause.MCFlyIntoWall")block=false;
    }
    if(block) {
        // Native and Blueprint callers both supply a constructed out TMap.
        // Empty it using its reflected property, never guess a TMap layout.
        final_map->DestroyValue(result);final_map->InitializeValue(result);
        ++blocked;
        if(BlockAudio::shield_hit()) ++block_sounds;else ++sound_failures;
        return;
    }
    ++passed;
    HealthGate::DamageScope health_scope(cause);
    original(component,source,cause,hit,body,attributes,attack,calculator,direction,sweep,result);
}

inline void install() {
    static std::once_flag once;
    std::call_once(once,[] {
        verify_pinned_abi();
        auto* base=reinterpret_cast<unsigned char*>(GetModuleHandleW(nullptr));
        const auto& build=verified_host_build();
        constexpr std::array<ExpectedParameter,10> expected_parameters{{
             {L"DamageSource",L"InterfaceProperty"},{L"DamageCause",L"StructProperty"},{L"HitLocation",L"StructProperty"},
             {L"HitBody",L"StructProperty"},{L"AttackerAttributes",L"MapProperty"},{L"AttackData",L"MapProperty"},
             {L"CustomCalculator",L"ObjectProperty"},{L"AttackDirection",L"StructProperty"},{L"SweepDirection",L"StructProperty"},
             {L"FinalDamageData",L"MapProperty"}}};
        const auto schema=inspect_signature(L"/Script/SGameAttributes.AttributeComponent:TakeDamage",expected_parameters);
        require(schema.size==360 && schema.at(L"AttackDirection").offset==232 && schema.at(L"FinalDamageData").offset==280,
            "shield damage ABI changed");
        final_map=schema.at(L"FinalDamageData").property;
        const auto init=MH_Initialize();require(init==MH_OK||init==MH_ERROR_ALREADY_INITIALIZED,"shield hook initialize");
        auto* address=base+build.take_damage;
        // Preserve the verified unmodified function entry before MinHook owns it.
        constexpr unsigned char prefix[]{0x40,0x55,0x56,0x57,0x41,0x54,0x41,0x55,0x41,0x56,0x41,0x57};
        require(std::memcmp(address,prefix,sizeof(prefix))==0,"shield entry differs from ABI proof");
        auto created=MH_CreateHook(address,reinterpret_cast<void*>(&intercept),reinterpret_cast<void**>(&original));
        if(created==MH_ERROR_MEMORY_ALLOC)
            created=MH_CreatePBZDamageHook(address,reinterpret_cast<void*>(&intercept),reinterpret_cast<void**>(&original));
        if(created!=MH_OK)throw std::runtime_error(std::string("shield hook create: ")+MH_StatusToString(created));
        HMODULE pinned{};
        require(GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS|GET_MODULE_HANDLE_EX_FLAG_PIN,
            reinterpret_cast<LPCWSTR>(&intercept),&pinned)!=FALSE,"shield callback pin");
        require(MH_EnableHook(address)==MH_OK,"shield hook enable");
    });
}

inline std::string set(const std::string& input) {
    using Json=nlohmann::json;
    require(input.size()<=8192,"shield input too large");const auto data=Json::parse(input);
    require(IsInGameThread(),"shield state requires game thread");
    require(data.is_object()&&data.contains("active")&&data["active"].is_boolean(),"shield state schema");
    if(data.value("prepare",false)) install();
    if(!data["active"].get<bool>()){
        std::lock_guard lock(mutex);
        if(data.value("lease",std::string{})==lease){active=false;owner=nullptr;owner_name.clear();lease.clear();}
        return Json{{"active",active},{"blocked",blocked.load()},{"passed",passed.load()},
            {"block_sounds",block_sounds.load()},{"sound_failures",sound_failures.load()}}.dump();
    }
    install();
    const auto path=from_utf8(data.at("component").get<std::string>());
    const double x=data.at("x").get<double>(),y=data.at("y").get<double>();
    const auto token=data.at("lease").get<std::string>();require(!token.empty()&&token.size()<=128,"shield lease required");
    require(std::isfinite(x)&&std::isfinite(y)&&std::abs(x*x+y*y-1)<.001,"shield invalid view vector");
    auto* component=find_object(path.c_str());
    const auto name=component->GetFullName();
    require(name.starts_with(L"AttributeComponent ")&&!component->IsUnreachable(),"shield requires live AttributeComponent");
    std::lock_guard lock(mutex);
    owner=component;owner_name=name;lease=token;facing_x=x;facing_y=y;game_thread=GetCurrentThreadId();heartbeat=GetTickCount64();active=true;
    return Json{{"active",true},{"blocked",blocked.load()},{"passed",passed.load()},
        {"block_sounds",block_sounds.load()},{"sound_failures",sound_failures.load()}}.dump();
}
inline int lua_set(const Lua& lua) {
    try {
        require(lua.get_stack_size()==1&&lua.is_string(1),"usage: PBZMC_ShieldState(json)");
        lua.set_string(set(std::string(lua.get_string(1))));lua.set_nil();
    } catch(const std::exception& error){clear();lua.set_nil();lua.set_string(std::string("PBZMC shield: ")+error.what());}
    return 2;
}

// Bounded developer scene setup: invokes the SAME native entry as PBZ attacks,
// bypassing Blueprint exec. It does not turn the shield on or decide the result.
inline int lua_dev_hit(const Lua& lua) {
    try {
        require(lua.get_stack_size()==1&&lua.is_string(1)&&IsInGameThread(),"developer shield hit requires game thread JSON");
        const auto data=nlohmann::json::parse(std::string(lua.get_string(1)));
        install();
        auto* pawn=find_object(from_utf8(data.at("pawn").get<std::string>()).c_str());
        auto* component=find_object(from_utf8(data.at("component").get<std::string>()).c_str());
        const auto source_path=from_utf8(data.at("source").get<std::string>());
        auto* source=find_object(source_path.c_str());
        require(component->GetFullName().starts_with(L"AttributeComponent "),"developer shield target class");
        constexpr std::array<ExpectedParameter,3> interface_params{{
            {L"TestObject",L"ObjectProperty"},{L"Interface",L"ClassProperty"},{L"ReturnValue",L"BoolProperty"}}};
        const auto interface_schema=inspect_signature(L"/Script/Engine.KismetSystemLibrary:DoesImplementInterface",interface_params);
        ParameterFrame interface_frame(interface_schema);
        auto* source_interface=find_object(L"/Script/SGameAttributes.DamageSourceInterface");
        std::memcpy(interface_frame.address(interface_schema.at(L"TestObject")),&source,sizeof(source));
        std::memcpy(interface_frame.address(interface_schema.at(L"Interface")),&source_interface,sizeof(source_interface));
        find_object(L"/Script/Engine.Default__KismetSystemLibrary")->ProcessEvent(interface_schema.function,interface_frame.data());
        require(reinterpret_cast<FBoolProperty*>(const_cast<FProperty*>(interface_schema.at(L"ReturnValue").property))->GetPropertyValue(
            interface_frame.address(interface_schema.at(L"ReturnValue"))),"developer source must implement DamageSourceInterface");
        // UE4SS's Lua InterfaceProperty setter writes only UObject*. Populate
        // this owned test module's native interface through the engine importer.
        const auto bullet_path=from_utf8(data.at("bullet").get<std::string>());
        auto* bullet=find_object(bullet_path.c_str());
        require(source->GetFullName().starts_with(L"BulletAttackModule ")&&
            bullet->GetFullName().starts_with(L"BulletObjectBase "),"developer owned bullet classes");
        auto* bullet_interface=find_object(L"/Script/SGameCombatSystem.BulletInterface");
        std::memcpy(interface_frame.address(interface_schema.at(L"TestObject")),&bullet,sizeof(bullet));
        std::memcpy(interface_frame.address(interface_schema.at(L"Interface")),&bullet_interface,sizeof(bullet_interface));
        find_object(L"/Script/Engine.Default__KismetSystemLibrary")->ProcessEvent(interface_schema.function,interface_frame.data());
        require(reinterpret_cast<FBoolProperty*>(const_cast<FProperty*>(interface_schema.at(L"ReturnValue").property))->GetPropertyValue(
            interface_frame.address(interface_schema.at(L"ReturnValue"))),"developer bullet must implement BulletInterface");
        const FProperty* bullet_property{};
        auto* module_class=reinterpret_cast<UStruct*>(find_object(L"/Script/SGameCombatSystem.BulletModuleBase"));
        for(auto* field=module_class->GetChildProperties();field;field=FieldAccess::next(field)) {
            if(field->GetName()==L"Bullet") {
                require(const_cast<FField*>(field)->GetFullName()==L"InterfaceProperty /Script/SGameCombatSystem.BulletModuleBase:Bullet","developer bullet field type");
                bullet_property=reinterpret_cast<const FProperty*>(field);break;
            }
        }
        require(bullet_property&&bullet_property->GetSize()==16&&bullet_property->GetOffset_Internal()==48,"developer bullet interface schema");
        auto* bullet_value=reinterpret_cast<unsigned char*>(source)+bullet_property->GetOffset_Internal();
        const auto bullet_text=L"Object'"+bullet_path+L"'";
        require(bullet_property->ImportText_Direct(bullet_text.c_str(),bullet_value,source,0,nullptr)!=nullptr,"developer bullet interface import");
        std::array<void*,2> bullet_pair{};std::memcpy(bullet_pair.data(),bullet_value,sizeof(bullet_pair));
        require(bullet_pair[0]==bullet&&bullet_pair[1]!=nullptr,"developer native bullet interface missing");
        constexpr std::array<ExpectedParameter,10> expected{{
            {L"DamageSource",L"InterfaceProperty"},{L"DamageCause",L"StructProperty"},{L"HitLocation",L"StructProperty"},
            {L"HitBody",L"StructProperty"},{L"AttackerAttributes",L"MapProperty"},{L"AttackData",L"MapProperty"},
            {L"CustomCalculator",L"ObjectProperty"},{L"AttackDirection",L"StructProperty"},{L"SweepDirection",L"StructProperty"},
            {L"FinalDamageData",L"MapProperty"}}};
        const auto schema=inspect_signature(L"/Script/SGameAttributes.AttributeComponent:TakeDamage",expected);
        ParameterFrame frame(schema);
        const auto text=L"Object'"+source_path+L"'";
        require(schema.at(L"DamageSource").property->ImportText_Direct(text.c_str(),frame.address(schema.at(L"DamageSource")),component,0,nullptr)!=nullptr,"developer source import");
        constexpr std::array<ExpectedParameter,2> capture_params{{{L"Character",L"ObjectProperty"},{L"Snapshot",L"MapProperty"}}};
        const auto capture=inspect_signature(L"/Script/SGameAttributes.AttributeUtils:CaptureCharacterAttributeSnapshot",capture_params);
        ParameterFrame snapshot(capture);std::memcpy(snapshot.address(capture.at(L"Character")),&pawn,sizeof(pawn));
        find_object(L"/Script/SGameAttributes.Default__AttributeUtils")->ProcessEvent(capture.function,snapshot.data());
        require(schema.at(L"AttackerAttributes").property->SameType(capture.at(L"Snapshot").property),"developer snapshot type");
        schema.at(L"AttackerAttributes").property->CopyCompleteValue(frame.address(schema.at(L"AttackerAttributes")),snapshot.address(capture.at(L"Snapshot")));
        // PBZ interprets this value as an attack coefficient. With the current
        // developer player's 100 attack, .08 yields 8 actual HP, not 800.
        const auto text_attack=L"(((TagName=\"Damage.Attack.Target.PhysicalDamage\"),0.08))";
        require(schema.at(L"AttackData").property->ImportText_Direct(text_attack,frame.address(schema.at(L"AttackData")),component,0,nullptr)!=nullptr,"developer attack map import");
        Vector direction{data.at("x").get<double>(),data.at("y").get<double>(),0};
        require(std::isfinite(direction.x)&&std::isfinite(direction.y)&&std::hypot(direction.x,direction.y)<=1.001,"developer direction");
        std::memcpy(frame.address(schema.at(L"AttackDirection")),&direction,sizeof(direction));
        const auto before=blocked.load();
        const auto sounds_before=block_sounds.load(),failures_before=sound_failures.load();
        auto entry=reinterpret_cast<Damage>(reinterpret_cast<unsigned char*>(GetModuleHandleW(nullptr))+verified_host_build().take_damage);
        entry(component,frame.address(schema.at(L"DamageSource")),frame.address(schema.at(L"DamageCause")),
            static_cast<Vector*>(frame.address(schema.at(L"HitLocation"))),frame.address(schema.at(L"HitBody")),
            frame.address(schema.at(L"AttackerAttributes")),frame.address(schema.at(L"AttackData")),nullptr,
            static_cast<Vector*>(frame.address(schema.at(L"AttackDirection"))),static_cast<Vector*>(frame.address(schema.at(L"SweepDirection"))),
            frame.address(schema.at(L"FinalDamageData")));
        lua.set_string(nlohmann::json{{"blocked",blocked.load()-before},{"block_sounds",block_sounds.load()-sounds_before},
            {"sound_failures",sound_failures.load()-failures_before},{"route","native-AttributeComponent-TakeDamage"}}.dump());lua.set_nil();
    } catch(const std::exception& error){lua.set_nil();lua.set_string(std::string("PBZMC shield developer hit: ")+error.what());}
    return 2;
}
} // namespace ShieldGate
