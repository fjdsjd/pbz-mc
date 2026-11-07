-- Action time/state from wukong-steve 0.11.0 SwordCombat / ModernWeaponCombat.
-- Copyright (c) 2026 桃天帝不差. PolyForm Noncommercial 1.0.0; retain NOTICE.
-- The adapter must authorize actual native exclusivity before every operation.
-- A handler is synchronous, returns a boolean plus optional use result, and owns the world transaction;
-- it must not defer an active action without retaining its source/action stamp.
local rules=require('rules.minecraft_combat')
local actions=require('content.item_actions')
local stacks=require('rules.item_stack')
local items=require('content.items')
local native=require('rules.native_slot_reference')
local value=require('storage.state')
local M={};M.__index=M
local function finite(n) return type(n)=='number' and n==n and math.abs(n)<math.huge end
local function integer(n) return finite(n) and n%1==0 and n>=0 and n<2^53 end
local function id(stack) return stack and stack.content_id end
local function float(n) return string.unpack('<f',string.pack('<f',n)) end
local function source(c)
  assert(integer(c.epoch) and integer(c.equipment_revision) and integer(c.input_epoch),'invalid-action-source')
  return tostring(c.epoch)..'/'..tostring(c.equipment_revision)..'/'..tostring(c.input_epoch)
end
local function snapshot(c)
  assert(c.mode=='free' or c.mode=='adventure' or c.mode=='creative','invalid-action-mode')
  for _,hand in ipairs({'main','offhand'}) do
    if c[hand] then
      assert(not native.is(c[hand]),'native-item-in-minecraft-actions');stacks.validate(c[hand],items)
    end
  end
  return {epoch=c.epoch,equipment_revision=c.equipment_revision,input_epoch=c.input_epoch,
    main=stacks.copy(c.main),offhand=stacks.copy(c.offhand),mode=c.mode}
end
function M.new(host)
  assert(type(host)=='table' and type(host.authorize)=='function' and type(host.cancel)=='function'
    and type(host.handlers)=='table','missing-minecraft-action-adapter')
  return setmetatable({host=host,serial=0,previous_attack=-100,last_use=-100,next_pearl=0,next_wind=0,
    last_mining_swing=-100,last_jab=-100,last_spear_impact=-100,
    last_seq=-1,seen={}},M)
end
function M:_cancel(reason)
  local old=self.bound
  self.bound=nil;self.stamp=nil;self.attack_down=false;self.use_down=false;self.using=nil
  self.breaking_block=false
  self.attack_target_checked=nil;self.attack_target_consumed=false;self.target_swing_until=nil
  self.last_entity_use=nil
  self.swing_start=nil;self.swing_hand=nil;self.last_jab=-100;self.last_spear_impact=-100;self.attack_id=nil;self.spear_release=nil
  if old then self.host:cancel(old,reason) end
  -- Player cooldowns deliberately survive equipment/group/pause cancellations.
end
function M:cancel(reason)
  local ok,why=pcall(self._cancel,self,reason or 'cancelled')
  if not ok then self.fault=tostring(why);return false,self.fault end
  return true
end
function M:_call(kind,record)
  assert(self.bound and self.host:authorize(self.bound)==true,'combat-ownership-lost')
  local handler=assert(self.host.handlers[kind],'combat-handler-unavailable:'..kind)
  record=record or {};record.source=self.stamp;record.equipment=value.clone(self.bound)
  record.action_id=record.action_id or self.attack_id
  local result,outcome=handler(self.host,record)
  assert(type(result)=='boolean','invalid-combat-handler-result:'..kind)
  assert(outcome==nil or outcome=='success' or outcome=='consume' or outcome=='pass' or outcome=='fail',
    'invalid-combat-use-result:'..kind)
  if outcome then assert(result==(outcome=='success' or outcome=='consume'),'inconsistent-combat-use-result:'..kind) end
  assert(self.bound and self.host:authorize(self.bound)==true,'combat-ownership-lost-after-action')
  return result,outcome or (result and 'success' or 'pass')
