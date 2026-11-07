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
local block_size=require('rules.build_grid').size
local min_damage_speed,min_knockback_speed=f32(4.6),f32(5.1)
local function game_tick(seconds) return math.floor(number(seconds)*20+1e-8) end
local function charge_window(spear,seconds,duration)
  local elapsed=game_tick(seconds)-game_tick(spear.delay)
  return elapsed>=0 and elapsed<=game_tick(duration)
end
function M.spear_speed(velocity,direction)
  return (velocity.X*direction.X+velocity.Y*direction.Y+velocity.Z*direction.Z)/block_size
end
function M.charge_damage(spear,attacker_speed,target_speed,seconds)
  local relative=math.max(0,number(attacker_speed)-number(target_speed))
  if attacker_speed>=0 and relative>=min_damage_speed and game_tick(seconds)>=game_tick(spear.delay) then
    -- Bedrock-style held charge: reevaluate the relative velocity throughout
    -- the hold. The jab uses the equipped attack attribute instead.
    return 1+math.floor(relative*spear.multiplier)
  end
  return 0
end
function M.charge_knockback(spear,speed,seconds)
  return number(speed)>=min_knockback_speed and charge_window(spear,seconds,spear.knockback)
end
function M.charge_dismount(spear,speed,seconds)
  return number(speed)>=spear.min_dismount and charge_window(spear,seconds,spear.dismount)
end
function M.armor_multiplier(reduction,breach)
  reduction=math.max(0,math.min(.8,number(reduction)));breach=number(breach)
  return (1-reduction*(1-.15*breach))/(1-reduction)
end

M.spear_tick=game_tick
return M
