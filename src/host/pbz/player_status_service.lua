-- One game-thread status owner per loaded campaign profile. Inventory and
-- activation commit together in memory; only campaign.savepoint persists it.
local state=require('storage.state')
local rules=require('rules.status_effects')
local slots=require('rules.container_slots')
local identity=require('host.pbz.object_identity')
local valid=require('host.pbz.appearance').valid
local M={};M.__index=M
local function path(o)return assert(o:GetFullName():match('^[^ ]+ (.+)$'))end
local function now(actor)return StaticFindObject('/Script/Engine.Default__GameplayStatics'):GetTimeSeconds(actor)end
function M.new(session,log)
 local self=setmetatable({session=session,binding=session.binding,log=log,report={},seen={},mode=require('rules.game_mode').action(session.store.core,session.mode)},M)
 self.value=state.clone(session.store.core.mc_status or rules.empty());rules.validate(self.value)
 self.last=now(self.binding.actor);self.accumulator=0
 local effect=StaticFindObject('/PBZCombatAsset/Config/AttributesModifyEffect/GE_MA_Health_1_Add.GE_MA_Health_1_Add')
 assert(valid(effect),'status-health-effect-unavailable')
 effect.Modifiers:ForEach(function(_,p)
  local attribute=p:get().Attribute
  if attribute.AttributeName:ToString()=='Health' then self.attribute=attribute;return true end
 end)
 assert(self.attribute,'status-health-attribute-unavailable')
 self.effect=effect -- Native asset owns its reflected attribute value.
 -- This is an eight-byte gameplay tag, not an inferred damage enum/container.
 local checked=false
 StaticFindObject('/Script/SGameAttributes.AttributeComponent:TakeDamage'):ForEachProperty(function(p)
  if p:GetFName():ToString()=='DamageCause' then
   assert(p:GetStruct():GetFullName()=='ScriptStruct /Script/GameplayTags.GameplayTag','status-damage-cause-layout')
   checked=true;return true
  end
 end)
 assert(checked,'status-damage-cause-missing')
 self.asc_path=path(self.binding.actor.AbilitySystemComponent)
 PBZMC_HealthDecision=function(delta,cause)return self:damage(delta,cause)end
 PBZMC_LethalHealthDecision=function(delta)return self:lethal_health(delta)end
 local ok,why=PBZMC_BindHealth(self.asc_path);assert(ok,why)
 self:bind_death()
 self.binding.mc_status_service=self
 self.loop=LoopInGameThreadAfterFrames(1,function()
  local ok,err=pcall(self.tick,self)
  if not ok then
   self.report.error=tostring(err)
   if self.error~=tostring(err) then self.error=tostring(err);log('MC status unavailable: '..self.error) end
  end
 end)
 return self
end
function M:current()
 return not self.closed and self.binding:is_current() and require('host.pbz.campaign_inventory').current(self.binding)
end
function M:commit(next,address,expected,consume)
 assert(self:current(),'status-owner-changed')
 local s=self.session;assert(not s.restart_frozen and not s.session.busy,'status-transaction-unavailable')
 local ticket=s.store:checkout({});local candidate=state.object();for k,v in pairs(ticket.data) do candidate[k]=v end
 if address then
  local current=slots.get(candidate.containers,address)
  assert(current and require('storage.canonical_json')(current)==require('storage.canonical_json')(expected),'status-held-stack-changed')
  if consume then
   local draft=slots.edit(candidate.containers);local item=state.clone(current);item.count=item.count-1
   draft:set(address,item.count>0 and item or nil);candidate.containers=draft.data
  end
 end
 candidate.mc_status=state.clone(next)
 local ok,why=s.session:commit(ticket,candidate);assert(ok,why)
 self.value=next;self.dirty=false
end
function M:flush_memory()
 if self.dirty then
  -- Also used while replacing the actor: only serialize remaining times into
  -- the same in-memory profile. No stale actor API or disk write is involved.
  local s=self.session;local ticket=s.store:checkout({})
  ticket.data.mc_status=state.clone(self.value)
  local ok,why=s.store:commit(ticket,ticket.data);assert(ok,why);self.dirty=false
 end
