-- MC 1.21.1 FoodComponents, StatusEffectInstance and RegenerationStatusEffect.
-- PBZ health is normalized to twenty MC units; no hunger or durability state.
local state=require('storage.state')
local M={}
local definitions=require('content.potion_reference').effects
M.definitions=definitions
M.max_air=300
local turtle_duration=200
M.cooldown_ticks={['pbzmc:golden_apple']=200,['pbzmc:enchanted_golden_apple']=600,['pbzmc:totem_of_undying']=1200,
 ['pbzmc:ender_pearl']=require('rules.ender_pearl').cooldown,
 ['pbzmc:chorus_fruit']=require('rules.chorus_fruit').cooldown_ticks,
 ['pbzmc:wind_charge']=require('rules.wind_charge').cooldown_ticks}
function M.empty()return {schema=1,effects={},absorption=0,totem_cooldown=0,cooldowns={},serial=0}end
function M.remaining(s,id)
 if id=='pbzmc:totem_of_undying' then return s.totem_cooldown or 0 end
 return s.cooldowns and s.cooldowns[id] or 0
end
function M.cooling(s)
 if s.totem_cooldown>0 then return true end
 for _,ticks in pairs(s.cooldowns or {}) do if ticks>0 then return true end end
 return false
end
function M.start_cooldown(previous,id)
 assert(M.cooldown_ticks[id] and id~='pbzmc:totem_of_undying','unsupported-item-cooldown')
 assert(M.remaining(previous,id)==0,'item-cooldown')
 local s=state.clone(previous);s.cooldowns=s.cooldowns or {};s.cooldowns[id]=M.cooldown_ticks[id]
 s.serial=s.serial+1;return s
end
function M.validate(s)
 assert(type(s)=='table' and s.schema==1 and type(s.effects)=='table','invalid-status-state')
 assert(s.air==nil or type(s.air)=='number' and s.air%1==0 and s.air>=-19 and s.air<=M.max_air,'invalid-air-supply')
 for _,key in ipairs({'absorption','totem_cooldown','serial'}) do
  assert(type(s[key])=='number' and s[key]==s[key] and s[key]>=0 and s[key]<1e12,'invalid-status-'..key)
 end
 local function effect(e,depth)
  assert(depth<8 and type(e.ticks)=='number' and e.ticks%1==0 and e.ticks>0 and e.ticks<=2147483647,'invalid-effect-time')
  assert(type(e.amplifier)=='number' and e.amplifier%1==0 and e.amplifier>=0 and e.amplifier<=255,'invalid-effect-level')
  if e.heal~=nil then assert(type(e.heal)=='number' and e.heal>0 and e.heal<1e9,'invalid-effect-healing') end
  if e.hidden then effect(e.hidden,depth+1) end
 end
 for id,e in pairs(s.effects) do assert(definitions[id],'unknown-status-effect');effect(e,0) end
 for id,ticks in pairs(s.cooldowns or {}) do
  assert(M.cooldown_ticks[id] and id~='pbzmc:totem_of_undying' and type(ticks)=='number' and ticks%1==0 and ticks>=0 and ticks<=M.cooldown_ticks[id],'invalid-item-cooldown')
 end
 return true
end
-- Stronger short effects retain a weaker, longer one beneath them. Time runs
-- for both; applying a weaker apple never downgrades enchanted absorption.
local function merge(old,next,depth)
 depth=depth or 0
 if not old then return state.clone(next),true end
 local changed=false
 if next.amplifier>old.amplifier then
  local result=state.clone(next)
  if next.ticks<old.ticks then result.hidden=old else result.hidden=old.hidden end
  return result,true
 elseif next.amplifier==old.amplifier then
  if next.ticks>old.ticks then old.ticks=next.ticks;changed=true end
 elseif next.ticks>old.ticks and depth<6 then old.hidden=merge(old.hidden,next,depth+1) end
 old.hide=next.hide
 return old,changed
end
function M.add(s,id,ticks,amplifier,max_hp,capacity,hide)
 assert(definitions[id],'unknown-status-effect:'..tostring(id))
 local old=s.effects[id];local e,changed=merge(old,{ticks=ticks,amplifier=amplifier,hide=hide==true})
 s.effects[id]=e
 local tail=e
 for _=1,6 do if not tail.hidden then break end;tail=tail.hidden end
 tail.hidden=nil
 if id=='absorption' and changed then
  s.absorption=math.max(s.absorption,capacity or max_hp*.2*(amplifier+1))
 end
end
function M.apple(previous,id,max_hp)
 assert(id=='pbzmc:golden_apple' or id=='pbzmc:enchanted_golden_apple','not-golden-apple')
 assert(M.remaining(previous,id)==0,'apple-cooldown')
 local s=state.clone(previous);local enchanted=id=='pbzmc:enchanted_golden_apple'
 M.add(s,'regeneration',enchanted and 400 or 100,1,max_hp)
 M.add(s,'absorption',2400,enchanted and 3 or 0,max_hp)
 if enchanted then M.add(s,'resistance',6000,0,max_hp);M.add(s,'fire_resistance',6000,0,max_hp) end
 s.cooldowns=s.cooldowns or {};s.cooldowns[id]=M.cooldown_ticks[id]
 s.serial=s.serial+1;return s
