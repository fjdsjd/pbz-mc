-- Pure combat rules ported from the pinned wukong-steve 0.11.0 source.
-- Copyright (c) 2026 桃天帝不差. PolyForm Noncommercial 1.0.0.
-- Retain third_party/wukong-steve/LICENSE and NOTICE with distributions.
-- No global PBZ attack/defence ratios: host damage attribution is a separate adapter.
local M={swing_seconds=.3,minimum_attack_interval=.05}
local function number(value)
  assert(type(value)=='number' and value==value and value~=math.huge and value~=-math.huge,'invalid-combat-number')
  return value
end
local function f32(value)
  local result=string.unpack('<f',string.pack('<f',value));return result
end
function M.strength(elapsed,attack_speed)
  elapsed=number(elapsed);attack_speed=number(attack_speed or 1.6)
  assert(attack_speed>0,'invalid-attack-speed')
  local ticks=math.floor(math.max(0,elapsed)*20+1e-8)
  return math.min(1,(ticks+.5)/(20/attack_speed))
end
function M.damage_multiplier(strength)
  strength=number(strength);assert(strength>=0 and strength<=1,'invalid-attack-strength')
  return f32(.2+.8*strength*strength)
end
function M.reinforcement(level)
  return 1+.04*math.max(0,math.min(15,number(level)))
end
function M.critical(strength,vertical_speed,sprint_down)
  return number(strength)>.9 and number(vertical_speed)<-50 and not sprint_down
end
function M.sprinting(grounded,sprint_down,speed)
  return grounded and sprint_down and number(speed)>50 or false
end
function M.can_sweep(profile,damaged,strength,critical,grounded,sprinting,speed)
  return damaged and profile.can_sweep==true and number(strength)>.9 and not critical
    and grounded and not sprinting and number(speed)<431.8 or false
end
function M.melee_damage(base_damage,strength,critical)
  -- Match SwordCombat's float operands and multiplication order for ordinary melee.
  return f32(f32(f32(number(base_damage))*M.damage_multiplier(strength))*(critical and 1.5 or 1))
end
function M.smash_bonus(distance,density)
  distance=number(distance);density=number(density)
  if distance<=1.5 then return 0 end
  return math.min(distance,3)*4+math.min(math.max(0,distance-3),5)*2
    +math.max(0,distance-8)+distance*.5*density
end
function M.wind_multiplier(level)
  level=number(level);return level<=1 and 1.2 or level==2 and 1.75 or 2.2
end
function M.charge_damage(spear,attacker_speed,target_speed,seconds)
  local relative=math.max(0,number(attacker_speed)-number(target_speed))
  local active=number(seconds)-spear.delay
  if active>=0 and active<spear.damage_seconds and relative>=4.6 then
    return spear.base_damage+math.floor(relative*spear.multiplier)
  end
  return 0
end
function M.charge_knockback(spear,speed,seconds)
  return number(seconds)>=spear.delay and seconds<spear.delay+spear.knockback and number(speed)>=5.1
end
function M.charge_dismount(spear,speed,seconds)
  return number(seconds)>=spear.delay and seconds<spear.delay+spear.dismount and number(speed)>=spear.min_dismount
end
function M.armor_multiplier(reduction,breach)
  reduction=math.max(0,math.min(.8,number(reduction)));breach=number(breach)
  return (1-reduction*(1-.15*breach))/(1-reduction)
end

-- A successful spear contact requires separation AND the ten-tick interval.
-- Targets are caller-owned entity identities; this object has no native handles.
function M.contacts()
  local state={last={},previous={},current={}}
  function state:begin() self.current={} end
  function state:touch(target,now)
    assert(target~=nil,'missing-contact-target');now=number(now)
    self.current[target]=true
    return not self.previous[target] and not (self.last[target] and now-self.last[target]<.5)
  end
  function state:hit(target,now)
    assert(target~=nil,'missing-contact-target');self.last[target]=number(now);self.previous[target]=true
  end
  function state:finish()
    for target in pairs(self.previous) do if not self.current[target] then self.previous[target]=nil end end
    local count=0;for _ in pairs(self.last) do count=count+1 end
    if count>256 then self.last={} end -- Preserve the baseline's bounded history policy.
  end
  function state:clear() self.last={};self.previous={};self.current={} end
  return state
end
return M
