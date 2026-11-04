// UAbilitySystemComponent::ApplyModToAttribute, before Health/death delegates.
// Combat retains its armor/status path; direct native fall writes only consult
// the lethal totem boundary and retain ordinary PBZ damage semantics.
// Pinned static evidence: health-applymod-native.json and shield-takedamage-native.json.
#pragma once
namespace ShieldGate { inline void install(); }
namespace DeathGate { inline void clear(); inline nlohmann::json report(); }
namespace HealthGate {
using Apply=void(*)(UObject*,const void*,std::uint8_t,float);
inline Apply original{};
inline Apply original_modify{};
inline UObject* asc{};
inline std::wstring asc_name;
inline UObject* pawn{};
inline std::wstring pawn_name;
inline Lua* callback_state{};
inline int thread_ref{};
inline DWORD game_thread{};
inline ULONGLONG heartbeat{};
inline bool inside{};
inline thread_local unsigned damage_depth{};
inline thread_local const void* damage_cause{};
inline std::uint64_t observed{},changed{},failures{};
inline std::uint64_t direct_observed{},direct_changed{};
inline std::string error;
inline const FProperty* attribute_name{};
struct DamageScope {
 const void* previous;
 explicit DamageScope(const void* cause):previous(damage_cause){++damage_depth;damage_cause=cause;}
 ~DamageScope(){--damage_depth;damage_cause=previous;}
};
inline void clear() {asc=nullptr;asc_name.clear();pawn=nullptr;pawn_name.clear();heartbeat=0;DeathGate::clear();}
inline void start(const Lua& root) {
 callback_state=&root.new_thread();thread_ref=root.registry().make_ref();
}
inline void stop() {clear();callback_state=nullptr;thread_ref=0;}
inline void intercept(UObject* target,const void* attribute,std::uint8_t op,float magnitude) {
 if(target==asc && !inside && op==0 && magnitude<0 && std::isfinite(magnitude)
   && callback_state && GetCurrentThreadId()==game_thread && GetTickCount64()-heartbeat<1500
   && !target->IsUnreachable() && target->GetFullName()==asc_name && attribute) {
  const auto* name=reinterpret_cast<const TStringBase<wchar_t>*>(
      static_cast<const unsigned char*>(attribute)+attribute_name->GetOffset_Internal());
  if(name->Len()==6 && std::wstring_view(**name,6)==L"Health") {
   ++observed;inside=true;
   try {
    callback_state->prepare_function_call(damage_depth?"PBZMC_HealthDecision":"PBZMC_LethalHealthDecision");
    callback_state->set_number(magnitude);
    std::string cause;
    if(damage_cause)cause=to_utf8(reinterpret_cast<const FName*>(damage_cause)->ToString());
    callback_state->set_string(cause);callback_state->call_function(2,1);
    require(callback_state->is_number(),"health decision must be numeric");
    const double next=callback_state->get_number();
    require(std::isfinite(next)&&next>=magnitude&&next<=1e7,"invalid health decision");
    magnitude=static_cast<float>(next);++changed;
   }catch(const std::exception& e){++failures;error=e.what();}
   while(callback_state->get_stack_size()>0)callback_state->discard_value();
   inside=false;
  }
 }
 original(target,attribute,op,magnitude);
}
inline void intercept_modify(UObject* target,const void* attribute,std::uint8_t op,float magnitude){
 // PBZ falling can construct a GameplayEffectSpec instead of calling ApplyMod.
 // Catch its explicit Health delta before either branch, before a zero-HP
 // event can run stale locals after the totem rescues the player.
 if(target==pawn && pawn && !damage_depth && !inside && op==0 && magnitude<0 && std::isfinite(magnitude)
  && callback_state && GetCurrentThreadId()==game_thread && GetTickCount64()-heartbeat<1500
  && !target->IsUnreachable() && target->GetFullName()==pawn_name && attribute){
  const auto* name=reinterpret_cast<const TStringBase<wchar_t>*>(
   static_cast<const unsigned char*>(attribute)+attribute_name->GetOffset_Internal());
  if(name->Len()==6 && std::wstring_view(**name,6)==L"Health"){
   ++direct_observed;inside=true;
   try{
    callback_state->prepare_function_call("PBZMC_LethalHealthDecision");callback_state->set_number(magnitude);callback_state->call_function(1,1);
    require(callback_state->is_number(),"direct health decision must be numeric");const double next=callback_state->get_number();
    require(std::isfinite(next)&&next>=magnitude&&next<=1e7,"invalid direct health decision");
    if(next!=magnitude)++direct_changed;magnitude=static_cast<float>(next);
   }catch(const std::exception& e){++failures;error=e.what();}
   while(callback_state->get_stack_size()>0)callback_state->discard_value();inside=false;
  }
 }
 original_modify(target,attribute,op,magnitude);
}
inline void install() {
 static std::once_flag once;
 std::call_once(once,[]{
  ShieldGate::install(); // exact executable digest, schema, MinHook and module pin
  auto* type=reinterpret_cast<UStruct*>(find_object(L"/Script/GameplayAbilities.GameplayAttribute"));
  for(auto* f=type->GetChildProperties();f;f=FieldAccess::next(f))if(f->GetName()==L"AttributeName"){
   require(const_cast<FField*>(f)->GetFullName()==L"StrProperty /Script/GameplayAbilities.GameplayAttribute:AttributeName","health attribute name type");
   attribute_name=reinterpret_cast<const FProperty*>(f);
  }
  require(attribute_name&&attribute_name->GetOffset_Internal()==0&&attribute_name->GetSize()==16,"health attribute name layout");
  const auto& build=verified_host_build();
  auto* address=reinterpret_cast<unsigned char*>(GetModuleHandleW(nullptr))+build.apply_health;
  constexpr unsigned char prefix[]{0x48,0x89,0x5c,0x24,0x08,0x48,0x89,0x74,0x24,0x10,0x57,0x48,0x83,0xec,0x40};
  require(std::memcmp(address,prefix,sizeof(prefix))==0,"health apply entry changed");
  auto code=MH_CreateHook(address,reinterpret_cast<void*>(&intercept),reinterpret_cast<void**>(&original));
  if(code==MH_ERROR_MEMORY_ALLOC)code=MH_CreatePBZHealthHook(address,reinterpret_cast<void*>(&intercept),reinterpret_cast<void**>(&original));
  if(code!=MH_OK)throw std::runtime_error(std::string("health hook create: ")+MH_StatusToString(code));require(MH_EnableHook(address)==MH_OK,"health hook enable");
  const std::array<ExpectedParameter,4> params{{{L"Character",L"ObjectProperty"},{L"Attribute",L"StructProperty"},
   {L"ModiferOp",L"ByteProperty"},{L"Value",L"FloatProperty"}}};
  const auto schema=inspect_signature(L"/Script/SGameAttributes.AttributeUtils:ModifyCharacterAttributeValue",params);
  require(schema.at(L"Character").offset==0 && schema.at(L"Attribute").offset==8 && schema.at(L"ModiferOp").offset==64
   && schema.at(L"Value").offset==68,"direct health signature changed");
  auto* direct=reinterpret_cast<unsigned char*>(GetModuleHandleW(nullptr))+build.modify_attribute;
  constexpr unsigned char direct_prefix[]{0x40,0x55,0x56,0x57,0x41,0x56,0x41,0x57,0x48,0x8d,0xac,0x24,0x60,0xfd,0xff,0xff};
  require(std::memcmp(direct,direct_prefix,sizeof(direct_prefix))==0,"direct health entry changed");
  code=MH_CreateHook(direct,reinterpret_cast<void*>(&intercept_modify),reinterpret_cast<void**>(&original_modify));
  if(code==MH_ERROR_MEMORY_ALLOC)code=MH_CreatePBZAttributeHook(direct,reinterpret_cast<void*>(&intercept_modify),reinterpret_cast<void**>(&original_modify));
  if(code!=MH_OK)throw std::runtime_error(std::string("direct health hook create: ")+MH_StatusToString(code));
  require(MH_EnableHook(direct)==MH_OK,"direct health hook enable");
 });
}
inline int lua_bind(const Lua& lua) {
 try {
  require(IsInGameThread()&&lua.get_stack_size()==1&&lua.is_string(1),"health bind(path) on game thread");
  const auto path=from_utf8(std::string(lua.get_string(1))); // argument removal leaves callback at index 1
  auto* object=find_object(path.c_str());const auto name=object->GetFullName();
  require(name.starts_with(L"PBZAbilitySystemComponent ")&&!object->IsUnreachable(),"health local ASC required");
  install();clear();require(callback_state!=nullptr,"health callback runtime missing");
  const auto owner_path=path.substr(0,path.rfind(L'.'));require(owner_path!=path,"health owner path required");
  auto* actor=find_object(owner_path.c_str());require(!actor->IsUnreachable(),"health owner unavailable");
  asc=object;asc_name=name;pawn=actor;pawn_name=actor->GetFullName();game_thread=GetCurrentThreadId();heartbeat=GetTickCount64();
  lua.set_bool(true);lua.set_nil();
 }catch(const std::exception& e){clear();lua.set_nil();lua.set_string(e.what());}
 return 2;
}
inline int lua_poll(const Lua& lua) {
 try {
  require(IsInGameThread()&&lua.get_stack_size()==1&&lua.is_string(1),"health poll(path) on game thread");
  const auto path=from_utf8(std::string(lua.get_string(1)));
  if(path.empty())clear();
  else {auto* target=find_object(path.c_str());require(target==asc&&target->GetFullName()==asc_name,"health owner changed");heartbeat=GetTickCount64();}
  lua.set_string(nlohmann::json{{"observed",observed},{"changed",changed},{"direct_observed",direct_observed},{"direct_changed",direct_changed},
   {"failures",failures},{"error",error},{"active",asc!=nullptr},{"death",DeathGate::report()}}.dump());lua.set_nil();
 }catch(const std::exception& e){clear();lua.set_nil();lua.set_string(e.what());}
 return 2;
}
}
