-- MC chooses damage once; PBZ owns armour, attribution and hit reactions.
local valid=require('host.pbz.appearance').valid
local identity=require('host.pbz.object_identity')
local json=require('dkjson')
local scaling=require('rules.damage_scaling')
local M={};M.__index=M
local function path(o) return assert(o:GetFullName():match('^[^ ]+ (.+)$')) end
local function component(actor,class)
  local list=actor:K2_GetComponentsByClass(StaticFindObject(class))
  return #list==1 and list[1]:get() or nil
end
local function native(request)
  local raw,why=PBZMC_NativeHit(json.encode(request));if not raw then return nil,why end
  local result,_,err=json.decode(raw);return result,err
end
local function native_shield(attributes)
  -- Shield is a real PBZ attribute, separate from MC absorption. Some actors
  -- do not expose it; unavailable data must not be invented as a zero loss.
  local ok,value=pcall(function()return attributes.Shield.CurrentValue end)
  return ok and type(value)=='number' and value==value and value>=0 and value<math.huge and value or nil
end
function M.new(binding)
  return setmetatable({binding=binding,seen={},order={},report={},
    flash=require('host.pbz.hit_flash').new(binding)},M)
end
function M:eligible(target)
  if require('host.pbz.mob_living').alive(self.binding,target) then return true end
  if not valid(target) or identity.matches(target,self.binding.actor_id)
    or not target:IsA(StaticFindObject('/Script/ProjectPBZ.PBZCharacter')) or not target.bCanBeDamaged
    or not identity.matches(target:GetWorld(),self.binding.world_id) then return false end
  local attributes=target.AttributeSetBase
  if not valid(attributes) or attributes.Health.CurrentValue<=0 then return false end
  local faction=StaticFindObject('/Script/SGameCombatSystem.Default__FactionUtils')
  return faction:GetFactionRelation(self.binding.actor,target)==2
