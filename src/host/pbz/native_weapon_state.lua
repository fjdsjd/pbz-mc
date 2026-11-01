-- Read the current CharacterWeaponsComponent through scalar getters.
-- Tags are borrowed only during the same synchronous Map callback. No native
-- object/address escapes the result; no equipment, input or cooldown is changed.
local identity=require('host.pbz.object_identity')
local M={}
local PLAYER='/Game/RenewalContent/Prototypes/Character/BP_RenewalPlayer.BP_RenewalPlayer_C'
local CWC='/Script/SGameCombatSystem.CharacterWeaponsComponent'
local TAG='/Script/GameplayTags.GameplayTag'
local SLOT='/Script/SGameCombatSystem.RuntimeWeaponSlotData'
local MAIN='Weapon.Slot.Main'
local SHACHI='Weapon.Slot.Shachi'
local getters={
  GetSlotWeapons={SlotTag={'StructProperty',0,TAG},ReturnValue={'IntProperty',8}},
  GetCurrentWeaponIndex={SlotTag={'StructProperty',0,TAG},WithPending={'BoolProperty',8},ReturnValue={'IntProperty',12}},
}
local selection_getters={
  IsArmed={SlotTag={'StructProperty',0,TAG},ReturnValue={'BoolProperty',8}},
  IsInWeaponTransition={ReturnValue={'BoolProperty',0}},
}
local function_flags={IsInWeaponTransition=1409418241}
local function integer(value,minimum,maximum)
  return type(value)=='number' and value%1==0 and value>=minimum and value<=maximum