end
function M.totem(previous,max_hp,mode)
 assert(previous.totem_cooldown<=0,'totem-cooldown')
 local s=state.clone(previous);s.effects={};s.absorption=0
 -- Explicit PBZ project rule: 60 s, 45 s regeneration, 40 s fire resistance.
 local unit=mode=='adventure' and 15 or max_hp/20
 M.add(s,'regeneration',900,1,max_hp);s.effects.regeneration.heal=unit
 M.add(s,'absorption',100,1,max_hp,mode=='adventure' and 120 or max_hp*.4)
 M.add(s,'fire_resistance',800,0,max_hp)
 s.totem_cooldown=1200;s.serial=s.serial+1
 return s,math.min(max_hp,unit)
end
local function decrement(e)
 if e.hidden then e.hidden=decrement(e.hidden) end
 if e.ticks~=2147483647 then e.ticks=e.ticks-1 end
 if e.ticks<=0 then return e.hidden end
 return e
end
-- A charged helmet on land is a steady state. Avoid cloning the profile or
-- marking it dirty twenty times a second just to renew the same ten seconds.
function M.needs_tick(s,submerged,helmet,creative)
 if s.air~=nil or submerged and not creative or M.cooling(s) then return true end
 local charging=helmet and submerged==false
 for id,e in pairs(s.effects) do
  if id~='water_breathing' or not charging or e.ticks~=turtle_duration or e.amplifier~=0 or e.hidden then return true end
 end
 return charging and not s.effects.water_breathing
end
function M.advance(previous,ticks,max_hp,submerged,helmet,creative)
 local s=state.clone(previous);local healing,drowning=0,0;local pulses={poison=0,wither=0}
 assert(ticks>=0 and ticks%1==0 and ticks<=100,'invalid-status-step')
 for _=1,ticks do
  -- Vanilla checks air before ticking effect durations. The last protected
  -- tick still preserves the remaining air. Omitted air means a full supply
  -- in both old and new savepoints.
  if submerged and not creative and not s.effects.water_breathing then
   s.air=(s.air or M.max_air)-1
   if s.air<=-20 then s.air=0;drowning=drowning+1 end
  elseif submerged==false and s.air then
   s.air=s.air+4;if s.air>=M.max_air then s.air=nil end
  end
  local regen=s.effects.regeneration
  if regen and regen.ticks%math.max(1,50>>math.min(30,regen.amplifier))==0 then healing=healing+(regen.heal or max_hp/20) end
  for id,interval in pairs({poison=25,wither=40})do
   local e=s.effects[id]
   if e and e.ticks%math.max(1,interval>>math.min(30,e.amplifier))==0 then pulses[id]=pulses[id]+1 end
  end
  local prior=s.effects.absorption
  for id,e in pairs(s.effects) do s.effects[id]=decrement(e) end
  if helmet and submerged==false then
   local e=s.effects.water_breathing
   if not e then s.effects.water_breathing={ticks=turtle_duration,amplifier=0,hide=true}
   elseif e.amplifier==0 then e.ticks=math.max(turtle_duration,e.ticks)
   else M.add(s,'water_breathing',turtle_duration,0,max_hp,nil,true) end
  end
  local current=s.effects.absorption
  if prior and not current then s.absorption=0
  elseif current and prior.amplifier~=current.amplifier then
   s.absorption=math.min(s.absorption,max_hp*.2*(current.amplifier+1))
  end
  s.totem_cooldown=math.max(0,s.totem_cooldown-1)
  for id,remaining in pairs(s.cooldowns or {}) do s.cooldowns[id]=remaining>1 and remaining-1 or nil end
 end
 return s,healing,drowning,pulses
end
function M.level(s,id)local e=s and s.effects and s.effects[id];return e and e.amplifier+1 or 0 end
function M.speed(s)
 return math.max(0,(1+.2*M.level(s,'speed'))*(1-.15*M.level(s,'slowness')))
end
function M.attack_bonus(s)return 3*M.level(s,'strength')-4*M.level(s,'weakness')end
function M.mining(s)
 local n=M.level(s,'mining_fatigue')
 local fatigue=({.3,.09,.0027,.00081})[math.min(4,n)]or 1
 return (1+.2*M.level(s,'haste'))*fatigue
end
function M.damage(previous,amount,is_fire,bypass_resistance)
 assert(type(amount)=='number' and amount>0 and amount<1e9,'invalid-status-damage')
 local s=state.clone(previous)
 if is_fire and s.effects.fire_resistance then return s,0,0 end
 if s.effects.resistance and not bypass_resistance then amount=amount*math.max(0,1-.2*(s.effects.resistance.amplifier+1)) end
 local absorbed=math.min(s.absorption,amount);s.absorption=s.absorption-absorbed
 return s,amount-absorbed,absorbed
end
function M.has_particles(s)
 for id,e in pairs(s.effects) do if not e.hide and definitions[id].particles~=false then return true end end
 return false
end
function M.list(s,particles_only)
 local out={}
 for id,e in pairs(s.effects) do
  local def=definitions[id]
  if not particles_only or not e.hide and def.particles~=false then out[#out+1]={id=id,name=def.name,amplifier=e.amplifier,ticks=e.ticks,color=def.color} end
 end
 table.sort(out,function(a,b)return a.color<b.color end) -- StatusEffectInstance ordering, all beneficial/non-ambient.
 return out
end
function M.particle_color(s)
 -- Uniform reservoir choice; emission doesn't need sorted UI records.
 local count,color=0,nil
 for id,e in pairs(s.effects)do
  if not e.hide and definitions[id].particles~=false then
   count=count+1;if math.random(count)==1 then color=definitions[id].color end
  end
 end
 return color
end
return M
