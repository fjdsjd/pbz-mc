-- Read only the reflected native health attributes verified in
-- vitals-runtime-20261031-032350.txt. Run on the game thread. This module owns
-- no callbacks, native state, UI visibility, effects or gameplay mode.
local identity=require('host.pbz.object_identity')
local M={}
local ATTRIBUTE='/Script/GameplayAbilities.GameplayAttributeData'
local function finite(value)
  return type(value)=='number' and value==value and math.abs(value)<math.huge
end
local function epoch_valid(value)
  return finite(value) and value>=0 and value%1==0 and value<2^53
end
local function object(path)
  local value=StaticFindObject(path)
  assert(value and value:IsValid(),'vitals-metadata-unavailable:'..path)
  return value
end
local function schema(path,wanted)
  local owner=object(path)
  local found,count,remaining={},0,0
  for _ in pairs(wanted) do remaining=remaining+1 end
  owner:ForEachProperty(function(property)
    count=count+1;assert(count<=512,'vitals-metadata-scan-limit:'..path)
    local key=property:GetFName():ToString()
    local expected=wanted[key]
    if expected then
      assert(not found[key],'vitals-duplicate-field:'..key)
      assert(property:GetFullName():match('^(%S+) ')==expected,'vitals-field-type:'..key)
      if expected=='StructProperty' then
        assert(property:GetStruct():GetFullName()=='ScriptStruct '..ATTRIBUTE,'vitals-attribute-type:'..key)
      elseif expected=='ArrayProperty' then
        assert(property:GetInner():GetFullName():match('^(%S+) ')=='ObjectProperty','vitals-array-element-type:'..key)
      end
      found[key]=true
      remaining=remaining-1
      if remaining==0 then return true end
    end
  end)
  for key in pairs(wanted) do assert(found[key],'vitals-field-missing:'..key) end
  return owner
end
local function current_value(attributes,key)
  local value=attributes[key]
  assert(value and value:IsMappedToObject() and value:GetFullName()=='ScriptStruct '..ATTRIBUTE,
    'vitals-unmapped-attribute:'..key)
  local number=value.CurrentValue
  assert(finite(number),'vitals-invalid-value:'..key)
  return number
end
function M.new(binding,controller,epoch)
  local ok,value=pcall(function()
    assert(epoch_valid(epoch),'vitals-invalid-epoch')
    assert(binding and binding:is_current(),'vitals-stale-binding')
    local classes={
      controller=schema('/Script/Engine.PlayerController',{Player='ObjectProperty'}),
      pawn=schema('/Script/Engine.Controller',{Pawn='ObjectProperty'}),
      character=schema('/Script/ProjectPBZ.PBZCharacter',{
        AttributeSetBase='ObjectProperty',AbilitySystemComponent='ObjectProperty'}),
      asc=schema('/Script/GameplayAbilities.AbilitySystemComponent',{
        OwnerActor='ObjectProperty',AvatarActor='ObjectProperty',SpawnedAttributes='ArrayProperty'}),
      pbz_asc=object('/Script/ProjectPBZ.PBZAbilitySystemComponent'),
      attributes=schema('/Script/CharacterBasics.BasicAttributeSet',{
        Health='StructProperty',Health_Max='StructProperty',Shachi='StructProperty',Shachi_Max='StructProperty'}),
      data=schema(ATTRIBUTE,{CurrentValue='FloatProperty'}),
      local_player=object('/Script/Engine.LocalPlayer'),
    }
    assert(controller and controller:IsValid() and controller:IsA(classes.controller),'vitals-controller-required')
    local player=controller.Player
    assert(player and player:IsValid() and player:IsA(classes.local_player),'vitals-local-player-required')
    local actor=binding.actor
    assert(actor:IsA(classes.character) and identity.matches(controller.Pawn,binding.actor_id),'vitals-player-mismatch')
    local asc,attributes=actor.AbilitySystemComponent,actor.AttributeSetBase
    assert(asc and asc:IsValid() and asc:IsA(classes.pbz_asc),'vitals-asc-required')
    assert(attributes and attributes:IsValid() and attributes:IsA(classes.attributes),'vitals-attributes-required')
    local self={epoch=epoch,binding=binding,controller=controller,player=player,actor=actor,
      asc=asc,attributes=attributes}
    for _,key in ipairs({'controller','player','actor','asc','attributes'}) do
      self[key..'_id']=identity.capture(self[key])
    end
    function self:check(expected_epoch)
      assert(expected_epoch==self.epoch and epoch_valid(expected_epoch),'vitals-stale-epoch')
      assert(self.binding:is_current(),'vitals-stale-binding')
      for _,key in ipairs({'controller','player','actor','asc','attributes'}) do
        assert(identity.matches(self[key],self[key..'_id']),'vitals-stale-object:'..key)
      end
      assert(identity.matches(self.controller.Player,self.player_id),'vitals-local-player-changed')
      assert(identity.matches(self.controller.Pawn,self.actor_id),'vitals-pawn-changed')
      assert(identity.matches(self.binding.actor,self.actor_id),'vitals-binding-actor-changed')
      assert(identity.matches(self.actor.AbilitySystemComponent,self.asc_id),'vitals-asc-changed')
      assert(identity.matches(self.actor.AttributeSetBase,self.attributes_id),'vitals-attributes-changed')
      assert(identity.matches(self.asc.OwnerActor,self.actor_id) and identity.matches(self.asc.AvatarActor,self.actor_id),
        'vitals-asc-player-mismatch')
      local array=self.asc.SpawnedAttributes
      local count=array:GetArrayNum()
      assert(type(count)=='number' and count%1==0 and count>=1 and count<=64,'vitals-attribute-array-size')
      local visited,matched=0,0
      array:ForEach(function(_,wrapped)
        visited=visited+1;assert(visited<=64,'vitals-attribute-array-limit')
        if identity.matches(wrapped:get(),self.attributes_id) then matched=matched+1 end
      end)
      assert(visited==count and matched==1,'vitals-attribute-set-not-unique-in-asc')
    end
    function self:read(expected_epoch)
      local success,snapshot=pcall(function()
        self:check(expected_epoch)
        local hp=current_value(self.attributes,'Health')
        local max_hp=current_value(self.attributes,'Health_Max')
        local stamina=current_value(self.attributes,'Shachi');local max_stamina=current_value(self.attributes,'Shachi_Max')
        assert(max_hp>0,'vitals-invalid-maximum')
        assert(max_stamina>0,'vitals-invalid-stamina-maximum')
        -- These are four synchronous reads from the same reflected set on
        -- the game thread. Recheck the owner without walking the ASC twice.
        assert(identity.matches(self.controller.Pawn,self.actor_id) and
          identity.matches(self.actor.AttributeSetBase,self.attributes_id),'vitals-owner-changed')
        -- Native Shield semantics are unverified. Unknown armor/absorption
        -- stay absent; never translate them to zero or fake a complete HUD.
        return {epoch=self.epoch,health_authoritative=true,hp=hp,max_hp=max_hp,
          stamina=stamina,max_stamina=max_stamina,stamina_authoritative=true,
          absorption_authoritative=false,defense_authoritative=false,source='pbz-native-health-v1'}
      end)
      if success then return snapshot end
      return nil,tostring(snapshot)
    end
    self:check(epoch)
    return self
  end)
  if ok then return value end
  return nil,tostring(value)
end
return M