end
function M:_action_id()
  self.serial=self.serial+1;assert(self.serial<2^53,'action-sequence-exhausted')
  return tostring(self.bound.epoch)..':'..tostring(self.serial)
end
function M:_animate(now,hand) self.swing_start=now;self.swing_hand=hand or 'main' end
function M:_pearl(now,c,hand)
  if now<self.next_pearl or ((c.item_cooldowns or {})['pbzmc:ender_pearl'] or 0)>0 then return false,'pass' end
  local accepted,outcome=self:_call('use',{kind='pearl',hand=hand,action_id=self:_action_id(),now=now})
  if accepted then self.next_pearl=now+require('rules.ender_pearl').cooldown/20 end
  return accepted,outcome
end
function M:_raising(c)
  return self.using and self.using.kind=='shield' and (c.shield_cooldown or 0)<=0 or false
end
function M:_guard_combat()
  return self.bound and require('rules.shield_combat').weapon(self.bound.main,self.bound.offhand)
end
function M:_guard_attack_running(now)
  return self.target_swing_until and now<self.target_swing_until
    or self:_guard_combat()=='sword' and self.swing_start and now-self.swing_start<rules.swing_seconds
end
function M:_attack_target(now)
  -- Optional entity targets own their cadence. Consume throttled attempts too,
  -- so a held attack cannot mine or damage something behind the targeted boat.
  if not self.host.handlers.attack_target then return false end
  if self.attack_target_checked==self.frame_serial then return self.attack_target_consumed end
  self.attack_target_checked=self.frame_serial
  local profile=actions.get(id(self.bound.main)).combat
  local action_id=self:_action_id()
  local consumed,outcome=self:_call('attack_target',{now=now,action_id=action_id,
    strength=rules.strength(now-self.previous_attack,profile.attack_speed)})
  self.attack_target_consumed=consumed
  if consumed then
    self.using=nil;self.breaking_block=false
    if outcome=='success' then
      self.attack_id=action_id;self.previous_attack=now;self:_animate(now)
      self.target_swing_until=now+rules.swing_seconds
    end
  end
  return consumed
end
function M:_attack(now,c)
  if c.flight_use_only then return end
  if self:_attack_target(now) then return end
  local profile=actions.get(id(self.bound.main)).combat
  -- User override: held RMB remains a defence intent. A sword attack can
  -- interrupt its shield; the end of the real swing resumes it automatically.
  local guarded=self:_guard_combat()
  if guarded=='bow' and self.bound.mode=='adventure' and c.has_arrow~=true then return end
  if guarded and self.using and self.using.kind=='shield' then self.using=nil end
  if guarded=='bow' and not self.using then
    self:_start_use('bow','main',now);self.using.release_button='attack';return
  end
  -- MinecraftClient.handleInputEvents discards attack presses while an item
  -- is in use, regardless of shield warm-up/cooldown or which hand is using it.
  -- Spears are a later-version/upstream special attack and retain their jab
  -- cancellation contract; the 1.21.1 shield/input rule does not redefine it.
  if self.using and self.using.kind~='spear' or profile.kind=='trident' and c.trident_out then return end
  self.attack_id=self:_action_id()
  if profile.kind=='spear' then
    if rules.strength(now-self.previous_attack,profile.attack_speed)<1 then return end
    self.previous_attack=now;self.last_jab=now;self.using=nil;self.spear_release=nil;self:_animate(now)
    self:_call('spear_jab',{strength=1,now=now});return
  end
  if profile.kind=='mace' and now-self.previous_attack<rules.minimum_attack_interval then return end
  if profile.kind~='mace' and self:_call('deflect',{now=now}) then self:_animate(now);return end
  self.breaking_block=self:_call('mine',{held=true,dt=0,now=now})
  if self.breaking_block then self:_animate(now);return end
  if now-self.previous_attack<rules.minimum_attack_interval then return end
  local strength=rules.strength(now-self.previous_attack,profile.attack_speed)
  self.previous_attack=now;self:_animate(now)
  -- The host performs target queries, LOS, hits and mode-specific damage using
  -- this frozen equipment snapshot; animation never dispatches a second hit.
  self:_call(profile.kind=='mace' and 'mace' or 'melee',{strength=strength,now=now})