end
function M:held()
 if not require('host.pbz.item_interface').equipment_available(self.binding) then return nil end
 local data=require('host.pbz.campaign_inventory').view(self.binding)
 local main_address='player/hotbar/'..data.player.selected
 local main=slots.get(data,main_address)
 if require('rules.native_slot_reference').is(main) then return nil end
 return {{address=main_address,stack=main},{address='player/offhand',stack=slots.get(data,'player/offhand')}}
end
function M:totem_hand()
 -- A passive death-prevention item does not need the MC action/input lease.
 -- PBZ weapons, native hit reactions and either camera retain the one shared
 -- offhand slot. Inspect only the committed current hand, never spare slots.
 if not self:current() then return nil end
 local data=require('runtime.hotbar_selection').view(self.session.store)
 local main='player/hotbar/'..data.player.selected
 for _,address in ipairs({main,'player/offhand'})do
  local item=slots.get(data,address)
  if item and item.content_id=='pbzmc:totem_of_undying' and item.count>0 then return address,item end
 end
end
function M:bind_death()
 -- Kept separate from combat/input ownership and refreshed with each pawn.
 if type(PBZMC_BindDeath)~='function'then
  self.report.death_unavailable='native-bridge-restart-required';return false
 end
 local death=self.binding.actor['Death Component'];assert(valid(death),'totem-death-component-unavailable')
 local component=death['Actor State Component'];assert(valid(component),'totem-state-component-unavailable')
 assert(death['Dead State Tag'].TagName:ToString()=='CharacterState.Dead','totem-death-tag-changed')
 self.death_component=death;self.death_state=component
 self.death_component_id=identity.capture(death);self.death_state_id=identity.capture(component)
 PBZMC_DeathDecision=function(retry)return self:prevent_native_death(retry)end
 local ok,why=PBZMC_BindDeath(path(component));assert(ok,why)
 self.report.death_unavailable=nil;return true
end
function M:activate_totem(previous,max,address,item,cause)
 local next,survival=rules.totem(previous,max,self.mode)
 self:commit(next,address,item,self.mode=='adventure')
 self.pending_totem=true
 self.log('MC totem activated hand='..address..' survival='..survival..' cooldown=60s cause='..cause)
 return next,survival
end
function M:lethal_health(delta)
 if self:current() and self.binding.mc_creative and type(delta)=='number' and delta<0 then return 0 end
 -- Native PBZ falling modifies Health directly, outside TakeDamage. Only the
 -- lethal boundary is changed here: nonlethal setters/costs keep PBZ semantics.
 if not self:current() or type(delta)~='number'or delta>=0 or self.value.totem_cooldown>0 then return delta end
 local hp=self.binding.actor.AttributeSetBase.Health.CurrentValue
 local max=self.binding.actor.AttributeSetBase.Health_Max.CurrentValue
 if hp<=0 or max<=0 or hp+delta>0 then return delta end
 local address,item=self:totem_hand();if not address then return delta end
 local next,survival=self:activate_totem(self.value,max,address,item,'PBZ.LethalHealthWrite')
 self.report.last_native_health={before=hp,incoming=-delta,health_delta=survival-hp,
  slot=address,totem=true,cooldown=next.totem_cooldown,phase='before-health-write'}
 return survival-hp