end
local function capture(value)
  local id=identity.capture(value)
  assert(integer(id.address,1,2^53-1) and type(id.name)=='string' and #id.name>0,'weapon-state-invalid-identity')
  return id
end
local function same(value,id,label)
  assert(identity.matches(value,id),'weapon-state-identity-changed:'..label)
end
local function find(path,kind)
  local value=StaticFindObject(path)
  local id=capture(value)
  assert(id.name==kind..' '..path,'weapon-state-metadata-kind:'..path)
  return value,id
end
local function fields(owner,path,expected,exact)
  local seen,visited,matched={},0,0
  owner:ForEachProperty(function(field)
    visited=visited+1;assert(visited<=256,'weapon-state-schema-limit')
    local name=field:GetFName():ToString();local spec=expected[name]
    if spec then
      assert(not seen[name] and field:IsValid() and field:GetFullName()==spec[1]..' '..path..':'..name
        and field:GetOffset_Internal()==spec[2],'weapon-state-schema-field:'..name)
      if spec[3] then
        local _,id=find(spec[3],'ScriptStruct');same(field:GetStruct(),id,name)
      end
      seen[name]=true;matched=matched+1
    end
    return nil -- UE4SS ForEach uses nil to continue, true to stop.
  end)
  for name in pairs(expected) do assert(seen[name],'weapon-state-schema-missing:'..name) end
  assert(not exact or visited==matched,'weapon-state-schema-extra-field')
end
local function mapped(value,struct_id)
  assert(value and value:type()=='UScriptStruct' and value:IsValid()
    and value:IsMappedToObject() and value:IsMappedToProperty(),'weapon-state-borrowed-struct-required')
  local property=value:GetProperty()
  assert(property and property:IsValid() and property:type()=='StructProperty','weapon-state-struct-property-required')
  same(property:GetStruct(),struct_id,'borrowed-struct')
  return value
end

-- validate() is the equipment owner's lifecycle/epoch guard. It must throw on
-- a stale binding and must not yield. A failure discards the entire snapshot.
function M.read(actor,validate,options)
  local ok,result=pcall(function()
    assert(type(IsInGameThread)=='function' and IsInGameThread(),'weapon-state-game-thread-required')
    assert(type(validate)=='function','weapon-state-lifecycle-guard-required')
    assert(options==nil or type(options)=='table','weapon-state-invalid-options')
    local selection=options and options.selection==true
    validate()
    local actor_id=capture(actor);local world=actor:GetWorld();local world_id=capture(world)
    local proto,proto_id=find(PLAYER,'BlueprintGeneratedClass')
    assert(actor:IsA(proto),'weapon-state-player-type')
    fields(proto,PLAYER,{['Character Weapons Component']={'ObjectProperty',3776}})
    local class,class_id=find(CWC,'Class')
    fields(class,CWC,{RuntimeWeaponData={'MapProperty',248}})
    local tag_type,tag_id=find(TAG,'ScriptStruct')
    fields(tag_type,TAG,{TagName={'NameProperty',0}},true)
    local slot_type,slot_id=find(SLOT,'ScriptStruct')
    fields(slot_type,SLOT,{Weapons={'ArrayProperty',0}},true)
    local component=actor['Character Weapons Component'];local component_id=capture(component)
    local functions={}
    local function check()
      validate();same(actor,actor_id,'actor');same(actor:GetWorld(),world_id,'world')
      same(actor['Character Weapons Component'],component_id,'component-reference')
      same(component,component_id,'component');same(component:GetClass(),class_id,'component-class')
      same(component:GetOuter(),actor_id,'component-owner');same(component:GetWorld(),world_id,'component-world')
      same(StaticFindObject(PLAYER),proto_id,'player-class');same(StaticFindObject(CWC),class_id,'class')
      same(StaticFindObject(TAG),tag_id,'tag-type');same(StaticFindObject(SLOT),slot_id,'slot-type')
      for name,id in pairs(functions) do
        local fn=component[name];same(fn,id,name);same(StaticFindObject(CWC..':'..name),id,name)
        same(fn:GetOuter(),class_id,name..'-owner')
        assert(fn:GetFunctionFlags()==(function_flags[name] or 1413612545),'weapon-state-function-flags:'..name)
      end
    end
    check()
    for name,expected in pairs(getters) do
      local path=CWC..':'..name;local fn,id=find(path,'Function')
      fields(fn,path,expected,true);functions[name]=id
    end
    if selection then
      for name,expected in pairs(selection_getters) do
        local path=CWC..':'..name;local fn,id=find(path,'Function')
        fields(fn,path,expected,true);functions[name]=id
      end
    end
    check()
    local map=component.RuntimeWeaponData
    assert(map and map:type()=='TMap' and map:IsValid(),'weapon-state-map-required')
    local count=#map;assert(integer(count,0,16),'weapon-state-map-limit')
    local visited,observed=0,{}
    map:ForEach(function(key_param,value_param)
      visited=visited+1;assert(visited<=count and #map==count,'weapon-state-map-changed')
      local key=mapped(key_param:get(),tag_id);local name=key.TagName:ToString()
      if name~=MAIN and name~=SHACHI then return nil end
      assert(not observed[name],'weapon-state-duplicate-slot')
      local value=mapped(value_param:get(),slot_id);local weapons=value.Weapons
      assert(weapons and weapons:IsValid(),'weapon-state-weapons-required')
      local array_count=weapons:GetArrayNum();assert(integer(array_count,0,64),'weapon-state-weapons-limit')
      check()
      local actual_count=component:GetSlotWeapons(key)
      local current=component:GetCurrentWeaponIndex(key,false)
      local with_pending=component:GetCurrentWeaponIndex(key,true)
      assert(integer(actual_count,0,64) and actual_count==array_count,'weapon-state-count-disagrees')
      assert(integer(current,-2147483648,2147483647) and integer(with_pending,-2147483648,2147483647),'weapon-state-index-not-int')
      local armed
      if selection and name==MAIN then
        armed=component:IsArmed(key)
        assert(type(armed)=='boolean','weapon-state-armed-not-bool')
      end
      assert(key.TagName:ToString()==name and weapons:GetArrayNum()==array_count and #map==count,'weapon-state-map-changed')
      observed[name]={count=actual_count,current_index=current,with_pending_index=with_pending,
        with_pending_differs=with_pending~=current,current_in_range=current>=0 and current<actual_count,armed=armed}
      return nil -- Both supported tags are borrowed within this one Map visit.
    end)
    assert(observed[MAIN],'weapon-state-main-unavailable')
    check();assert(visited==count and #map==count and #component.RuntimeWeaponData==count,'weapon-state-map-changed')
    local transition
    if selection then
      transition=component:IsInWeaponTransition()
      assert(type(transition)=='boolean','weapon-state-transition-not-bool')
      check()
    end
    return {source=selection and 'pbz-character-weapons-v2' or 'pbz-character-weapons-v1',
      selection_scope='runtime-component',slots=observed,in_weapon_transition=transition,
      transition_scope=selection and 'synchronous-weapon-mutation' or nil,
      capacity_verified=false,combat_commit_verified=false}
  end)
  if ok then return result end
  return nil,tostring(result)
end
return M