end
function M:_hit(target,amount,action_id,contact)
  assert(self.binding:is_current() and type(action_id)=='string','mc-damage-source-stale')
  assert(type(amount)=='number' and amount>0 and amount<=10000,'mc-damage-range')
  if not self:eligible(target) then return false end
  if contact.kind=='sword'and not action_id:find('summon/',1,true)then
    local status=self.binding.mc_status_service
    local bonus=require('rules.status_effects').attack_bonus(status and status.value)
    local profile=require('content.combat_profiles').get(contact.weapon_id)
    local base=profile.free_melee_damage or 4
    amount=amount*math.max(0,1+bonus/math.max(1,base))
    if amount<=0 then return false end
  end
  local living=require('host.pbz.mob_living')
  if living.find(self.binding,target) then
    local p=require('content.combat_profiles').get(contact.weapon_id)
    -- PBZ coefficients are not MC health points. Keep weapon strength and
    -- charge/critical multipliers, without scaling to the summon's max HP.
    local base=p.free_melee_damage or 1
    if p.kind=='sword' then
      base=({wooden=4,stone=5,copper=5,iron=6,golden=4,diamond=7,netherite=8})[contact.weapon_id:match('pbzmc:(%a+)_')] or base
    elseif contact.kind=='arrow' then base=6/1.8 end
    local points=contact.mc_damage or amount*base/math.max(.001,p.adventure_attack or 1)
    local accepted,result=living.hit(self.binding,target,points,action_id,contact)
    self.report=result or {accepted=false,route='mc-living'}
    return accepted
  end
  local target_id=identity.capture(target);local key=action_id..'/'..target_id.address
  if self.seen[key] then return false end
  local attributes=target.AttributeSetBase
  local damage=component(target,'/Script/SGameAttributes.AttributeComponent')
  -- PBZ uses MainBody from this component during damage settlement too,
  -- including on repeated thrusts that do not replay the hit animation.
  local reaction=component(target,'/Script/SGameCombatSystem.HitreactComponent')
  if not valid(damage) then return false end
  assert(type(PBZMC_NativeHit)=='function','mc-native-hit-bridge-0.14-required')
  local attack=self.binding.actor.AttributeSetBase.Attack.CurrentValue
  assert(type(attack)=='number' and attack>0 and attack==attack and attack<math.huge,'mc-native-attack-snapshot-invalid')
  local maximum_ok,maximum=pcall(function()return attributes.Health_Max.CurrentValue end)
  local scaled=scaling.apply(amount,maximum_ok and maximum or nil,contact.kind,contact.weapon_id,attack)
  if not maximum_ok then scaled.target_max_error=tostring(maximum) end
  local source=StaticConstructObject(StaticFindObject('/Script/SGameCombatSystem.DamageSource_GameplayEffect'),self.binding.actor)
  assert(valid(source),'mc-native-source-allocation')
  local direction=contact.direction
  local length=math.sqrt(direction.X^2+direction.Y^2+direction.Z^2);assert(length>1e-6,'mc-hit-direction')
  direction={X=direction.X/length,Y=direction.Y/length,Z=direction.Z/length}
  local request={phase='damage',kind=contact.kind,pawn=path(self.binding.actor),target=path(target),source=path(source),
    component=path(damage),reaction=valid(reaction) and path(reaction) or nil,coefficient=scaled.coefficient,
    location=contact.location,direction=direction,normal=contact.normal or {X=-direction.X,Y=-direction.Y,Z=-direction.Z}}
  if contact.smash then request.smash=true end
  local before=attributes.Health.CurrentValue;local shield_before=native_shield(attributes)
  -- Reserve before dispatch. Sustained multi-target piercing may fill the
  -- history quickly, so evict one entry without shifting the entire array.
  local slot=(self.last_seen_slot or 0)%2048+1
  local retired=self.order[slot]
  if retired then self.seen[retired]=nil end
  self.seen[key]=true;self.order[slot]=key;self.last_seen_slot=slot
  local receipt,why=native(request)
  local after=valid(attributes) and attributes.Health.CurrentValue or nil
  local shield_after=valid(attributes) and native_shield(attributes) or nil
  self.report={action_id=action_id,target=target_id.name,base_requested=scaled.base_requested,requested=scaled.requested,
    target_max=scaled.target_max,target_max_valid=scaled.target_max_valid,target_max_error=scaled.target_max_error,
    scaling_multiplier=scaled.scaling_multiplier,percentage=scaled.percentage,weapon_id=scaled.weapon_id,
    weapon_kind=scaled.weapon_kind,full_weapon_percentage=scaled.full_weapon_percentage,
    scaling_reason=scaled.scaling_reason,reference_full_base=scaled.reference_full_base,
    clamped=scaled.clamped,native_limit=scaled.native_limit,coefficient=scaled.coefficient,before=before,after=after,
    observed_delta=after and before-after,native_shield_before=shield_before,native_shield_after=shield_after,
    native_shield_delta=shield_before and shield_after and shield_before-shield_after,
    dispatched=receipt and receipt.dispatched==true or false,blocked=receipt and receipt.blocked==true or false,
    error=why,route='native-AttributeComponent-TakeDamage'}
  self.report.health_hit=self.report.dispatched and not self.report.blocked and (self.report.observed_delta or 0)>0
  self.report.native_shield_hit=self.report.dispatched and not self.report.blocked and (self.report.native_shield_delta or 0)>0
  self.report.accepted=self.report.health_hit or self.report.native_shield_hit
  -- Golden/native shields can absorb a successful hit without HP movement.
  -- Keep their native settlement; only fix the false miss/absent feedback.
  if not self.report.accepted then return false end
  if contact.feedback==false then return true end
  if after and after>0 and valid(reaction) and identity.matches(target,target_id) then
    request.phase='feedback'
    local feedback,err=native(request)
    self.report.feedback=feedback~=nil;self.report.feedback_error=err
    local ok,state=pcall(function() return reaction:GetCurrentHitState().TagName:ToString() end)
    if ok then self.report.hit_state=state end
  end
  local ok,shown=pcall(self.flash.show,self.flash,target)
  self.report.flash=ok and shown or false;self.report.flash_error=not ok and tostring(shown) or nil
  return true
end
function M:hit(target,amount,action_id,contact)
  local ok,result=pcall(require('host.pbz.entity_effects').with_attack_base,self.binding,self._hit,self,target,amount,action_id,contact)
  if not ok then self.report.error=tostring(result);return false end
  return result
end
function M:close() self.flash:close() end
return M