end
function M:prevent_native_death(retry)
 -- Called synchronously BEFORE ActorStateComponent starts CharacterState.Dead.
 -- HP may already be zero here (native setters / fall kills), but the death
 -- state and its delegates have not run. This is not post-death resurrection.
 if not self:current() then return false end
 local death,component=self.death_component,self.death_state
 if not identity.matches(self.binding.actor['Death Component'],self.death_component_id)
  or not identity.matches(component,self.death_state_id)then return false end
 local tag=death['Dead State Tag']
 if component:InExactState(tag)then return false end
 -- Native retry loops traverse a copy. RemovePendingState clears the live
 -- queue; duplicate entries in that old copy must not commit death afterward.
 -- Only the two pinned native retry call sites can pass retry=true.
 if retry and not component:InPendingState(tag)then
  self.report.stale_death_retries=(self.report.stale_death_retries or 0)+1;return true
 end
 if self.binding.mc_creative then
  local actor=self.binding.actor
  local hp=actor.AttributeSetBase.Health.CurrentValue
  if hp<=0 then
   StaticFindObject('/Script/SGameAttributes.Default__AttributeUtils'):ModifyCharacterAttributeValue(actor,self.attribute,0,1-hp)
  end
  component:RemovePendingState(tag)
  self.report.creative_deaths_blocked=(self.report.creative_deaths_blocked or 0)+1
  return true
 end
 if self.value.totem_cooldown>0 then return false end
 local actor=self.binding.actor
 local hp,max=actor.AttributeSetBase.Health.CurrentValue,actor.AttributeSetBase.Health_Max.CurrentValue
 if type(hp)~='number'or hp~=hp or type(max)~='number'or max<=0 or max~=max then return false end
 local address,item=self:totem_hand();if not address then return false end
 local next,survival=self:activate_totem(self.value,max,address,item,'PBZ.NativeDeath')
 -- The native gate holds the health callback recursion guard for this write.
 StaticFindObject('/Script/SGameAttributes.Default__AttributeUtils'):ModifyCharacterAttributeValue(
  actor,self.attribute,0,survival-hp)
 assert(actor.AttributeSetBase.Health.CurrentValue>0,'totem-native-health-recovery-failed')
 -- AddPendingState queues before trying activation. Consume this request as
 -- handled after removing its pending entries, so it cannot kill on the next
 -- state update merely because the same totem is now on cooldown.
 component:RemovePendingState(tag)
 self.report.last_native_death={before=hp,after=actor.AttributeSetBase.Health.CurrentValue,
  slot=address,totem=true,cooldown=next.totem_cooldown,phase='before-death-state'}
 return true
end
function M:damage(delta,cause)
 if not self:current() then return delta end
 if type(delta)~='number' or delta>=0 then return delta end
 if self.binding.mc_creative then return 0 end
 local hp=self.binding.actor.AttributeSetBase.Health.CurrentValue
 local max=self.binding.actor.AttributeSetBase.Health_Max.CurrentValue
 if hp<=0 or max<=0 then return delta end
 -- Exact known fire tags only. Unknown/native story causes pass normally;
 -- never turn resistance to fire into general damage immunity.
 local fire=cause=='Damage.Cause.Fire' or cause=='Damage.Type.Fire' or cause=='Damage.Element.Fire'
 -- The native gate only calls here for negative Health additive writes inside
 -- AttributeComponent::TakeDamage. Healing/story setters never reach armor.
 -- It is additional MC protection after PBZ's own defense calculation; no
 -- global native Defense value or weapon group attribute is changed.
 local armor=require('host.pbz.armor_state').get(self.session.store.core.containers.player.armor)
 local bypass=cause=='Damage.Cause.MCFall' or cause=='Damage.Cause.MCFlyIntoWall'
 local reduced,armor_receipt=require('rules.armor').reduce(-delta,max,armor,bypass)
 local next,remaining,absorbed=rules.damage(self.value,reduced,fire,false)
 local triggered,address,item=false
 if remaining>=hp and next.totem_cooldown<=0 then
  address,item=self:totem_hand()
  if address then
   local survival;next,survival=self:activate_totem(next,max,address,item,cause)
   remaining=hp-survival;triggered=true
  end
 end
 if not triggered then self.value=next;self.dirty=true end
 self.report.last_damage={before=hp,incoming=-delta,absorbed=absorbed,health_delta=-remaining,
  cause=cause,totem=triggered,slot=address,cooldown=next.totem_cooldown,armor=armor_receipt}
 return -remaining