end
function M:_start_use(kind,hand,now)
  self.spear_release=nil
  self.using={kind=kind,hand=hand,started=now,action_id=self:_action_id(),next_eat=0}
end
function M:_use(now,c,released,repeated,inherited_guard)
  if released then
    local use=self.using;self.using=nil
    if not use then return end
    if use.kind=='spear' then
      -- Release is immediate for damage; only the hand blends back to idle.
      self.spear_release={time=now,charge=math.max(0,now-use.started)}
    end
    local elapsed=math.max(0,now-use.started)
    if use.kind=='bow' then
      local seconds=float(math.min(1,elapsed))
      local power=math.min(1,float(float(float(seconds*seconds)+float(seconds*2))/3))
      if power>=float(.1) then self:_call('use',{kind='bow',hand=use.hand,power=power,action_id=use.action_id,now=now}) end
    elseif use.kind=='trident' and elapsed>=.5 then
      self:_call('use',{kind='trident',hand=use.hand,action_id=use.action_id,now=now});self:_animate(now)
    end
    return
  end
  -- Vanilla doItemUse refuses while destroying a block. Its four-tick delay
  -- limits held repeats, not fresh right-button presses.
  if self.using or self.breaking_block or self:_guard_attack_running(now) then return end
  if repeated and self.last_entity_use and now-self.last_entity_use<.2-1e-8 then return end
  if repeated and not self:_guard_combat() and now-self.last_use<.2-1e-8 then return end
  self.last_use=now
  -- Entity interaction is resolved before either hand starts using an item.
  -- A full boat consumes the interaction without falling through to a shield,
  -- projectile, food or block placement.
  if not c.sneaking then
    local accepted,outcome=self:_call('interact',{action_id=self:_action_id(),now=now})
    if accepted then
      self.last_entity_use=now
      if outcome=='success' then self:_animate(now) end;return
    end
    if outcome=='fail' then return end
  end
  -- An offhand rocket remains a usable flight control even when the selected
  -- main item has a ground-only use (a block, boat or native weapon reference).
  if c.gliding and id(self.bound.main)~='pbzmc:firework_rocket' and id(self.bound.offhand)=='pbzmc:firework_rocket' then
    local accepted,outcome=self:_call('use',{kind='instant',hand='offhand',action_id=self:_action_id(),now=now})
    if accepted then self:_animate(now,'offhand') end
    if accepted or outcome=='fail' then return end
  end
  local guarded=self:_guard_combat()
  -- A fresh RMB on bow+shield uses the bow. Only an already-held defence
  -- intent (including sword -> bow) resumes the shield after an LMB shot.
  if guarded and (guarded~='bow' or repeated or inherited_guard) then self:_start_use('shield','offhand',now);return end
  local category=actions.get(id(self.bound.main));local kind=category.use
  if self.bound.mode=='adventure' then
    if kind=='growth' then
      self:_call('growth',{action_id=self:_action_id(),now=now});self:_animate(now);return
    elseif kind=='bottle' then
      if (c.bottle_charges or 0)>0 then self:_start_use(kind,'main',now) end;return
    end
  end
  if kind=='trident' and self:_call('recall_trident',{action_id=self:_action_id(),now=now}) then return end
  if category.tool_use then
    local accepted,outcome=self:_call('tool_use',{action_id=self:_action_id(),now=now})
    if accepted then if outcome=='success' then self:_animate(now) end;return end
    if outcome=='fail' then return end
  end
  if kind=='spear' then self:_start_use(kind,'main',now);return end
  local off_wind=id(self.bound.offhand)=='pbzmc:wind_charge' and category.offhand_wind
  if kind=='wind' or off_wind then
    local wind=require('rules.wind_charge')
    if now<self.next_wind or ((c.item_cooldowns or {})[wind.id] or 0)>0 then return end
    local hand=kind=='wind' and 'main' or 'offhand'
    local thrown=self:_call('use',{kind='wind',hand=hand,action_id=self:_action_id(),now=now})
    if thrown then self.next_wind=now+wind.cooldown_ticks/20;self:_animate(now,hand) end
    return
  end
  if kind=='shield' or kind=='drink' or kind=='food' and ((c.item_cooldowns or {})[id(self.bound.main)] or 0)<=0 or kind=='trident'
    or kind=='bow' and (self.bound.mode~='adventure' or c.has_arrow==true) then
    self:_start_use(kind,'main',now);return
  end
  if kind=='instant' or kind=='pearl' or kind=='equipment' or kind=='summon' or kind=='potion_throw' then
    do
      local accepted,outcome
      if kind=='pearl' then accepted,outcome=self:_pearl(now,c,'main')
      else accepted,outcome=self:_call('use',{kind=kind,hand='main',action_id=self:_action_id(),now=now}) end
      if accepted then if outcome=='success' then self:_animate(now) end;return end
      if outcome=='fail' then return end
    end
    -- MinecraftClient.doItemUse: only PASS proceeds to the offhand. A rejected
    -- BlockItem placement returns FAIL and ends this use without raising it.
  end
  local off_id=id(self.bound.offhand)
  if actions.get(off_id).use=='equipment' then
    local accepted,outcome=self:_call('use',{kind='equipment',hand='offhand',action_id=self:_action_id(),now=now})
    if accepted and outcome=='success'then self:_animate(now)end
    if accepted or outcome=='fail'then return end
  end
  local off_kind=actions.get(off_id).use
  if off_kind=='summon' or off_kind=='potion_throw' or off_id=='pbzmc:firework_rocket' then
    local accepted,outcome=self:_call('use',{kind=off_kind,hand='offhand',action_id=self:_action_id(),now=now})
    if accepted and outcome=='success' then self:_animate(now,'offhand') end
    if accepted or outcome=='fail' then return end
  end
  if off_id=='pbzmc:ender_pearl' then
    local accepted=self:_pearl(now,c,'offhand');if accepted then self:_animate(now) end;return
  end
  if off_kind=='drink' or off_kind=='food' and ((c.item_cooldowns or {})[off_id] or 0)<=0 then
    self:_start_use(off_kind,'offhand',now);return
  end
  if off_id=='pbzmc:shield' then self:_start_use('shield','offhand',now) end
