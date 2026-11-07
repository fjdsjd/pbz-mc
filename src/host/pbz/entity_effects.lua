-- Shared potion / mob / command effect adapter. Only admitted, affected actors
-- are ticked. Unreal calls stay on the game thread; leases expire on replacement.
local rules=require('rules.status_effects')
local potions=require('rules.potions')
local state=require('storage.state')
local identity=require('host.pbz.object_identity')
local valid=require('host.pbz.appearance').valid
local M={}
M.supported={speed=true,slowness=true,strength=true,weakness=true,jump_boost=true,
 regeneration=true,poison=true,wither=true,instant_health=true,instant_damage=true,
 resistance=true,fire_resistance=true,absorption=true,water_breathing=true,
 levitation=true,slow_falling=true,haste=true,mining_fatigue=true,
 night_vision=true,invisibility=true,blindness=true,darkness=true}
local function health(h)
 if h.kind=='mc'then return h.mob.health,h.mob.max_health,1 end
 local a=h.actor.AttributeSetBase;return a.Health.CurrentValue,a.Health_Max.CurrentValue,a.Health_Max.CurrentValue/20
end
local function path(o)return assert(o:GetFullName():match('^[^ ]+ (.+)$'))end
local function fire(cause)return cause=='Damage.Cause.Fire'or cause=='Damage.Type.Fire'or cause=='Damage.Element.Fire'end
function M.with_attack_base(binding,fn,...)
 local module=package.loaded['host.pbz.command_service'];local service=module and module.get(binding)
 local entities=service and service.entities
 local s=entities and entities.effects[entities.options.player_id]
 if not s or not s.attack_attribute or s.borrowed_attack then return fn(...)end
 -- MC computes potion-adjusted melee damage itself; arrows/explosions are
 -- unaffected by Strength/Weakness. Its native bridge needs a positive base
 -- for normalization, including a projectile landing after switching to PBZ.
 -- Borrow only our own current attribute lease for this synchronous call.
 local actor=s.handle.actor;local value=actor.AttributeSetBase.Attack.CurrentValue
 if value~=s.written_damage or not s.base_damage or s.base_damage<=0 then return fn(...)end
 local base=s.base_damage;local attribute=s.attack_attribute
 local utility=StaticFindObject('/Script/SGameAttributes.Default__AttributeUtils')
 utility:ModifyCharacterAttributeValue(actor,attribute,0,base-value)
 local written=actor.AttributeSetBase.Attack.CurrentValue;s.borrowed_attack=true
 local result=table.pack(pcall(fn,...));s.borrowed_attack=nil
 if entities:current()and entities.effects[s.handle.id]==s and identity.matches(actor,s.handle.identity)then
  local current=actor.AttributeSetBase.Attack.CurrentValue
  s.base_damage=current==written and base or current;s.written_damage=current
  entities:_attack_modifier(s,rules.attack_bonus(s.state))
 end
 if not result[1]then error(result[2],0)end
 return table.unpack(result,2,result.n)
