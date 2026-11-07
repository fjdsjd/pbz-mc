-- MaceItem (Java 26.3) and wukong-steve ModernWeaponCombat/MinecraftWind.
-- Only a confirmed native hit can change the player's falling episode.
local profiles=require('content.combat_profiles')
local rules=require('rules.minecraft_combat')
local valid=require('host.pbz.appearance').valid
local block=require('rules.build_grid').size
local M={}
local function vec(p) return {X=p.X,Y=p.Y,Z=p.Z} end
local function feet(actor,center)
  return {X=center.X,Y=center.Y,Z=center.Z-actor.CapsuleComponent:GetScaledCapsuleHalfHeight()}
end
local function clear(combat,a,b,ignored)
  if a.X==b.X and a.Y==b.Y and a.Z==b.Z then return true end
  local color={R=0,G=0,B=0,A=0}
  return not require('UEHelpers').GetKismetSystemLibrary():LineTraceSingle(combat.binding.actor,a,b,0,false,ignored,0,{},true,color,color,0)
end
local function show_impact(combat,ground,wind,fall)
  return require('host.pbz.sprite_particles').impact(combat,{ground=ground,wind=wind,fall=fall})
end
local function push_nearby(combat,target,target_address,center,wind_origin,fall,wind)
  local pawn=combat.binding.actor
  local radius=wind>0 and 700 or 350
  local origin=wind>0 and wind_origin or center
  local ignored={pawn}
  if valid(target) then ignored[2]=target end
  local found={}
  local object_types=require('host.pbz.build_world').object_types
  require('UEHelpers').GetKismetSystemLibrary():SphereOverlapActors(pawn,origin,radius+200,object_types,
    StaticFindObject('/Script/ProjectPBZ.PBZCharacter'),{pawn},found)
  local pushed=0
  for _,item in ipairs(found) do
    local actor=item.GetFullName and item or item:get()
    if valid(actor) and combat.damage:eligible(actor) and actor.CharacterMovement.MovementMode~=0 then
      local p=vec(actor:K2_GetActorLocation())
      local x,y,z=p.X-center.X,p.Y-center.Y,p.Z-center.Z
      local distance=math.sqrt(x*x+y*y+z*z)
      local dx,dy,dz=0,0,0
      local primary=actor:GetAddress()==target_address
      local trace_ignore=ignored
      if not primary then trace_ignore={pawn,actor,ignored[2]} end
      if not primary and distance>0 and distance<350 and clear(combat,center,p,trace_ignore) then
        local impulse=(350-distance)*.7*(fall>5 and 2 or 1)
        dx=x/distance*impulse;dy=y/distance*impulse;dz=700
      end
      if wind>0 then
        local impulse=require('host.pbz.wind_burst').body_impulse(combat.binding,actor,origin,radius,rules.wind_multiplier(wind),
          function()return {table.unpack(trace_ignore)}end)
        if impulse then dx=dx+impulse.X;dy=dy+impulse.Y;dz=dz+impulse.Z end
      end
      if dx~=0 or dy~=0 or dz~=0 then
        actor:LaunchCharacter({X=dx,Y=dy,Z=dz},false,false);pushed=pushed+1
      end
    end
  end
  return pushed
end
local function strike_distance(combat,pawn,velocity)
  local b=combat.binding
  if pawn.CharacterMovement.MovementMode~=3 or velocity.Z>=0 or b.mc_gliding or b.mc_creative_flight
    or b.mc_boat_riding or (b.mc_fluid_contact and b.mc_fluid_contact.active~=false and b.mc_fluid_contact.kind
    and (not b.mc_fluid_contact.valid_until or combat.now<=b.mc_fluid_contact.valid_until)) then return 0 end
  local distance=combat.fall_state and combat.fall_state.distance or 0
  local camera=require('host.pbz.first_person_camera').get()
  local flight=camera and camera.flight
  if flight and flight.binding==b and not flight.active and flight.fall_mode==3 then
    distance=math.max(distance,flight.fall_distance)
  end
  return distance/block
