-- One identity-checked health entry for spawned MC actors. Weapon, projectile,
-- explosion and command adapters all use the same settlement and death owner.
local ids=require('host.pbz.object_identity')
local valid=require('host.pbz.appearance').valid
local M={}
function M.find(binding,actor)
  local group=binding.mc_summons
  if not group or not valid(actor) then return end
  local m=group.by_actor and group.by_actor[actor:GetAddress()]
  if m and not m.removed and ids.matches(actor,m.id) then return m,group end
end
function M.alive(binding,actor)
  local m=M.find(binding,actor)
  return m~=nil and m.health>0 and not m.invulnerable and actor.bCanBeDamaged~=false
end
function M.hit(binding,actor,amount,action,contact)
  local m,group=M.find(binding,actor)
  if not m or m.health<=0 or m.invulnerable or actor.bCanBeDamaged==false then return false end
  assert(type(amount)=='number' and amount>0 and amount<1e9,'mob-damage-amount')
  contact=contact or {}
  local now=group.clock:GetTimeSeconds(binding.actor)
  m.hits=m.hits or {};m.hit_order=m.hit_order or {}
  if action and m.hits[action] then return false end
  if action then
    local slot=(m.hit_slot or 0)%128+1
    local old=m.hit_order[slot];if old then m.hits[old]=nil end
    m.hits[action]=true;m.hit_order[slot]=action;m.hit_slot=slot
  end
  -- MC's hurt window rejects repeated equal/weaker damage; a stronger hit
  -- during it submits only the difference. Explicit /damage remains exact.
  local incoming=amount
  local in_window=not contact.command and now<(m.hurt_until or 0)
  if in_window then
    amount=math.max(0,amount-(m.last_damage or 0))
  end
  if amount<=0 then return false end
  m.last_damage=incoming
  if not in_window then m.hurt_until=now+.5 end
  local absorbed
  if m.status then
    local next,remaining,taken=require('rules.status_effects').damage(m.status,amount,contact.kind=='fire',false)
    -- The active service owns this table; preserve its identity during hits.
    m.status.absorption=next.absorption;amount=remaining;absorbed=taken
  else
    absorbed=math.min(m.absorption or 0,amount)
    m.absorption=(m.absorption or 0)-absorbed;amount=amount-absorbed
  end
  local before=m.health;m.health=math.max(0,before-amount)
  local result={before=before,after=m.health,absorbed=absorbed,requested=incoming,
    observed_delta=before-m.health,dispatched=true,hurt=true,health_hit=true,accepted=true,route='mc-living',killed=m.health<=0}
  m.last_hurt=now;m.hurt_count=(m.hurt_count or 0)+1
  if group.sounds then group.sounds:play(m,m.health<=0 and 'death' or 'hurt',now) end
  group.report.last_damage=result
  local ok,shown=pcall(group.combat.damage.flash.show,group.combat.damage.flash,actor)
  result.flash=ok and shown or false
  if not ok then result.flash_error=tostring(shown) end
  local d=contact.direction
  if m.health>0 and d and contact.knockback~=false then
    local length=math.sqrt(d.X*d.X+d.Y*d.Y)
    if length>.001 then actor:LaunchCharacter({X=d.X/length*240,Y=d.Y/length*240,Z=180},false,false) end
  end
  if m.health<=0 then
    m.steer=nil;m.target=nil;m.path=nil;m.following=nil;m.dying_until=now+.6
    m.move:StopMovementImmediately();m.move:SetMovementMode(0,0)
    actor:SetActorEnableCollision(false)
  end
  return true,result
end
return M