end
function M:_update(now,c,dt)
  if c.flight_use_only then
    if self.use_down then self:_use(now,c,false,true) end
    return
  end
  local category=actions.get(id(self.bound.main));local profile=category.combat
  local targeted=self.attack_down and self:_attack_target(now) or false
  local mining=not targeted and self.attack_down and not self.using and profile.kind~='spear' or false
  self.breaking_block=self:_call('mine',{held=mining,dt=dt,now=now})
  if self.breaking_block and now-self.last_mining_swing>=.3 then
    self:_animate(now);self.last_mining_swing=now
  end
  local use=self.using
  -- User building override: after an out-of-reach PASS raises the offhand
  -- shield, held RMB must still retry the main-hand block at the normal rate.
  -- Preserve the existing defence intent through this instantaneous action.
  if self.use_down and use and use.kind=='shield' and use.hand=='offhand' and category.placeable
    and not self.attack_down and now-self.last_use>=.2 then
    self.using=nil;self:_use(now,c,false,true)
    if not self.using then self.using=use end
    use=self.using
  end
  -- Vanilla retries held use every four ticks whenever no item is in use.
  -- This includes raising a shield once block mining stops while RMB stays down.
  if self.use_down and not use and profile.kind~='spear' then
    self:_use(now,c,false,true)
  end
  if not use then return end
  local elapsed=math.max(0,now-use.started)
  if use.kind=='spear' then
    local tick=rules.spear_tick(now)
    if tick~=use.last_tick and rules.spear_tick(elapsed)>=rules.spear_tick(profile.spear.delay) then
      use.last_tick=tick
      self:_call('spear_charge',{elapsed=elapsed,action_id=use.action_id,now=now})
    end
  elseif use.kind=='food' or use.kind=='drink' then
    if elapsed>=.35 and now>=use.next_eat then
      use.next_eat=now+.2;self:_call('eat_feedback',{kind=use.kind,count=5,hand=use.hand,action_id=use.action_id,now=now})
    end
    if elapsed>=1.6 then
      self.using=nil
      -- One adapter transaction owns consumption and healing; no local decrement.
      self:_call('consume',{kind=use.kind,hand=use.hand,action_id=use.action_id,now=now})
    end
  elseif use.kind=='bottle' and elapsed>=1.6 then
    self.using=nil;self:_call('consume',{kind='bottle',hand=use.hand,action_id=use.action_id,now=now})
  end
