// MC hit intents enter PBZ damage calculation and the native HitreactComponent.
// Only owned transient DamageSource_GameplayEffect objects are configured. No
// global attack attributes, assets, abilities or enemy resistance are modified.
#pragma once
namespace MinecraftHit {
using Json=nlohmann::json;
inline constexpr wchar_t source_class[]=L"/Script/SGameCombatSystem.DamageSource_GameplayEffect";
inline void import(const FProperty* property,void* value,UObject* owner,const std::wstring& text) {
    require(property->ImportText_Direct(text.c_str(),value,owner,0,nullptr)!=nullptr,"MC hit property import failed");
}
inline UObject* object(const Json& data,const char* key) {
    const auto path=from_utf8(data.at(key).get<std::string>());
    require(path.size()<2048&&path.find_first_of(L"\"'\r\n")==std::wstring::npos,"MC hit invalid object path");
    auto* result=find_object(path.c_str());require(!result->IsUnreachable(),"MC hit object retired");return result;
}
inline UObject* owner(UObject* component) {
    constexpr std::array expected{ExpectedParameter{L"ReturnValue",L"ObjectProperty"}};
    const auto signature=inspect_signature(L"/Script/Engine.ActorComponent:GetOwner",expected);
    ParameterFrame frame(signature);component->ProcessEvent(signature.function,frame.data());
    UObject* result{};std::memcpy(&result,frame.address(signature.at(L"ReturnValue")),sizeof(result));return result;
}
inline void interface_value(const Parameter& parameter,void* value,UObject* context,UObject* source,const std::wstring& path) {
    require(parameter.kind==L"InterfaceProperty"&&parameter.size==16,"MC hit interface schema");
    import(parameter.property,value,context,L"Object'"+path+L"'");
    std::array<void*,2> pair{};std::memcpy(pair.data(),value,sizeof(pair));
    require(pair[0]==source&&pair[1]!=nullptr,"MC hit missing native interface pointer");
}
inline ShieldGate::Vector vector(const Json& data,const char* name,bool unit=false) {
    const auto& v=data.at(name);ShieldGate::Vector result{v.at("X").get<double>(),v.at("Y").get<double>(),v.at("Z").get<double>()};
    require(std::isfinite(result.x)&&std::isfinite(result.y)&&std::isfinite(result.z)
        &&std::abs(result.x)<1e9&&std::abs(result.y)<1e9&&std::abs(result.z)<1e9,"MC hit vector range");
    if(unit)require(std::abs(result.x*result.x+result.y*result.y+result.z*result.z-1)<.002,"MC hit unit direction");
    return result;
}
inline Signature damage_schema() {
    constexpr std::array<ExpectedParameter,10> expected{{
        {L"DamageSource",L"InterfaceProperty"},{L"DamageCause",L"StructProperty"},{L"HitLocation",L"StructProperty"},
        {L"HitBody",L"StructProperty"},{L"AttackerAttributes",L"MapProperty"},{L"AttackData",L"MapProperty"},
        {L"CustomCalculator",L"ObjectProperty"},{L"AttackDirection",L"StructProperty"},{L"SweepDirection",L"StructProperty"},{L"FinalDamageData",L"MapProperty"}}};
    return inspect_signature(L"/Script/SGameAttributes.AttributeComponent:TakeDamage",expected);
}
inline void fire_cause(const Signature& signature,ParameterFrame& frame,UObject* context,const wchar_t* cause_name=L"Damage.Cause.Fire") {
    // Explicit mod-owned cause consumed by HealthGate. Validate the real
    // GameplayTag layout and importer rather than assuming registration.
    const auto& cause=signature.at(L"DamageCause");require(cause.size==8,"MC fire cause schema");
    auto* type=find_object(L"/Script/GameplayTags.GameplayTag");
    require(type->GetFullName()==L"ScriptStruct /Script/GameplayTags.GameplayTag","MC fire tag struct");
    require(reinterpret_cast<UStruct*>(type)->GetPropertiesSize()==8,"MC fire tag struct size");
    const FProperty* name{};unsigned fields=0;
    for(auto* field=reinterpret_cast<UStruct*>(type)->GetChildProperties();field;field=FieldAccess::next(field)) {
        require(++fields<=32,"MC fire tag fields");
        if(field->GetName()==L"TagName")name=reinterpret_cast<const FProperty*>(field);
    }
    require(fields==1&&name&&property_kind(name)==L"NameProperty"&&name->GetOffset_Internal()==0&&name->GetSize()==8
        &&const_cast<FField*>(reinterpret_cast<const FField*>(name))->GetFullName()==L"NameProperty /Script/GameplayTags.GameplayTag:TagName",
        "MC fire tag name layout");
    // Import the verified FName member, bypassing GameplayTag's optional
    // registry lookup. Only this call's parameter buffer receives the name.
    import(name,frame.address(cause),context,cause_name);
    require(reinterpret_cast<const FName*>(frame.address(cause))->ToString()==cause_name,"MC environmental cause import");
}
inline std::string run(const std::string& input) {
    require(IsInGameThread()&&input.size()<=16384,"MC hit requires bounded game thread JSON");
    const auto data=Json::parse(input);const auto phase=data.at("phase").get<std::string>();
    if(phase=="capabilities") {
        // Metadata and a local initialized parameter buffer only. No UObject
        // is modified and no ProcessEvent/damage call occurs in this probe.
        const auto signature=damage_schema();ParameterFrame frame(signature);fire_cause(signature,frame,nullptr);
        return Json{{"api",2},{"kinds",{"sword","spear","mace","arrow","wind_charge","explosion","fire","fall","fly_into_wall"}},
            {"self_damage",true},{"fire_cause","Damage.Cause.Fire"},{"fire_cause_verified",true}}.dump();
    }
    require(phase=="damage"||phase=="feedback","MC hit phase");
    const auto kind=data.at("kind").get<std::string>();
    const bool environmental=kind=="explosion"||kind=="fire"||kind=="fall"||kind=="fly_into_wall";
    require(kind=="sword"||kind=="spear"||kind=="mace"||kind=="arrow"||kind=="wind_charge"||environmental,"MC hit kind");
    auto* pawn=object(data,"pawn");auto* target=object(data,"target");auto* source=object(data,"source");
    auto* component=object(data,"component");
    require(component->GetFullName().starts_with(L"AttributeComponent ")&&owner(component)==target,"MC damage target owner");
    if(pawn==target) {
        // Self damage must reach the live health gate, including gold hearts,
        // fire resistance and the pre-lethal totem decision. Never bypass it.
        require(environmental&&HealthGate::asc&&!HealthGate::asc->IsUnreachable()
            &&HealthGate::asc->GetFullName()==HealthGate::asc_name&&owner(HealthGate::asc)==pawn
            &&HealthGate::callback_state&&!HealthGate::inside&&HealthGate::heartbeat!=0
            &&GetCurrentThreadId()==HealthGate::game_thread&&GetTickCount64()-HealthGate::heartbeat<1500,
            "MC environmental self damage requires live player health binding");
    }
    require(source->GetFullName().starts_with(L"DamageSource_GameplayEffect "),"MC hit source class");
    const auto source_path=from_utf8(data.at("source").get<std::string>());
    const auto pawn_path=from_utf8(data.at("pawn").get<std::string>());
    // UE's importer constructs the weak reference; never store a raw UObject*
    // in a WeakObjectProperty or an incomplete FScriptInterface.
    auto* avatar=class_property(source_class,L"SourceAvatar");
    require(property_kind(avatar)==L"WeakObjectProperty"&&avatar->GetSize()==8,"MC hit source-avatar schema");
    import(avatar,reinterpret_cast<unsigned char*>(source)+avatar->GetOffset_Internal(),source,L"Object'"+pawn_path+L"'");
    const wchar_t* attack_type=L"HitReact.AttackType.Physical.Slash.TangBlade.Player";
    if(kind=="arrow") attack_type=L"HitReact.AttackType.Physical.Projectile.Arrow";
    if(kind=="mace") attack_type=L"HitReact.AttackType.Physical";
    if(kind=="wind_charge") attack_type=L"HitReact.AttackType.Physical.Projectile";
    const std::array<std::pair<const wchar_t*,const wchar_t*>,4> tags{{
        {L"AttackStyle",L"Hitreact.AttackStyle.Default"},
        {L"AttackType",attack_type},
        {L"HitStrength",kind=="wind_charge"?L"Hitreact.Strength.Income.Normal.Light":
            kind=="mace"&&data.value("smash",false)?L"Hitreact.Strength.Income.Normal.Heavy":L"Hitreact.Strength.Income.Normal.Middle"},
        {L"AttackDirection",L"Hitreact.AttackDirection.Forward"}}};
    for(const auto& [name,tag]:tags) {
        const auto* property=class_property(source_class,name);require(property_kind(property)==L"StructProperty"&&property->GetSize()==8,"MC hit tag schema");
        import(property,reinterpret_cast<unsigned char*>(source)+property->GetOffset_Internal(),source,std::wstring(L"(TagName=\"")+tag+L"\")");
    }
    const auto direction=vector(data,"direction",true),location=vector(data,"location"),normal=vector(data,"normal");
    UObject* reaction{};
    if(data.contains("reaction")) {
        reaction=object(data,"reaction");require(reaction->GetFullName().starts_with(L"HitreactComponent ")&&owner(reaction)==target,"MC hit reaction owner");
    }
    const auto blocked_before=ShieldGate::blocked.load();
    if(phase=="damage") {
        const double coefficient=data.at("coefficient").get<double>();require(std::isfinite(coefficient)&&coefficient>0&&coefficient<=1000,"MC attack coefficient");
        const auto signature=damage_schema();ParameterFrame frame(signature);
        interface_value(signature.at(L"DamageSource"),frame.address(signature.at(L"DamageSource")),component,source,source_path);
        if(kind=="fire"||kind=="fall"||kind=="fly_into_wall") {
            fire_cause(signature,frame,component,kind=="fall"?L"Damage.Cause.MCFall":kind=="fly_into_wall"?L"Damage.Cause.MCFlyIntoWall":L"Damage.Cause.Fire");
        }
        constexpr std::array snapshot_params{ExpectedParameter{L"Character",L"ObjectProperty"},ExpectedParameter{L"Snapshot",L"MapProperty"}};
        const auto capture=inspect_signature(L"/Script/SGameAttributes.AttributeUtils:CaptureCharacterAttributeSnapshot",snapshot_params);ParameterFrame snapshot(capture);
        std::memcpy(snapshot.address(capture.at(L"Character")),&pawn,sizeof(pawn));
        find_object(L"/Script/SGameAttributes.Default__AttributeUtils")->ProcessEvent(capture.function,snapshot.data());
        require(signature.at(L"AttackerAttributes").property->SameType(capture.at(L"Snapshot").property),"MC snapshot type");
        signature.at(L"AttackerAttributes").property->CopyCompleteValue(frame.address(signature.at(L"AttackerAttributes")),snapshot.address(capture.at(L"Snapshot")));
        import(signature.at(L"AttackData").property,frame.address(signature.at(L"AttackData")),component,
            L"(((TagName=\"Damage.Attack.Target.PhysicalDamage\"),"+std::to_wstring(coefficient)+L"))");
        if(reaction) {
            auto* body=class_property(L"/Script/SGameCombatSystem.HitreactComponent",L"MainBody");
            require(body->SameType(signature.at(L"HitBody").property),"MC hit body schema");
            body->CopyCompleteValue(frame.address(signature.at(L"HitBody")),reinterpret_cast<unsigned char*>(reaction)+body->GetOffset_Internal());
        }
        std::memcpy(frame.address(signature.at(L"HitLocation")),&location,sizeof(location));
        std::memcpy(frame.address(signature.at(L"AttackDirection")),&direction,sizeof(direction));
        std::memcpy(frame.address(signature.at(L"SweepDirection")),&direction,sizeof(direction));
        component->ProcessEvent(signature.function,frame.data());
    } else {
        require(reaction!=nullptr,"MC hit feedback component required");
        constexpr std::array body_params{ExpectedParameter{L"BodyComponent",L"ObjectProperty"},ExpectedParameter{L"BodyBone",L"NameProperty"}};
        const auto body_schema=inspect_signature(L"/Script/SGameCombatSystem.HitreactComponent:GetMainBody",body_params);ParameterFrame body(body_schema);
        reaction->ProcessEvent(body_schema.function,body.data());UObject* mesh{};
        std::memcpy(&mesh,body.address(body_schema.at(L"BodyComponent")),sizeof(mesh));require(mesh&&!mesh->IsUnreachable()&&owner(mesh)==target,"MC hit main body missing");
        constexpr std::array<ExpectedParameter,7> expected{{{L"AttackSource",L"InterfaceProperty"},{L"HitComponent",L"ObjectProperty"},
            {L"HitBone",L"NameProperty"},{L"AttackDirection",L"StructProperty"},{L"HitLocation",L"StructProperty"},{L"HitNormal",L"StructProperty"},{L"SweepDirection",L"StructProperty"}}};
        const auto signature=inspect_signature(L"/Script/SGameCombatSystem.HitreactComponent:PlayHitreact",expected);ParameterFrame frame(signature);
        interface_value(signature.at(L"AttackSource"),frame.address(signature.at(L"AttackSource")),reaction,source,source_path);
        std::memcpy(frame.address(signature.at(L"HitComponent")),&mesh,sizeof(mesh));
        signature.at(L"HitBone").property->CopyCompleteValue(frame.address(signature.at(L"HitBone")),body.address(body_schema.at(L"BodyBone")));
        for(const auto& [name,value]:std::array<std::pair<const wchar_t*,const ShieldGate::Vector*>,4>{{
            {L"AttackDirection",&direction},{L"HitLocation",&location},{L"HitNormal",&normal},{L"SweepDirection",&direction}}})
            std::memcpy(frame.address(signature.at(name)),value,sizeof(*value));
        reaction->ProcessEvent(signature.function,frame.data());
    }
    return Json{{"phase",phase},{"dispatched",true},{"blocked",phase=="damage"&&pawn==target&&ShieldGate::blocked.load()!=blocked_before},
        {"route",phase=="damage"?"native-AttributeComponent-TakeDamage":"native-HitreactComponent-PlayHitreact"}}.dump();
}
inline int lua_hit(const Lua& lua) {
    try {require(lua.get_stack_size()==1&&lua.is_string(1),"usage: PBZMC_NativeHit(json)");lua.set_string(run(std::string(lua.get_string(1))));lua.set_nil();}
    catch(const std::exception& error){lua.set_nil();lua.set_string(std::string("PBZMC native hit: ")+error.what());}return 2;
}
}