end
local function reset_impact(combat,pawn,p,wind)
  -- Both the airborne PBZ kill check and its landing calculation measure from
  -- this reflected origin. Keep the lower origin across chained wind bounces.
  local before=pawn.BeforeFallingLocation
  if before.Z>p.Z then pawn.BeforeFallingLocation={X=before.X,Y=before.Y,Z=p.Z} end
  combat.fall_state=nil
  require('host.pbz.item_interface').reset_fall_after_teleport(combat.binding)
  pawn:LaunchCharacter({X=0,Y=0,Z=wind>0 and rules.wind_multiplier(wind)*2000 or 20},false,true)
end
function M.strike(combat,record)
  local pawn=combat.binding.actor
  local start,dir=combat:aim()
  if combat.wind and combat.wind:melee(start,dir,0,300) then return true end
  local finish={X=start.X+dir.X*300,Y=start.Y+dir.Y*300,Z=start.Z+dir.Z*300}
  local yes,hit,target=combat:trace(start,finish,25)
  local profile=require('rules.commands.gameplay')._mace_profile(record.equipment.main)
  local fall=strike_distance(combat,pawn,pawn:GetVelocity())
  local report={distance=fall,smash=false,hit=false}
  combat.last_mace=report
  if not yes or not target or not combat.damage:eligible(target) then
    combat:sound('sword_miss',start);return false
  end
  local contact=hit.bStartPenetrating and start or vec(hit.ImpactPoint)
  if not clear(combat,start,contact,{pawn,target}) then return false end
  local target_center=vec(target:K2_GetActorLocation())
  local target_address=target:GetAddress()
  local grounded=target.CharacterMovement.MovementMode==1 or target.CharacterMovement.MovementMode==2
  local ground_point=feet(target,target_center)
  local smash=fall>1.5
  local lease=combat.binding.mc_movement_owner
  local critical=not smash and fall>0 and rules.critical(record.strength,pawn:GetVelocity().Z,lease and lease.frame and lease.frame.sprint)
  local points=rules.melee_damage(profile.free_melee_damage,record.strength,critical)+rules.smash_bonus(fall,profile.density)
  if profile.breach>0 and not require('host.pbz.mob_living').find(combat.binding,target) then
    -- PBZ's native TakeDamage applies this fraction after the mod's hit.
    -- Compensate only for the share bypassed by Breach, on this attack.
    local reduction=target.AttributeSetBase.Resistance_Physical.CurrentValue
    points=points*rules.armor_multiplier(reduction,profile.breach)
    report.resistance=reduction
  end
  local amount=math.min(10000,points*profile.adventure_attack/profile.free_melee_damage)
  report.base=amount;report.critical=critical
  if not combat.damage:hit(target,amount,record.action_id,{kind='mace',weapon_id=profile.content_id,smash=smash,
    direction=dir,location=contact}) then return false end
  combat.hits=combat.hits+1;report.hit=true;report.smash=smash
  if not smash then
    combat:sound(record.strength>.9 and 'sword_strong' or 'sword_weak',contact)
    if critical then
      local ok,why=pcall(function()
        if not combat.critical_fx then combat.critical_fx=require('host.pbz.critical_particles').new(combat.binding,combat.pc) end
        if valid(target) then combat.critical_fx:burst(target) end
      end)
      if not ok then report.fx_error=tostring(why);combat.log('MC mace critical particles: '..report.fx_error) end
    end
    return true
  end
  local p=vec(pawn:K2_GetActorLocation())
  reset_impact(combat,pawn,p,profile.wind_burst)
  local origin=feet(pawn,p);origin.Z=origin.Z+2
  report.wind=profile.wind_burst
  report.sound=not grounded and 'mace_air' or fall>5 and 'mace_heavy' or 'mace_ground'
  report.audio=combat:sound(report.sound,contact)
  if profile.wind_burst>0 then report.wind_audio=combat:sound('mace_wind',origin) end
  report.pushed=push_nearby(combat,target,target_address,target_center,origin,fall,profile.wind_burst)
  if grounded or profile.wind_burst>0 then
    local ok,why=pcall(show_impact,combat,grounded and ground_point or nil,profile.wind_burst>0 and origin or nil,fall)
    if not ok then report.fx_error=tostring(why);combat.log('MC mace impact particles: '..report.fx_error) end
  end
  return true
end
return M