end
function M:consume(record)
 if record.kind~='food' or not self:current() or self.seen[record.action_id] then return false end
 local item=record.equipment[record.hand]
 if item and item.content_id=='pbzmc:chorus_fruit' then
   if not self.chorus or self.chorus.closed then self.chorus=require('host.pbz.chorus_fruit').new(self) end
   return self.chorus:consume(record)
 end
 if not item or item.content_id~='pbzmc:golden_apple' and item.content_id~='pbzmc:enchanted_golden_apple' then return false end
 if rules.remaining(self.value,item.content_id)>0 then return false end
 local hands=self:held();if not hands then return false end
 local selected=record.hand=='offhand' and hands[2] or hands[1]
 local max=self.binding.actor.AttributeSetBase.Health_Max.CurrentValue
 local next=rules.apple(self.value,item.content_id,max)
 self:commit(next,selected.address,item,self.mode=='adventure')
 self.seen_order=self.seen_order or {};self.seen_order[#self.seen_order+1]=record.action_id
 if #self.seen_order>128 then self.seen[table.remove(self.seen_order,1)]=nil end
 self.seen[record.action_id]=true;self.report.last_consumed=item.content_id
 self.report.consumed=(self.report.consumed or 0)+1
 self.log('MC food consumed id='..item.content_id..' cooldown='..(rules.remaining(next,item.content_id)/20)..'s')
 self:sound('burp');return true
end
function M:pearl_cooldown(record)
 if not self:current() then return false,'status-owner-changed' end
 local item=record.equipment[record.hand]
 if not item or item.content_id~='pbzmc:ender_pearl' or rules.remaining(self.value,item.content_id)>0 then return false,'pearl-cooldown' end
 local hands=self:held();if not hands then return false,'equipment-unavailable' end
 local selected=record.hand=='offhand' and hands[2] or hands[1]
 -- Cooldown and the unchanged held stack are validated in one memory commit.
 -- The pearl never decrements in any gameplay mode.
 self:commit(rules.start_cooldown(self.value,item.content_id),selected.address,item,false)
 return true
end
function M:sound(event)
 local service=require('host.pbz.building_service').get(self.binding)
 if service and service.audio then
  pcall(service.audio.combat,service.audio,event,self.binding.actor:K2_GetActorLocation(),require('UEHelpers').GetPlayerController())
 end
end
function M:tick()
 if not self:current() then self:close();return end
 local t=now(self.binding.actor);local dt=math.max(0,math.min(.25,t-self.last));self.last=t
 local raw,why=PBZMC_PollHealth(self.asc_path);assert(raw,why)
 self.report.native=assert(require('dkjson').decode(raw))
 require('host.pbz.native_totem_fall').tick(self)
 local hp=self.binding.actor.AttributeSetBase.Health.CurrentValue;local max=self.binding.actor.AttributeSetBase.Health_Max.CurrentValue
 if hp<=0 then
  if next(self.value.effects) then self.value.effects={};self.value.absorption=0;self.dirty=true end
  self.accumulator=0
 else
  self.accumulator=self.accumulator+dt
  local ticks=math.floor(self.accumulator*20+1e-7)
  if ticks>0 then
   self.accumulator=self.accumulator-ticks/20
   if next(self.value.effects) or rules.cooling(self.value) then
    local next,healing=rules.advance(self.value,ticks,max);self.value=next;self.dirty=true
    if healing>0 and hp<max then
     StaticFindObject('/Script/SGameAttributes.Default__AttributeUtils'):ModifyCharacterAttributeValue(
      self.binding.actor,self.attribute,0,math.min(max-hp,healing))
    end
   end
  end
 end
 self.binding.mc_status=self.binding.mc_status or {}
 self.binding.mc_status.regeneration=self.value.effects.regeneration~=nil
 if self.pending_totem or next(self.value.effects) or self.fx then
  if not self.fx then self.fx=require('host.pbz.status_particles').new(self.binding,require('UEHelpers').GetPlayerController()) end
  if self.pending_totem then self.pending_totem=false;self:sound('totem');self.fx:activate(t);self.activation_at=t end
  self.fx:step(t,self.value)
 end
end
function M:close()
 if self.closed then return end
 require('host.pbz.native_totem_fall').close(self)
 self.closed=true
 if self.loop then CancelDelayedAction(self.loop);self.loop=nil end
 if self.fx then self.fx:close() end
 if self.chorus then self.chorus:close() end
 if self.binding.mc_status_service==self then self.binding.mc_status_service=nil end
end
return M
