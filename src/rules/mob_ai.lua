-- Goal parameters from the pinned Bedrock behavior files; host movement and
-- damage are adapters. Owner allegiance is the intentional PBZ mod override.
local references=require('content.mob_behavior_reference')
local M={}
local cache={}
function M.profile(name)
  if cache[name] then return cache[name] end
  local row=assert(references[name],'mob-behavior-reference:'..name)
  local groups=assert(row.groups,'mob-behavior-groups:'..name)
  local merged={};for k,v in pairs(groups.base or {})do merged[k]=v end
  local keys={};for k in pairs(groups)do if k~='base' then keys[#keys+1]=k end end;table.sort(keys)
  for _,k in ipairs(keys) do
    if not k:find('baby') and not k:find('hard') and not k:find('small') and not k:find('medium') then
      for key,value in pairs(groups[k])do if not merged[key] then merged[key]=value end end
    end
  end
  if name=='wolf' then
    merged.health=groups['minecraft:wolf_increased_max_health'].health
    merged.attack=groups['minecraft:wolf_tame'].attack
  end
  local h=merged.health or {};local health=h.max or h.value
  if type(health)=='table' then health=health.range_max or health.max end
  local melee=merged['behavior.melee_box_attack'] or merged['behavior.melee_attack'] or {}
  local ranged=merged['behavior.ranged_attack']
  local p={health=type(health)=='number' and health or 20,melee=melee,ranged=ranged,stationary=name=='shulker',
    delayed=merged['behavior.delayed_attack'],leap=merged['behavior.leap_at_target'],
    swoop=merged['behavior.swoop_attack'],charge=merged['behavior.charge_attack'],
    sonic=merged['behavior.sonic_boom'],guardian=merged['behavior.guardian_attack'],
    slime=merged['behavior.slime_attack'],ram=merged['behavior.ram_attack']}
  local damage=merged.attack and merged.attack.damage
  if type(damage)=='number' then p.damage=damage
  elseif type(damage)=='table' then p.damage=damage.range_min or damage.min end
  local goal=merged['behavior.nearest_attackable_target'] or {}
  p.forget=goal.must_see_forget_duration or 3
  if ranged then
    local r=ranged.attack_range or {};local interval=ranged.attack_interval or {}
    if type(r)=='number'then r={max=r}end
    if type(interval)=='number'then interval={min=interval,max=interval}end
    p.range=(r.max or ranged.attack_radius or 15)*100;p.minimum=(r.min or ranged.attack_radius_min or 0)*100
    p.interval_min=interval.min or ranged.attack_interval_min or 1
    p.interval_max=interval.max or ranged.attack_interval_max or p.interval_min
    p.windup=(ranged.charge_shoot_trigger or 0)*2
    p.see_time=ranged.target_in_sight_time or 1
    p.follow_target=ranged.in_range_movement_mode=='follow_target'
    p.burst=ranged.burst_shots or 1;p.burst_interval=ranged.burst_interval or .3
  end
  if p.sonic then p.melee={cooldown_time=.9}end -- WardenAi: MeleeAttack.create(18)
  cache[name]=p;return p
end
-- Warden/SonicBoom (26.3): pursue for 200 ticks on acquiring a target;
-- 34-tick windup, 60-tick action, then a 40-tick cooldown. The wave ignores
-- visibility and uses independent horizontal/vertical range tests.
function M.sonic_kind(m,now,key,horizontal,vertical,reach)
  if m.sonic_target~=key then
    m.sonic_target=key;m.next_sonic=now+10;m.charge_started=nil;m.charging_kind=nil
  end
  if now<(m.sonic_recovery or 0)then return nil end
  if m.charging_kind=='sonic'and m.charge_started then return 'sonic'end
  if horizontal<=reach and vertical<m.def.height/2+110 then return 'melee'end
  if now>=(m.next_sonic or 0)and horizontal<=1500 and vertical<=2000 then return 'sonic'end
end
function M.ready(m,now,key,distance,visible,contact)
  local p=m.ai or M.profile(m.def.name)
  if m.attack_target~=key then
    m.attack_target=key;m.charge_started=nil;m.burst_remaining=nil;m.visible_since=nil
  end
  if not visible then m.charge_started=nil;m.burst_remaining=nil;m.visible_since=nil;return false end
  m.visible_since=m.visible_since or now
  if now<(m.next_attack or 0) then return false end
  if contact then
    local delay=p.delayed
    if delay then
      m.charge_started=m.charge_started or now
      if now-m.charge_started<(delay.attack_duration or 1)*(delay.hit_delay_pct or .5) then return false end
    end
    m.charge_started=nil;m.next_attack=now+(delay and delay.attack_duration or p.melee.cooldown_time or 1)
    if p.sonic then m.next_sonic=now+(p.sonic.attack_cooldown or 2)end
    return true
  end
  if p.ranged and now-m.visible_since<(p.see_time or 1) then return false end
  local windup=p.windup or (p.sonic and 1.7 or p.guardian and 4 or .5)
  m.charge_started=m.charge_started or now
  if now-m.charge_started<windup then return false end
  if p.sonic then
    m.sonic_recovery=m.charge_started+(p.sonic.duration or 3)
    m.next_attack=m.sonic_recovery;m.next_sonic=m.sonic_recovery+(p.sonic.attack_cooldown or 2)
    m.charge_started=nil;return true
  end
  local burst=m.burst_remaining or p.burst or 1
  burst=burst-1
  if burst>0 then m.burst_remaining=burst;m.next_attack=now+(p.burst_interval or .3)
  else
    m.burst_remaining=nil;m.charge_started=nil
    local minimum=p.windup and p.windup>0 and 0 or p.interval_min or m.def.interval
    local maximum=p.windup and p.windup>0 and minimum or p.interval_max or minimum
    m.next_attack=now+math.max(.05,minimum+(maximum-minimum)*math.min(1,distance/math.max(1,p.range or 1500)))
  end
  return true
end

-- Separate flyby and charge phases. A hit, hurt event or horizontal collision
-- ends a swoop; the next pass uses the vanilla goal's 10--20 second delay.
function M.fly_goal(m,now,target,blocked,random)
  local p=m.ai;if not p or not (p.swoop or p.charge) then return target,true end
  random=random or math.random
  local active=m.flight_phase=='attack'
  if active and (blocked or (m.last_hurt or -1)>(m.flight_started or now)
      or (m.last_attack or -1)>=(m.flight_started or now)) then
    m.flight_phase='circle';active=false
    local delay=p.swoop and (p.swoop.delay_range or {min=10,max=20}) or {min=1,max=3}
    m.next_pass=now+(delay.min or 10)+random()*((delay.max or 20)-(delay.min or 10))
  end
  if not m.flight_phase then m.flight_phase='circle';m.next_pass=now+(p.swoop and 10 or 1) end
  if now>=(m.next_pass or 0) then m.flight_phase='attack';m.flight_started=now;m.next_pass=math.huge;active=true end
  if active then return target,true end
  local angle=now*.65+m.serial;local radius=p.swoop and 450 or 180
  return {X=target.X+math.cos(angle)*radius,Y=target.Y+math.sin(angle)*radius,
    Z=target.Z+(p.swoop and 500 or 150)},false
end
return M
