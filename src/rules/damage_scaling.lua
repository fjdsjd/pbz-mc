-- PBZ extension: swords, tools and bow growth follows target maximum HP. The incoming
-- base amount already contains material, cooldown, critical and draw factors;
-- multiply it once, then let PBZ calculate armor and native shield damage.
local profiles=require('content.combat_profiles')
local M={sword_percentage=.08,bow_percentage=.12,native_coefficient_limit=1000}
local max_number=1.7976931348623157e308
local melee_kinds={sword=true,pickaxe=true,shovel=true,axe=true}
local function positive(value)
  return type(value)=='number' and value==value and value>0 and value<math.huge
end
local function reference(id,multiplier)
  local ok,profile=pcall(profiles.get,id)
  if not ok or not profile or not positive(profile.adventure_attack) then return nil end
  local value=profile.adventure_attack*multiplier
  return positive(value) and value or nil
end
function M.apply(amount,target_max,kind,weapon_id,attack)
  assert(positive(amount),'damage-scaling-base-invalid')
  assert(positive(attack),'damage-scaling-attack-invalid')
  local out={base_requested=amount,target_max=positive(target_max) and target_max or false,
    target_max_valid=positive(target_max) or false,weapon_id=type(weapon_id)=='string' and weapon_id or false,
    scaling_multiplier=1,percentage=0,scaling_reason='unscaled-weapon'}
  local reference_base
  if kind=='arrow' then
    out.percentage=M.bow_percentage;reference_base=reference('pbzmc:bow',1.8)
    if not out.weapon_id then out.weapon_id='pbzmc:bow' end
  elseif kind=='sword' then
    local ok,profile=pcall(profiles.get,weapon_id)
    if ok and profile and melee_kinds[profile.kind] then
      out.percentage=M.sword_percentage;reference_base=reference('pbzmc:diamond_sword',1)
      out.weapon_kind=profile.kind
      if reference_base then out.full_weapon_percentage=M.sword_percentage*profile.adventure_attack/reference_base end
    elseif not ok then out.scaling_reason='weapon-profile-unavailable' end
  end
  if out.percentage>0 then
    out.reference_full_base=reference_base
    if not out.target_max_valid then out.scaling_reason='invalid-target-max'
    elseif not reference_base then out.scaling_reason='reference-profile-unavailable'
    else
      out.scaling_multiplier=math.max(1,target_max*out.percentage/reference_base)
      out.scaling_reason=out.scaling_multiplier>1 and 'target-max-growth' or 'fixed-floor'
    end
  end
  -- Check the ratio before multiplication so huge finite max HP cannot
  -- overflow into infinity and serialize an invalid native request.
  local limit=attack<=max_number/M.native_coefficient_limit and attack*M.native_coefficient_limit or max_number
  out.native_limit=limit
  out.clamped=out.scaling_multiplier>limit/amount
  out.requested=out.clamped and limit or amount*out.scaling_multiplier
  out.coefficient=math.min(M.native_coefficient_limit,out.requested/attack)
  assert(positive(out.requested) and positive(out.coefficient),'damage-scaling-result-invalid')
  return out
end
return M
