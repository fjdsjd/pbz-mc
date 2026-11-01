// Current-player pre-death state fallback. Native high-fall Health writes are
// handled earlier by HealthGate; direct state/setter deaths reach this gate.
// Call sites and prologues are restricted to the supported executable build.
#pragma once
#include <intrin.h>
namespace DeathGate {
using Activate=bool(*)(UObject*,const void*);
inline Activate original{};
inline UObject* owner{};
inline std::wstring owner_name;
inline std::uintptr_t image_base{};
inline std::uint64_t observed{},handled{},failures{};
inline std::string error;
inline void clear(){owner=nullptr;owner_name.clear();}
inline nlohmann::json report(){
 return {{"active",owner!=nullptr},{"observed",observed},{"handled",handled},{"failures",failures},{"error",error}};
}
inline bool intercept(UObject* component,const void* tag){
 const auto caller=reinterpret_cast<std::uintptr_t>(_ReturnAddress());
 if(component==owner && owner && tag && !HealthGate::inside && HealthGate::asc && HealthGate::callback_state
  && GetCurrentThreadId()==HealthGate::game_thread && GetTickCount64()-HealthGate::heartbeat<1500
  && !component->IsUnreachable() && component->GetFullName()==owner_name
  && reinterpret_cast<const FName*>(tag)->ToString()==L"CharacterState.Dead"){
  ++observed;bool saved=false;HealthGate::inside=true;
  auto* lua=HealthGate::callback_state;
  try{
   // These two native loops iterate a copy of the pending queue. The Lua
   // decision checks the live queue before replaying a copied Dead request.
   const bool retry=caller==image_base+0x5d9503c || caller==image_base+0x5d9488b;
   lua->prepare_function_call("PBZMC_DeathDecision");lua->set_bool(retry);lua->call_function(1,1);
   require(lua->is_bool(),"death decision must be boolean");saved=lua->get_bool();
   if(saved)++handled;
  }catch(const std::exception& e){++failures;error=e.what();}
  while(lua->get_stack_size()>0)lua->discard_value();HealthGate::inside=false;
  // AddPendingState interprets false as retry-later. A totem handles/removes
  // the request, so return true WITHOUT starting Dead or broadcasting it.
  if(saved)return true;
 }
 return original(component,tag);
}
inline void install(){
 static std::once_flag once;
 std::call_once(once,[]{
  HealthGate::install(); // verifies pinned PBZ SHA, UE4SS ABI and DLL lifetime
  const std::array<ExpectedParameter,2> params{{{L"NewStateTag",L"StructProperty"},{L"ReturnValue",L"BoolProperty"}}};
  const auto schema=inspect_signature(L"/Script/SGameActorState.ActorStateComponent:TryActivateNewState",params);
  require(schema.at(L"NewStateTag").offset==0 && schema.at(L"NewStateTag").property->GetSize()==8
   && schema.at(L"ReturnValue").offset==8,"death state signature changed");
  image_base=reinterpret_cast<std::uintptr_t>(GetModuleHandleW(nullptr));
  auto* address=reinterpret_cast<unsigned char*>(image_base+0x5d94d30);
  constexpr unsigned char prefix[]{0x40,0x55,0x56,0x41,0x54,0x41,0x57,0x48,0x8b,0xec,0x48,0x83,0xec,0x78};
  require(std::memcmp(address,prefix,sizeof(prefix))==0,"death state entry changed");
  auto code=MH_CreateHook(address,reinterpret_cast<void*>(&intercept),reinterpret_cast<void**>(&original));
  if(code==MH_ERROR_MEMORY_ALLOC)code=MH_CreatePBZDeathHook(address,reinterpret_cast<void*>(&intercept),reinterpret_cast<void**>(&original));
  if(code!=MH_OK)throw std::runtime_error(std::string("death hook create: ")+MH_StatusToString(code));
  require(MH_EnableHook(address)==MH_OK,"death hook enable");
 });
}
inline int lua_bind(const Lua& lua){
 try{
  require(IsInGameThread()&&lua.get_stack_size()==1&&lua.is_string(1),"death bind(path) on game thread");
  const auto path=from_utf8(std::string(lua.get_string(1)));require(!path.empty()&&path.size()<4096,"death path bound");
  auto* object=find_object(path.c_str());const auto name=object->GetFullName();
  require(name.starts_with(L"ActorStateComponent ")&&!object->IsUnreachable(),"death local state component required");
  require(HealthGate::asc && HealthGate::callback_state,"death requires current health owner");
  // Both components must be direct children of the same currently bound pawn.
  const auto health_path=HealthGate::asc_name.substr(HealthGate::asc_name.find(L' ')+1);
  const auto state_path=name.substr(name.find(L' ')+1);
  require(health_path.substr(0,health_path.rfind(L'.'))==state_path.substr(0,state_path.rfind(L'.')),"death/health owner mismatch");
  install();clear();owner=object;owner_name=name;lua.set_bool(true);lua.set_nil();
 }catch(const std::exception& e){clear();lua.set_nil();lua.set_string(e.what());}
 return 2;
}
}