end
function M.install(C)
 function C:actor_handle(actor)
  if identity.matches(actor,self.binding.actor_id)then return self:_admit(actor,'player')end
  local mob,group=require('host.pbz.mob_living').find(self.binding,actor)
  if mob then return self:_admit(actor,'mc',mob,group)end
  assert(valid(actor)and actor:IsA(StaticFindObject('/Script/ProjectPBZ.PBZCharacter')),'effect-target-not-living')
  return self:_admit(actor,'native')
 end
 function C:nearby(point,radius)
  local found,out,seen={},{},{}
  require('UEHelpers').GetKismetSystemLibrary():SphereOverlapActors(self.binding.actor,point,radius,
   require('host.pbz.build_world').object_types,StaticFindObject('/Script/Engine.Character'),{},found)
  local function admit(actor)
   if not valid(actor)or seen[actor:GetAddress()]then return end
   seen[actor:GetAddress()]=true
   local ok,h=pcall(self.actor_handle,self,actor)
   if not ok then return end
   local hp=health(h);if hp<=0 then return end
   local p=actor:K2_GetActorLocation();local half,r=self:_dimensions(h)
   local dx=math.max(0,math.abs(point.X-p.X)-r);local dy=math.max(0,math.abs(point.Y-p.Y)-r)
   local dz=math.max(0,math.abs(point.Z-p.Z)-half)
   local distance=math.sqrt(dx*dx+dy*dy+dz*dz)
   if distance<radius then out[#out+1]={handle=h,distance=distance,position={X=p.X,Y=p.Y,Z=p.Z}}end
  end
  for _,raw in ipairs(found)do admit(raw.GetFullName and raw or raw:get())end
  -- Some native player capsules don't answer overlap queries during actions.
  admit(self.binding.actor)
  local group=self.binding.mc_summons
  if group then for _,mob in ipairs(group.mobs)do admit(mob.actor)end end
  table.sort(out,function(a,b)return a.distance<b.distance end)
  while #out>128 do table.remove(out)end
  return out
 end
 function C:_status(h)
  local status=h.player and self.binding.mc_status_service
  assert(status and status:current(),'effect-player-status-unavailable');return status
 end
 function C:_effect_state(h)
  if not self.effect_timer then
   self.effect_timer=LoopInGameThreadAfterFrames(1,function()
    local ok,why=pcall(self.tick,self)
    if not ok then self.log('MC effect update: '..tostring(why))end
   end)
  end
  local s=self.effects[h.id]
  if not s then
   local count=0;for _ in pairs(self.effects)do count=count+1 end
   assert(count<256,'effect-active-entity-limit-256')
   s={handle=h,state=rules.empty(),leases={}};s.values=s.state.effects;self.effects[h.id]=s
  end
  if h.player then s.state=self:_status(h).value;s.values=s.state.effects end
  if h.kind=='mc'then h.mob.status=s.state end
  return s
 end
 function C:_movement(s,field,factor,add)
  local move=s.handle.actor.CharacterMovement;assert(valid(move),'effect-movement-unavailable')
  local current=move[field];assert(type(current)=='number','effect-movement-field:'..field)
  local lease=s.leases[field]
  if not lease then lease={object=move,identity=identity.capture(move),base=current};s.leases[field]=lease
  elseif current~=lease.written then lease.base=current end
  local value=lease.base*factor+(add or 0)
  if value~=current then move[field]=value end
  -- UE movement properties are float32; Lua arithmetic is float64. Compare
  -- against the value the host actually stored, or fractional base speeds
  -- appear to be external changes and compound the multiplier every tick.
  lease.written=move[field]
 end
 function C:_restore(s,field)
  local lease=s.leases[field];if not lease then return end
  if identity.matches(lease.object,lease.identity)and lease.object[field]==lease.written then lease.object[field]=lease.base end
  s.leases[field]=nil
 end
 function C:_attack_modifier(s,bonus)
  if s.borrowed_attack then return end
  local h=s.handle
  if h.kind=='mc'then
   if bonus~=0 then
    if s.base_damage==nil then s.base_damage=h.mob.attack_damage or h.mob.ai.damage or h.mob.def.damage end
    h.mob.attack_damage=math.max(0,s.base_damage+bonus)
   elseif s.base_damage~=nil then h.mob.attack_damage=s.base_damage;s.base_damage=nil end
  else
   if bonus~=0 and not s.attack_attribute then
    local object=StaticFindObject('/PBZCombatAsset/Config/AttributesModifyEffect/GE_MA_Attack_1_Add.GE_MA_Attack_1_Add')
    if not valid(object)then object=LoadAsset('/PBZCombatAsset/Config/AttributesModifyEffect/GE_MA_Attack_1_Add.GE_MA_Attack_1_Add')end
    assert(valid(object),'effect-native-attack-attribute-unavailable')
    object.Modifiers:ForEach(function(_,p)local a=p:get().Attribute
     if a.AttributeName:ToString()=='Attack'then s.attack_attribute=a;return true end end)
    assert(s.attack_attribute,'effect-native-attack-attribute-missing');s.attack_asset=object
   end
   if s.attack_attribute then
    local value=h.actor.AttributeSetBase.Attack.CurrentValue
    if not s.base_damage then s.base_damage=value
    elseif s.written_damage and value~=s.written_damage then s.base_damage=value end
    -- PBZ has level-scaled attack, so three vanilla points modify its baseline
    -- by 3/4 instead of becoming irrelevant at the next chapter.
    local next=math.max(0,s.base_damage*(1+bonus/4))
    if next~=value then StaticFindObject('/Script/SGameAttributes.Default__AttributeUtils'):ModifyCharacterAttributeValue(h.actor,s.attack_attribute,0,next-value)end
    s.written_damage=h.actor.AttributeSetBase.Attack.CurrentValue
    if bonus==0 then s.attack_attribute=nil;s.attack_asset=nil;s.base_damage=nil;s.written_damage=nil end
   end
  end
 end
 function C:_modifiers(s)
  local h=s.handle;local e=s.values;s.state.effects=e
  local owns=h.player and self.binding.mc_movement_owner~=nil
  for _,field in ipairs({'MaxWalkSpeed','MaxFlySpeed'})do
   if not owns and (e.speed or e.slowness)then self:_movement(s,field,rules.speed(s.state))else self:_restore(s,field)end
  end
  if not owns and e.jump_boost then self:_movement(s,'JumpZVelocity',1,200*(e.jump_boost.amplifier+1))else self:_restore(s,'JumpZVelocity')end
  if not owns and (e.levitation or e.slow_falling)then
   local falling=h.actor:GetVelocity().Z<0
   self:_movement(s,'GravityScale',e.levitation and 0 or falling and .125 or 1)
  else self:_restore(s,'GravityScale')end
  self:_attack_modifier(s,rules.attack_bonus(s.state))
  require('host.pbz.effect_visuals').update(self,s)
 end
 function C:_effect_health(h,delta,id)
  local hp,maximum=health(h)
  if delta>0 then
   delta=math.min(delta,maximum-hp)
   if h.kind=='mc'then h.mob.health=hp+delta else self:_health_delta(h,delta)end
  elseif delta<0 then
   if h.kind=='mc'then
    require('host.pbz.mob_living').hit(self.binding,h.actor,-delta,nil,{kind='magic',command=true,knockback=false})
   else
    if h.player then delta=self:_status(h):damage(delta,'Damage.Cause.MCPotion')
    else
     local s=self.effects[h.id]
     if s then local next,remaining=rules.damage(s.state,-delta,false,false);s.state=next;s.values=next.effects;delta=-remaining end
    end
    self:_health_delta(h,delta)
   end
  end
  self:invalidate()
 end
 function C:_effect(e,id,ticks,amplifier,hide,scale)
  local h=self:_resolve(e);id=id:gsub('^minecraft:','');amplifier=amplifier or 0
  assert(M.supported[id],'effect-unsupported-system:'..tostring(id))
  assert(h.kind~='boat','effect-target-not-living')
  assert(type(ticks)=='number'and ticks%1==0 and ticks>0 and ticks<=2147483647,'effect-duration-invalid')
  assert(type(amplifier)=='number'and amplifier%1==0 and amplifier>=0 and amplifier<=255,'effect-amplifier-invalid')
  local hp,maximum,unit=health(h);assert(hp>0,'effect-target-dead')
  local name=h.kind=='mc'and h.mob.def.name or ''
  if potions.immune(id,name)then return false,'effect-immune'end
  if h.player and self.binding.mc_creative and ({poison=true,wither=true,instant_damage=true})[id]then return false,'creative-immune'end
  if id=='instant_health'or id=='instant_damage'then
   self:_effect_health(h,potions.instant(id,amplifier,scale,potions.undead(name))*unit,id)
   return true,{effect=id,instant=true}
  end
  local s=self:_effect_state(h);local old=state.clone(s.state)
  if h.player then s.state=state.clone(s.state)end
  rules.add(s.state,id,ticks,amplifier,h.kind=='mc'and 20 or maximum,nil,hide)
  s.values=s.state.effects
  local ok,why=pcall(function()
   self:_modifiers(s)
   if h.kind=='native'then self:_native_effect_lease(s)end
   if h.player then s.state.serial=s.state.serial+1;self:_status(h):commit(s.state)end
  end)
  if not ok then s.state=old;s.values=old.effects;pcall(self._modifiers,self,s);error(why)end
  self:invalidate();return true,{effect=id,ticks=ticks,amplifier=amplifier}
 end
 function C:apply_actor(actor,id,ticks,amplifier,hide,scale)
  local ok,a,b=pcall(function()return self:_effect({handle=self:actor_handle(actor)},id,ticks,amplifier,hide,scale)end)
  if not ok then self.log('MC effect failed: '..tostring(a));return false,tostring(a)end
  return a,b
 end
 function C:_native_effect_lease(s)
  assert(type(PBZMC_EntityHealthLease)=='function','effect-native-bridge-restart-required')
  local asc=s.handle.actor.AbilitySystemComponent
  local ok,why=PBZMC_EntityHealthLease(path(asc),s.handle.id);assert(ok,why);s.native=true;s.refreshed=self:_time()
  if not self.entity_health_callback then
   self.entity_health_callback=function(id,delta,cause)
    local active=self.effects[id]
    if not active or not self:current()then return delta end
    self:_resolve({handle=active.handle})
    local next,amount=rules.damage(active.state,-delta,fire(cause),false)
    active.last_native_damage={incoming=-delta,remaining=amount,mitigated=-delta-amount}
    active.state=next;active.values=next.effects;return -amount
   end
   PBZMC_EntityHealthDecision=self.entity_health_callback
  end
 end
 function C:_retire_effect(s)
  -- Releasing a host lease must not erase the campaign's persistent effects.
  s.state=state.clone(s.state);s.values={};pcall(self._modifiers,self,s)
  for field in pairs(s.leases)do pcall(self._restore,self,s,field)end
  if s.native then pcall(PBZMC_EntityHealthLease,'',s.handle.id)end
  if s.handle.kind=='mc'then s.handle.mob.status=nil end
  self.effects[s.handle.id]=nil
 end
 function C:_clear_effect(e,id)
  local h=self:_resolve(e);id=id and id:gsub('^minecraft:','')
  local s=self.effects[h.id]or h.player and self:_effect_state(h)
  if not s then return false,'effect-not-present'end
  if h.player then s.state=state.clone(s.state);s.values=s.state.effects end
  local changed=id and s.values[id]~=nil or not id and next(s.values)~=nil
  if id then s.values[id]=nil else s.values={};s.state.effects=s.values end
  if not id or id=='absorption'then s.state.absorption=0 end
  if h.player then self:_status(h):commit(s.state)end
  self:_modifiers(s)
  if not next(s.values)then self:_retire_effect(s)end
  return changed,{cleared=id or 'all'}
 end
 function C:tick(now)
  if not self:current()then self:close();return end
  now=now or self:_time()
  local delta=self.last_tick and math.max(0,now-self.last_tick)or 0;self.last_tick=now
  self.accumulator=(self.accumulator or 0)+math.min(delta,.25)
  local ticks=math.floor(self.accumulator*20+1e-6);if ticks==0 then return end
  self.accumulator=self.accumulator-ticks/20
  local status=self.binding.mc_status_service
  if status and next(status.value.effects)then self:_effect_state(self:actor_handle(self.binding.actor))end
  for _,s in pairs(self.effects)do
   local ok,why=pcall(function()
    local h=self:_resolve({handle=s.handle});local hp,maximum,unit=health(h);assert(hp>0,'effect-target-dead')
    if h.player then s.state=self:_status(h).value;s.values=s.state.effects
    else
     local next,heal,_,pulses=rules.advance(s.state,ticks,h.kind=='mc'and 20 or maximum)
     s.state=next;s.values=next.effects;if h.kind=='mc'then h.mob.status=next end
     if heal>0 then self:_effect_health(h,heal,'regeneration')end
     for id,count in pairs(pulses)do
      if count>0 then local current=health(h);local damage=count*unit
       if id=='poison'then damage=math.max(0,math.min(damage,current-unit))end
       if damage>0 then self:_effect_health(h,-damage,id)end
      end
     end
    end
    self:_modifiers(s)
    local lev=s.values.levitation
    if lev and not (h.player and self.binding.mc_creative_flight)then
     local v=h.actor:GetVelocity();local z=v.Z+(100*(lev.amplifier+1)-v.Z)*(1-.8^ticks)
     h.actor:LaunchCharacter({X=0,Y=0,Z=z},false,true)
    end
    if s.native and now-(s.refreshed or 0)>.5 then self:_native_effect_lease(s)end
    self:_effect_particles(s,now)
   end)
   if not ok or not next(s.values)then
    self:_retire_effect(s)
    if not ok and tostring(why):find('dead',1,true)==nil then self.log('MC effect retired: '..tostring(why))end
   end
  end
  if self.effect_fx then self.effect_fx:step(now)end
  if not next(self.effects)and (not self.effect_fx or #self.effect_fx.particles==0)and self.effect_timer then
   CancelDelayedAction(self.effect_timer);self.effect_timer=nil
  end
 end
 function C:_effect_particles(s,now)
  if s.handle.player or not rules.has_particles(s.state)or now<(s.next_particle or 0)then return end
  s.next_particle=now+.4
  local p=s.handle.actor:K2_GetActorLocation();local eye=self.binding.actor:K2_GetActorLocation()
  if (p.X-eye.X)^2+(p.Y-eye.Y)^2+(p.Z-eye.Z)^2>3000^2 then return end
  if not self.effect_fx then self.effect_fx=require('host.pbz.status_particles').acquire(self.binding,require('host.pbz.local_player').controller(),self)end
  self.effect_fx:emit_at(rules.particle_color(s.state),p,40,80)
 end
end
return M
