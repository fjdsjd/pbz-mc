-- One bounded piercing trace per obstructing body. Only an equipped, active
-- spear runs this query. UE supplies collision and PBZ owns damage and armour.
local rules=require('rules.minecraft_combat')
local profiles=require('content.combat_profiles')
local block=require('rules.build_grid').size
local valid=require('host.pbz.appearance').valid
local boats=require('host.pbz.boat_service')
local M={}
local sword=profiles.get('pbzmc:diamond_sword')
local damage_per_point=sword.adventure_attack/sword.free_melee_damage
local function offset(p,d,n)return {X=p.X+d.X*n,Y=p.Y+d.Y*n,Z=p.Z+d.Z*n} end
local function copy(v)return {X=v.X,Y=v.Y,Z=v.Z} end

local function along(combat,from,to,radius,class,ignore,targets)
  for _=1,16 do
    local yes,hit,actor=combat:trace(from,to,radius,nil,ignore)
    if not yes then return true end
    if not valid(actor) or not actor:IsA(class) then return false end
    ignore[#ignore+1]=actor
    if targets then
      targets[#targets+1]={actor=actor,location=hit.bStartPenetrating and from or copy(hit.ImpactPoint)}
    end
  end
  return false
end

local function speed(actor,direction,flight,seat)
  if seat then
    -- Boat simulation velocities are in host centimetres per game tick.
    local s=seat.state
    return (s.vx*direction.X+s.vy*direction.Y+s.vz*direction.Z)*20/block
  end
  return rules.spear_speed(flight and flight.velocity or actor:GetVelocity(),direction)
end

local function push(actor,direction)
  local horizontal=math.sqrt(direction.X^2+direction.Y^2)
  if horizontal<.001 then return end
  local movement=actor.CharacterMovement
  if not valid(movement) or movement.MovementMode==0 then return end
  actor:LaunchCharacter({X=direction.X/horizontal*240,Y=direction.Y/horizontal*240,Z=0},false,false)
end

function M.strike(combat,record,charged)
  local binding=combat.binding
  local weapon=record.equipment.main.content_id
  local stats=profiles.get(weapon).spear
  local tick=rules.spear_tick(record.now)
  local prefix=weapon=='pbzmc:wooden_spear' and 'spear_wood_' or 'spear_'
  local origin,dir=combat:aim()
  local charge
  if charged then
    if rules.spear_tick(record.elapsed)<rules.spear_tick(stats.delay) then return false end
    charge=combat.spear_charge
    if not charge or charge.id~=record.action_id then
      charge={id=record.action_id,feedback={},prune=tick+20};combat.spear_charge=charge
      combat:sound(prefix..'use',origin)
    end
    if charge.tick==tick then return false end
    charge.tick=tick
    if tick>=charge.prune then
      for target,next_tick in pairs(charge.feedback) do
        if next_tick<=tick then charge.feedback[target]=nil end
      end
      charge.prune=tick+20
    end
  else
    combat.spear_charge=nil
    combat:sound(prefix..'attack',origin)
  end

  local pawn=binding.actor
  local service=boats.get(binding)
  local attacker=speed(pawn,dir,binding.mc_gliding or binding.mc_creative_flight,service and service.driver)
  local report={action_id=record.action_id,tick=tick,charged=charged,attacker_speed=attacker,contact_count=0,hit_count=0}
  combat.last_spear=report
  local near=offset(origin,dir,stats.min_reach*block)
  local reach=record.equipment.mode=='creative' and stats.creative_reach or stats.max_reach
  if not charged and combat.wind and combat.wind:melee(origin,dir,stats.min_reach*block,reach*block) then return true end
  local far=offset(origin,dir,reach*block)
  local targets,ignore={},{pawn}
  if service and service.driver then ignore[#ignore+1]=service.driver.handle.actor end
  local characters=StaticFindObject('/Script/Engine.Character')
  -- First collect bodies on the usable part of the shaft, stopping at the
  -- first wall. A wall between the eye and the near end blocks the whole jab.
  along(combat,near,far,stats.hitbox_margin*block,characters,ignore,targets)
  if #targets==0 or not along(combat,origin,near,.1,characters,ignore) then return false end
  local hit_id=charged and record.action_id..'/tick/'..tick or record.action_id
  for _,entry in ipairs(targets) do
    local target=entry.actor
    if valid(target) then
      report.contact_count=report.contact_count+1
      local seat,rider
      if service then seat,rider=service:spear_seat(target) end
      local target_speed=speed(target,dir,nil,seat)
      local points=charged and rules.charge_damage(stats,attacker,target_speed,record.elapsed) or stats.base_damage
      local amount=math.min(10000,points*damage_per_point)
      report.target_speed=target_speed;report.relative_speed=math.max(0,attacker-target_speed)
      report.base_requested=amount
      local key=target:GetAddress()
      local feedback=not charge or tick>=(charge.feedback[key] or 0)
      local hit=amount>0 and combat.damage:hit(target,amount,hit_id,
        {kind='spear',weapon_id=weapon,direction=dir,location=entry.location,feedback=feedback,mc_damage=points})
      if hit then
        combat.hits=combat.hits+1;report.hit_count=report.hit_count+1
      end
      local knock=not charged or rules.charge_knockback(stats,attacker,record.elapsed)
      local dismount=seat and charged and rules.charge_dismount(stats,attacker,record.elapsed)
      if feedback and (hit or amount==0 and (knock or dismount) and combat.damage:eligible(target)) then
        -- Limit native stagger, material updates, sound and impulses. Damage
        -- remains eligible every new simulation tick during continuous contact.
        if charge then charge.feedback[key]=tick+10 end
        if combat.damage:eligible(target) then
          if dismount and service:release(seat,rider,'spear',true) then seat=nil end
          if knock and not seat then push(target,dir) end
        end
        if hit then report.recoil=true end
      end
    end
  end
  if report.recoil then
    combat.actions:record_spear_contact(record.source,record.action_id,record.now)
    combat:sound(prefix..'hit',origin)
  end
  return report.hit_count>0
end
return M
