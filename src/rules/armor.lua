-- The four actual equipped slots are authoritative for every weapon group.
-- Host damage classification and callbacks remain in the PBZ adapter.
local definitions=require('content.armor')
local M={}
local function finite(n)return type(n)=='number' and n==n and math.abs(n)<math.huge end
local function nonnegative(n,label)assert(finite(n) and n>=0,'invalid-armor-'..label);return n end
local function part(value)return #value..':'..value end
function M.snapshot(equipped)
  assert(type(equipped)=='table','invalid-armor-slots')
  local result={points=0,toughness=0,knockback_resistance=0,pieces={},count=0,rejected={}}
  local seen,signature={},{}
  for _,slot in ipairs(definitions.slots)do
    local stack=equipped[slot];local definition=type(stack)=='table' and definitions.get(stack.content_id)
    local valid=definition and definition.slot==slot and stack.count==1 and type(stack.instance_id)=='string'
      and #stack.instance_id>0 and not seen[stack.instance_id]
    if valid then
      seen[stack.instance_id]=true
      result.points=result.points+definition.points;result.toughness=result.toughness+definition.toughness
      result.knockback_resistance=result.knockback_resistance+definition.knockback_resistance;result.count=result.count+1
      result.pieces[slot]={content_id=definition.id,instance_id=stack.instance_id,material=definition.material,
        points=definition.points,toughness=definition.toughness,model_layer=definition.model_layer}
      signature[#signature+1]=slot..'='..part(definition.id)..part(stack.instance_id)
    else
      signature[#signature+1]=slot..'=-'
      if stack then result.rejected[#result.rejected+1]=slot end
    end
  end
  result.hud_points=math.max(0,math.min(20,math.ceil(result.points)))
  result.signature=table.concat(signature,'|')
  return result
end
function M.reduce_mc(damage,points,toughness,bypass)
  nonnegative(damage,'damage');nonnegative(points,'points');nonnegative(toughness,'toughness')
  assert(points<=20,'invalid-armor-points')
  assert(bypass==nil or type(bypass)=='boolean','invalid-armor-bypass')
  local effective=0
  if not bypass then effective=math.min(20,math.max(points*.2,points-damage/(2+toughness/4)))end
  local multiplier=1-effective/25
  return damage*multiplier,multiplier,effective
end
function M.reduce(raw_damage,max_health,snapshot,bypass)
  nonnegative(raw_damage,'native-damage')
  assert(finite(max_health) and max_health>0,'invalid-armor-max-health')
  assert(type(snapshot)=='table','invalid-armor-snapshot')
  -- Normalize to the same twenty half-heart units used by the MC health HUD.
  -- The caller supplies already-resolved PBZ damage, not an attack coefficient.
  local damage_mc=raw_damage/max_health*20
  assert(finite(damage_mc),'invalid-armor-normalized-damage')
  local remaining_mc,multiplier,effective=M.reduce_mc(damage_mc,snapshot.points,snapshot.toughness,bypass)
  local remaining=raw_damage*multiplier
  return remaining,{incoming=raw_damage,damage_mc=damage_mc,remaining_mc=remaining_mc,
    points=snapshot.points,toughness=snapshot.toughness,effective_armor=effective,multiplier=multiplier,
    prevented=raw_damage-remaining,bypass=bypass==true}
end
return M