end
local event_bits={attack_press=1,attack_release=2,use_press=4,use_release=8}
function M:_step(now,c,events)
  assert(finite(now) and now>=0 and (not self.last_time or now>=self.last_time),'invalid-action-clock')
  local dt=math.min(.1,math.max(0,now-(self.last_time or now)));self.last_time=now
  self.frame_serial=(self.frame_serial or 0)+1
  assert(type(c)=='table' and type(events)=='table','invalid-action-frame')
  if c.kind~='game' or c.weapon_group~='mc' or c.allow_actions~=true then self:_cancel('context-unavailable');return end
  local next_stamp=source(c)
  local sequence_scope=tostring(c.epoch)..'/'..tostring(c.input_epoch)
  if self.sequence_scope~=sequence_scope then
    self.sequence_scope=sequence_scope;self.last_seq=-1;self.seen={}
  end
  if self.stamp~=next_stamp then
    self:_cancel('owner-or-equipment-changed');self.bound=snapshot(c);self.stamp=next_stamp
  else
    -- A caller must advance its revision for any equipment or mode change.
    assert(stacks.compatible(self.bound.main,c.main) or self.bound.main==nil and c.main==nil,'unstamped-main-change')
    assert(stacks.compatible(self.bound.offhand,c.offhand) or self.bound.offhand==nil and c.offhand==nil,'unstamped-offhand-change')
    assert(self.bound.mode==c.mode,'unstamped-mode-change')
  end
  assert(self.host:authorize(self.bound)==true,'combat-ownership-unavailable')
  local previous=-1
  local pending={}
  for _,event in ipairs(events) do
    if event.kind~='cancel_actions' then
      assert(event_bits[event.kind] and integer(event.seq) and event.seq>=previous,'invalid-action-event')
      assert(event.source==self.stamp and event.owner_epoch==c.epoch and event.input_epoch==c.input_epoch
        and event.equipment_revision==c.equipment_revision,'stale-action-event')
      previous=event.seq
    end
  end
  for _,event in ipairs(events) do
    if event.kind=='cancel_actions' then
      if event.source==self.stamp then self:_cancel(event.reason or 'input-cancelled');return end
    elseif event.seq>=self.last_seq then
      if event.seq>self.last_seq then self.seen={};self.last_seq=event.seq end
      if not self.seen[event.kind] then
        self.seen[event.kind]=true -- Reserve before a handler; an uncertain side effect is never retried.
        pending[#pending+1]=event
      end
    end
  end
  -- MinecraftClient.handleInputEvents drains attack presses before use presses.
  -- Keep message order within each button, and reserve the whole batch first.
  for _,button in ipairs({'attack','use'}) do
    for _,event in ipairs(pending) do
      if event.kind:sub(1,#button)==button then
        if event.kind=='attack_press' then
          if not self.attack_down then self.attack_down=true;self:_attack(now,c) end
        elseif event.kind=='attack_release' then
          self.attack_down=false
          if self.using and self.using.release_button=='attack' then self:_use(now,c,true) end
        elseif event.kind=='use_press' then
          if not self.use_down then self.use_down=true;self:_use(now,c,false,false,event.inherited_guard) end
        elseif event.kind=='use_release' then
          if self.use_down then
            self.use_down=false
            if not self.using or self.using.release_button~='attack' then self:_use(now,c,true) end
          end
        end
      end
    end
  end
  self:_update(now,c,dt)
end
function M:step(now,context,events)
  if self.fault then return false,self.fault end
  local ok,why=pcall(self._step,self,now,context,events or {})
  if not ok then
    self.fault=tostring(why);self:cancel('action-fault');return false,self.fault
  end
  return true
end
function M:presentation(now,context)
  if self.fault or not self.bound then return nil end
  if type(context)~='table' or context.kind~='game' or context.weapon_group~='mc' or context.allow_actions~=true
    or source(context)~=self.stamp or self.host:authorize(self.bound)~=true then return nil end
  assert(finite(now) and now>=self.last_time,'invalid-presentation-clock')
  local use=self.using;local elapsed=use and math.max(0,now-use.started) or 0
  local swing=self.swing_start and (now-self.swing_start)/rules.swing_seconds or 0
  local raising=self:_raising(context or {})
  local profile=actions.get(id(self.bound.main)).combat
  local recover=self.spear_release
  local w=recover and math.max(0,1-(now-recover.time)/.15) or 0
  if recover and w==0 then self.spear_release=nil end
  return {group='mc',main=stacks.copy(self.bound.main),offhand=stacks.copy(self.bound.offhand),
    swing=swing<1 and swing or 0,swing_hand=swing<1 and self.swing_hand or nil,blocking=raising,
    -- PBZ requirement: no activation delay, including the first input frame.
    shield_active=raising,use_hand=use and use.hand,
    bow_charge=use and use.kind=='bow' and math.min(1,elapsed) or 0,
    bow_ticks=use and use.kind=='bow' and elapsed*20 or 0,
    trident_charge=use and use.kind=='trident' and math.min(1,elapsed*2) or 0,trident_out=context.trident_out==true,
    eating=use and (use.kind=='food' or use.kind=='bottle' or use.kind=='drink') and math.min(1,elapsed/1.6) or 0,
    spear_charge=use and use.kind=='spear' and math.max(.001,elapsed) or 0,
    spear_recover_charge=w>0 and recover.charge or 0,spear_recover_weight=w*w*(3-2*w),
    spear_jab=profile.kind=='spear' and now-self.last_jab<profile.spear.jab
      and math.max(.00001,(now-self.last_jab)/profile.spear.jab) or 0,
    spear_recoil=math.min(10,(now-self.last_spear_impact)*20),
    attack_charge=rules.strength(now-self.previous_attack,profile.attack_speed),
    source=self.stamp,equipment_revision=self.bound.equipment_revision}
end
function M:record_spear_contact(stamp,action_id,now)
  if self.fault or not self.bound or stamp~=self.stamp or now~=self.last_time
    or actions.get(id(self.bound.main)).combat.kind~='spear' then return false end
  local active=self.using and self.using.kind=='spear' and self.using.action_id or self.attack_id
  if not active or action_id~=active or self.host:authorize(self.bound)~=true then return false end
  self.last_spear_impact=now;return true -- Visual feedback only; never dispatch damage here.
end
return M
