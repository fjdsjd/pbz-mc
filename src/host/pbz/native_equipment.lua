-- Read the V5-verified PBZBackPackSubsystem leaf fields on the game thread.
-- This is backpack-declared equipment, never a combat/animation commit. The
-- reader owns no native objects, hooks, input, UI, save state or equipment.
local identity=require('host.pbz.object_identity')
local M={};M.__index=M
local BACKPACK='/Script/ProjectPBZ.PBZBackPackSubsystem'
local MAX_INSTANCES,MAX_FIELDS,MAX_NAMES,MAX_NAME_BYTES=8,256,16,2048
local wanted={CurrentWeaponIndex='IntProperty',CurrentMainWeaponID='NameProperty',
  CurrentShaqiWeaponIndex='IntProperty',MainWeapons='ArrayProperty',ShaqiWeapons='ArrayProperty',
  BottomMedicineID='NameProperty',TopMedicineID='NameProperty',bZlgwBareMode='BoolProperty'}
local function integer(value,minimum,maximum)
  return type(value)=='number' and value==value and value>=minimum and value<=maximum and value%1==0
end
local function epoch_valid(value) return integer(value,0,2^53-1) end
local function capture(value)
  local id=identity.capture(value)
  assert(integer(id.address,1,2^53-1) and type(id.name)=='string' and #id.name>0,'equipment-invalid-object-identity')
  return id
end
local function metadata(path,fields)
  local class=StaticFindObject(path)
  assert(class and class:IsValid() and class:GetFullName()=='Class '..path,'equipment-metadata-unavailable:'..path)
  if fields then
    local found,count={},0
    class:ForEachProperty(function(property)
      count=count+1;assert(count<=MAX_FIELDS,'equipment-metadata-scan-limit:'..path)
      local name=property:GetFName():ToString();local expected=fields[name]
      if expected then
        assert(not found[name],'equipment-duplicate-field:'..name)
        assert(property:GetFullName():match('^(%S+) ')==expected,'equipment-field-type:'..name)
        if expected=='ArrayProperty' then
          assert(property:GetInner():GetFullName():match('^(%S+) ')=='NameProperty','equipment-array-inner-type:'..name)
        end
        found[name]=true
      end
    end)
    for name in pairs(fields) do assert(found[name],'equipment-field-missing:'..name) end
  end
  return class
end
local function owner_current(self,epoch)
  assert(not self.closed,'equipment-reader-closed')
  assert(epoch_valid(epoch) and epoch==self.epoch,'equipment-stale-epoch')
  local binding=self.binding
  assert(binding and not binding.closed and not binding.closing and not binding.creation_failure
    and binding:is_current(),'equipment-stale-binding')
  for name,class in pairs(self.classes) do
    assert(identity.matches(class,self.class_ids[name]),'equipment-stale-class:'..name)
  end
  for _,name in ipairs({'controller','player','actor','world'}) do
    assert(identity.matches(self[name],self[name..'_id']),'equipment-stale-object:'..name)
  end
  assert(self.controller:IsA(self.classes.controller) and self.player:IsA(self.classes.local_player),'equipment-not-local-player')
  assert(identity.matches(self.controller.Player,self.player_id),'equipment-local-player-changed')
  assert(identity.matches(self.controller.Pawn,self.actor_id),'equipment-pawn-changed')
  assert(identity.matches(binding.actor,self.actor_id) and identity.matches(self.actor,binding.actor_id),'equipment-binding-actor-changed')
  assert(identity.matches(self.actor:GetWorld(),self.world_id) and identity.matches(self.world,binding.world_id),'equipment-world-changed')
  assert(self.world:IsA(self.classes.world),'equipment-world-type')
end
local function current_subsystem(self)
  local list=FindAllOf('PBZBackPackSubsystem') or {}
  assert(type(list)=='table' and #list<=MAX_INSTANCES,'equipment-subsystem-list-limit')
  local selected,count=nil,0
  for index=1,#list do
    local value=list[index];local id=capture(value)
    -- CDOs are metadata, never a current-world equipment owner.
    if not id.name:find('Default__',1,true) then
      assert(id.name:match('^PBZBackPackSubsystem '),'equipment-subsystem-type')
      assert(identity.matches(value:GetClass(),self.class_ids.backpack),'equipment-subsystem-class')
      local outer=value:GetOuter();capture(outer)
      if identity.matches(outer,self.world_id) then selected=value;count=count+1 end
    end
  end
  assert(count==1,'equipment-subsystem-not-unique:'..count)
  return selected
end
local function subsystem_current(self)
  assert(identity.matches(self.subsystem,self.subsystem_id),'equipment-stale-subsystem')
  local current=current_subsystem(self)
  assert(identity.matches(current,self.subsystem_id),'equipment-subsystem-replaced')
  return current
end
local function name_string(value,label)
  assert(value~=nil,'equipment-unmapped-name:'..label)
  local text=type(value)=='string' and value or value:ToString()
  assert(type(text)=='string' and #text<=MAX_NAME_BYTES,'equipment-invalid-name:'..label)
  return text
end
local function names_array(value,label)
  assert(value and value:IsValid(),'equipment-unmapped-array:'..label)
  local count=value:GetArrayNum()
  assert(integer(count,0,MAX_NAMES),'equipment-array-limit:'..label)
  local result,seen={},0
  value:ForEach(function(index,wrapped)
    assert(value:IsValid() and value:GetArrayNum()==count,'equipment-array-changed:'..label)
    assert(integer(index,1,count) and index==seen+1,'equipment-array-index:'..label)
    seen=seen+1;assert(seen<=MAX_NAMES,'equipment-array-iteration-limit:'..label)
    assert(wrapped,'equipment-unmapped-name-param:'..label)
    result[index]=name_string(wrapped:get(),label)
  end)
  assert(value:IsValid() and value:GetArrayNum()==count and seen==count,'equipment-array-incomplete:'..label)
  return result,count
end
local function index_value(value,label)
  assert(integer(value,-2147483648,2147483647),'equipment-invalid-index:'..label)
  return value -- Raw declared indices, including -1 and out-of-array values.
end
local function reference(category,index,equipment_id)
  if not equipment_id or equipment_id=='' or equipment_id:lower()=='none' then return nil end
  return {kind='pbz-slot',category=category,native_slot_index=index,equipment_id=equipment_id}
end
local function declared_references(snapshot)
  local refs,selected={},{}
  for _,group in ipairs({{category='main',values=snapshot.main_weapons,index=snapshot.current_weapon_index},
    {category='shaqi',values=snapshot.shaqi_weapons,index=snapshot.current_shaqi_weapon_index}}) do
    for iterator_index,equipment_id in ipairs(group.values) do
      local ref=reference(group.category,iterator_index-1,equipment_id)
      if ref then
        refs[#refs+1]=ref
        if ref.native_slot_index==group.index then selected[group.category]=ref end
      end
    end
  end
  -- No medicine slot indices are inferred from Top/Bottom field names.
  snapshot.slot_refs=refs;snapshot.declared_selected=selected
end
function M.new(binding,controller,epoch)
  local ok,result=pcall(function()
    assert(epoch_valid(epoch),'equipment-invalid-epoch')
    assert(binding and not binding.closed and not binding.closing and not binding.creation_failure
      and binding:is_current(),'equipment-stale-binding')
    local classes={
      controller=metadata('/Script/Engine.PlayerController',{Player='ObjectProperty'}),
      controller_base=metadata('/Script/Engine.Controller',{Pawn='ObjectProperty'}),
      local_player=metadata('/Script/Engine.LocalPlayer'),world=metadata('/Script/Engine.World'),
      backpack=metadata(BACKPACK,wanted),
    }
    assert(controller and controller:IsValid() and controller:IsA(classes.controller),'equipment-controller-required')
    local player=controller.Player
    assert(player and player:IsValid() and player:IsA(classes.local_player),'equipment-local-player-required')
    local actor=binding.actor;local actor_id=capture(actor)
    assert(identity.matches(actor,binding.actor_id) and identity.matches(controller.Pawn,actor_id),'equipment-player-mismatch')
    local world=actor:GetWorld();local world_id=capture(world)
    assert(world:IsA(classes.world) and identity.matches(world,binding.world_id),'equipment-binding-world-mismatch')
    local self=setmetatable({epoch=epoch,binding=binding,controller=controller,player=player,actor=actor,world=world,
      actor_id=actor_id,world_id=world_id,controller_id=capture(controller),player_id=capture(player),
      classes=classes,class_ids={}},M)
    for name,class in pairs(classes) do self.class_ids[name]=capture(class) end
    owner_current(self,epoch)
    self.subsystem=current_subsystem(self);self.subsystem_id=capture(self.subsystem)
    owner_current(self,epoch);subsystem_current(self);owner_current(self,epoch)
    return self
  end)
  if ok then return result end
  return nil,tostring(result)
end
function M:read(expected_epoch)
  local ok,result=pcall(function()
    owner_current(self,expected_epoch)
    local owner=subsystem_current(self)
    owner_current(self,expected_epoch)
    local snapshot={epoch=self.epoch,source='pbz-backpack-declared-v1',selection_scope='backpack-declared',
      capacity_verified=false,unlocks_verified=false,combat_commit_verified=false,
      current_weapon_index=index_value(owner.CurrentWeaponIndex,'CurrentWeaponIndex'),
      current_main_weapon_id=name_string(owner.CurrentMainWeaponID,'CurrentMainWeaponID'),
      current_shaqi_weapon_index=index_value(owner.CurrentShaqiWeaponIndex,'CurrentShaqiWeaponIndex')}
    local main_count,shaqi_count
    snapshot.main_weapons,main_count=names_array(owner.MainWeapons,'MainWeapons')
    snapshot.shaqi_weapons,shaqi_count=names_array(owner.ShaqiWeapons,'ShaqiWeapons')
    snapshot.bottom_medicine_id=name_string(owner.BottomMedicineID,'BottomMedicineID')
    snapshot.top_medicine_id=name_string(owner.TopMedicineID,'TopMedicineID')
    snapshot.bare_mode=owner.bZlgwBareMode
    assert(type(snapshot.bare_mode)=='boolean','equipment-invalid-bare-mode')
    local named,names=pcall(function()return require('host.pbz.native_weapon_names').read(self,snapshot)end)
    if named then snapshot.weapon_names=names else snapshot.weapon_name_error=tostring(names)end
    subsystem_current(self);owner_current(self,expected_epoch)
    local main,shaqi=owner.MainWeapons,owner.ShaqiWeapons
    assert(main and main:IsValid() and main:GetArrayNum()==main_count,'equipment-array-post-count:MainWeapons')
    assert(shaqi and shaqi:IsValid() and shaqi:GetArrayNum()==shaqi_count,'equipment-array-post-count:ShaqiWeapons')
    owner_current(self,expected_epoch)
    declared_references(snapshot)
    return snapshot
  end)
  if ok then return result end
  return nil,tostring(result) -- Never reuse a prior successful snapshot on failure.
end
-- Separate from backpack-declared inventory: this observes the component's
-- actual scalar selection. It does not claim animation/damage completion.
function M:read_runtime(expected_epoch,options)
  local snapshot,why=require('host.pbz.native_weapon_state').read(self.actor,function()
    owner_current(self,expected_epoch)
  end,options)
  if snapshot then snapshot.epoch=self.epoch end
  return snapshot,why
end
function M:close()
  self.closed=true
  for _,key in ipairs({'binding','controller','player','actor','world','subsystem','classes','class_ids'}) do self[key]=nil end
  return true -- Only release Lua references; no native teardown or writes.
end
return M
