-- Request the two observed PBZ weapon actions through their native input handler.
-- This is an action adapter, never a read-only probe or an equipment setter.
-- Invoke/ProcessEvent adjusts the interface receiver; Lua passes the full UObject.
local identity=require('host.pbz.object_identity')
local M={}
local PLAYER='/Game/RenewalContent/Prototypes/Character/BP_RenewalPlayer.BP_RenewalPlayer_C'
local COMPONENT='/Script/SGameInputSystem.AbilityInputComponent'
local INPUT='/Script/SGameInputSystem.SGameInputComponent'
local SYSTEM='/Script/ProjectPBZ.PBZAbilitySystemComponent'
local INTERFACE='/Script/SGameInputSystem.SGameInputHandler'
local FUNCTION=INTERFACE..':HandleInputAction'
local ACTION_CLASS='/Script/EnhancedInput.InputAction'
local actions={
  next_main='/SGameCombatSystem/Weapon/Input/IA_ChangeWeapon.IA_ChangeWeapon',
  next_shaqi='/SGameCombatSystem/Weapon/Input/IA_ChangeShachiWeapon.IA_ChangeShachiWeapon',
  change_armed='/SGameCombatSystem/Weapon/Input/IA_ChangeArmed.IA_ChangeArmed',
}
local function capture(value)
  local id=identity.capture(value)
  assert(type(id.address)=='number' and id.address>0 and id.address%1==0 and id.address<=2^53-1
    and type(id.name)=='string' and #id.name>0,'native-input-invalid-identity')
  return id
end
local function same(value,id,label)
  assert(identity.matches(value,id),'native-input-identity-changed:'..label)
end
local function fields(owner,path,expected,exact)
  local seen,visited,matched={},0,0
  owner:ForEachProperty(function(field)
    visited=visited+1;assert(visited<=256,'native-input-schema-limit')
    local name=field:GetFName():ToString();local spec=expected[name]
    if spec then
      assert(not seen[name] and field:IsValid() and field:GetFullName()==spec[1]..' '..path..':'..name
        and field:GetOffset_Internal()==spec[2],'native-input-schema-field:'..name)
      seen[name]=true;matched=matched+1
    end
    return nil
  end)
  for name in pairs(expected) do assert(seen[name],'native-input-schema-missing:'..name) end
  assert(not exact or visited==matched,'native-input-schema-extra-field')
end

-- A completed non-buffered action can be rejected without replaying it. This
-- query deliberately refuses buffered weapon cycling and active native moves.
function M.action_idle(controller,validate)
  assert(IsInGameThread() and validate()~=false,'native-input-idle-context')
  local actor=controller.Pawn;local handler=actor['Ability Input Component']
  local class=StaticFindObject(COMPONENT)
  fields(class,COMPONENT,{InActionPhase={'BoolProperty',416}})
  assert(handler and handler:IsValid() and handler:IsA(class),'native-input-idle-handler')
  local weapons=actor['Character Weapons Component']
  local idle=handler.InActionPhase==false and not (weapons and weapons:IsValid() and weapons:IsInWeaponTransition())
    and not controller:IsLookInputIgnored()
    and not controller:IsMoveInputIgnored() and not actor.DisableMovement
    -- PBZ can keep a movement source after lock-on while standing idle.
    -- Active combat phases, animation root motion and control locks still
    -- defer the handoff. Selection never removes a native movement source.
    and not actor:IsPlayingRootMotion()
  assert(validate()~=false,'native-input-idle-owner-changed')
  return idle
end
function M.nonbuffered_idle(controller,action,validate)
  assert(actions[action] and validate()~=false and IsInGameThread(),'native-input-idle-context')
  local actor=controller.Pawn;local handler=actor['Ability Input Component']
  local class=StaticFindObject(COMPONENT)
  fields(class,COMPONENT,{ValidBufferInputs={'ArrayProperty',224},InActionPhase={'BoolProperty',416}})
  assert(handler and handler:IsValid() and handler:IsA(class),'native-input-idle-handler')
  local buffer=handler.ValidBufferInputs;assert(buffer:IsValid() and buffer:GetArrayNum()<=32,'native-input-buffer-schema')
  local buffered=false
  buffer:ForEach(function(_,wrapped)
    local value=wrapped:get()
    if value and value:IsValid() and value:GetFullName()=='InputAction '..actions[action] then buffered=true end
  end)
  assert(validate()~=false,'native-input-idle-owner-changed')
  return not buffered and handler.InActionPhase==false and not controller:IsLookInputIgnored()
    and not controller:IsMoveInputIgnored() and not actor:IsPlayingRootMotion() and not actor:HasAnyRootMotion()
end

-- Call on the game thread, once per accepted physical selection intent.
-- validate() must reject stale binding/epoch, UI capture, cutscenes, wrong input
-- ownership and unresolved earlier requests. It must not yield or mutate state.
-- attempted=true forbids automatic retry, including when the call/postcheck fails.
-- A void native return is only dispatch_returned, never equipment confirmation.
function M.request(controller,action,validate)
  local result={action=type(action)=='string' and action or nil,attempted=false,dispatch_returned=false,
    selection_confirmed=false,combat_commit_verified=false,status='preflight_rejected'}
  local ok,err=pcall(function()
    assert(type(IsInGameThread)=='function' and IsInGameThread(),'native-input-game-thread-required')
    assert(type(validate)=='function','native-input-lifecycle-guard-required')
    assert(type(action)=='string' and actions[action],'native-input-action-not-supported')
    assert(validate()~=false,'native-input-lifecycle-rejected')
    local metadata={}
    local function find(path,kind)
      local value=StaticFindObject(path);local id=capture(value)
      assert(id.name==kind..' '..path,'native-input-metadata-kind:'..path)
      metadata[path]=id;return value,id
    end
    local pc_class=find('/Script/Engine.PlayerController','Class')
    local controller_class=find('/Script/Engine.Controller','Class')
    local local_class=find('/Script/Engine.LocalPlayer','Class')
    local world_class=find('/Script/Engine.World','Class')
    fields(pc_class,'/Script/Engine.PlayerController',{Player={'ObjectProperty',848}})
    fields(controller_class,'/Script/Engine.Controller',{Pawn={'ObjectProperty',752}})
    local pc_id=capture(controller)
    assert(controller:IsA(pc_class),'native-input-controller-type')
    local local_player=controller.Player;local local_id=capture(local_player)
    assert(local_player:IsA(local_class),'native-input-local-player-required')
    local actor=controller.Pawn;local actor_id=capture(actor)
    local world=actor:GetWorld();local world_id=capture(world)
    assert(world:IsA(world_class),'native-input-world-type')
    local proto=find(PLAYER,'BlueprintGeneratedClass')
    assert(actor:IsA(proto),'native-input-player-type')
    fields(proto,PLAYER,{['Ability Input Component']={'ObjectProperty',3768}})
    local component_class,component_class_id=find(COMPONENT,'Class')
    fields(component_class,COMPONENT,{SGameInput={'ObjectProperty',200}})
    local input_class,input_class_id=find(INPUT,'Class')
    fields(input_class,INPUT,{AbilitySystem={'ObjectProperty',384}})
    local system_class=find(SYSTEM,'Class')
    local component=actor['Ability Input Component'];local component_id=capture(component)
    same(component:GetClass(),component_class_id,'handler-class')
    local input=component.SGameInput;local input_id=capture(input)
    same(input:GetClass(),input_class_id,'input-class')
    local system=input.AbilitySystem;local system_id=capture(system)
    local system_class_id=capture(system:GetClass())
    assert(system:IsA(system_class),'native-input-ability-system-type')
    local interface,interface_id=find(INTERFACE,'Class')
    local fn,fn_id=find(FUNCTION,'Function')
    fields(fn,FUNCTION,{AbilitySystem={'ObjectProperty',0},InputAction={'ObjectProperty',8}},true)
    local action_class,action_class_id=find(ACTION_CLASS,'Class')
    local input_action=StaticFindObject(actions[action]);local action_id=capture(input_action)
    assert(action_id.name=='InputAction '..actions[action] and input_action:IsA(action_class),'native-input-action-type')
    local function check()
      assert(IsInGameThread(),'native-input-game-thread-required')
      assert(validate()~=false,'native-input-lifecycle-rejected')
      for path,id in pairs(metadata) do same(StaticFindObject(path),id,path) end
      same(controller,pc_id,'controller');same(controller.Player,local_id,'local-player-reference')
      same(local_player,local_id,'local-player');same(controller.Pawn,actor_id,'pawn-reference')
      same(actor,actor_id,'pawn');same(actor:GetWorld(),world_id,'pawn-world')
      same(controller:GetWorld(),world_id,'controller-world');same(world,world_id,'world')
      same(actor['Ability Input Component'],component_id,'handler-reference')
      same(component,component_id,'handler');same(component:GetClass(),component_class_id,'handler-class')
      same(component:GetOuter(),actor_id,'handler-owner');same(component:GetWorld(),world_id,'handler-world')
      same(component.SGameInput,input_id,'input-reference');same(input,input_id,'input')
      same(input:GetClass(),input_class_id,'input-class');same(input:GetOuter(),actor_id,'input-owner')
      same(input:GetWorld(),world_id,'input-world');same(input.AbilitySystem,system_id,'system-reference')
      same(system,system_id,'system');same(system:GetClass(),system_class_id,'system-class')
      same(system:GetOuter(),actor_id,'system-owner');same(system:GetWorld(),world_id,'system-world')
      same(interface,interface_id,'interface');same(fn,fn_id,'function');same(fn:GetOuter(),interface_id,'function-owner')
      assert(fn:GetFunctionFlags()==0x08020C00,'native-input-function-flags')
      same(StaticFindObject(actions[action]),action_id,'action');same(input_action:GetClass(),action_class_id,'action-class')
    end
    check()
    result.attempted=true
    fn(component,system,input_action) -- Unbound UFunction: first argument is the receiver.
    result.dispatch_returned=true
    check()
    result.status='dispatched'
  end)
  if not ok then
    result.error=tostring(err)
    result.status=result.attempted and 'dispatch_uncertain' or 'preflight_rejected'
  end
  return result -- Plain result only; no native references or borrowed data escape.
end
return M
