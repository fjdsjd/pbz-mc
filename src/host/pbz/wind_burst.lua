-- One bounded local overlap per impact. Only the projectile's direct victim
-- receives damage; this module owns the air impulse and world interactions.
local rules=require('rules.wind_charge')
local valid=require('host.pbz.appearance').valid
local UE=require('UEHelpers')
local M={}
local color={R=0,G=0,B=0,A=0}
function M.clear(binding,a,b,ignored)
  if a.X==b.X and a.Y==b.Y and a.Z==b.Z then return true end
  local lib=UE.GetKismetSystemLibrary()
  local build
  for _=1,12 do
    local hit={}
    if not lib:LineTraceSingle(binding.actor,a,b,0,false,ignored,0,hit,true,color,color,0) then return true end
    build=build or require('host.pbz.building_service').get(binding)
    local handle=build and build.world:hit_handle(hit)
    local def=handle and require('content.blocks').get(handle.content_id)
    if not def or def.collision~=false or not valid(handle.actor) then return false end
    ignored[#ignored+1]=handle.actor
  end
  return false
end
function M.body_impulse(binding,actor,origin,reach,multiplier,ignore)
  local pos=actor:K2_GetActorLocation();local capsule=actor.CapsuleComponent
  local half=capsule:GetScaledCapsuleHalfHeight()
  local feet={X=pos.X,Y=pos.Y,Z=pos.Z-half}
  local push=rules.impulse(origin,feet,capsule:GetScaledCapsuleRadius(),half,reach,multiplier,1)
  if not push then return nil end
  local visible=0
  for _,level in ipairs({-.8,0,.8}) do
    if M.clear(binding,origin,{X=pos.X,Y=pos.Y,Z=pos.Z+level*half},ignore()) then visible=visible+1 end
  end
  if visible==0 then return nil end
  local w=visible/3
  return {X=push.X*w,Y=push.Y*w,Z=push.Z*w}
end
function M.apply(combat,origin)
  local binding=combat.binding;local pawn=binding.actor
  local boats=require('host.pbz.boat_service').get(binding)
  local function ignore(actor,second)
    local list={pawn}
    if actor and actor:GetAddress()~=pawn:GetAddress() then list[#list+1]=actor end
    if second then list[#list+1]=second end
    return list
  end
  local function visible(a,b,actor,second)return M.clear(binding,a,b,ignore(actor,second)) end
  local result={characters=0,player=false}
  local function push(actor,player)
    if not valid(actor) or (player and (binding.mc_creative_flight or binding.mc_boat_riding))
      or (not player and (not combat.damage:eligible(actor) or (boats and boats:spear_seat(actor)))) then return end
    local glider=player and binding.mc_gliding
    if actor.CharacterMovement.MovementMode==0 and not glider then return end
    local impulse=M.body_impulse(binding,actor,origin,rules.radius,rules.multiplier,function()return ignore(actor)end)
    if not impulse then return end
    if glider and glider.physics and glider.velocity then
      local vel=glider.velocity
      vel.X=vel.X+impulse.X;vel.Y=vel.Y+impulse.Y;vel.Z=vel.Z+impulse.Z
      glider.physics.vx,glider.physics.vy,glider.physics.vz=vel.X,vel.Y,vel.Z
    else
      actor:LaunchCharacter(impulse,false,false)
    end
    if player then
      local p=pawn:K2_GetActorLocation()
      combat.fall_state=nil;require('host.pbz.item_interface').reset_fall_after_teleport(binding)
      require('host.pbz.native_totem_fall').wind_lift(binding,p)
      result.player=true;result.player_impulse=impulse;result.launch_height=p.Z
    else result.characters=result.characters+1 end
  end
  local found={};local seen={[pawn:GetAddress()]=true}
  UE.GetKismetSystemLibrary():SphereOverlapActors(pawn,origin,rules.radius+200,require('host.pbz.build_world').object_types,
    StaticFindObject('/Script/ProjectPBZ.PBZCharacter'),{pawn},found)
  push(pawn,true)
  for _,item in ipairs(found) do
    local actor=item.GetFullName and item or item:get()
    if valid(actor) then
      local key=actor:GetAddress()
      if not seen[key] then seen[key]=true;push(actor,false) end
    end
  end
  if boats then result.boats=boats:wind_burst(origin,rules.radius,visible) end
  local build=require('host.pbz.building_service').get(binding)
  if build and build.mechanisms then
    result.mechanisms,result.switch_error=build.mechanisms:wind_pulse(origin,rules.radius,visible)
  end
  local tnt=require('host.pbz.tnt_service').get(binding)
  if tnt then result.fires,result.tnt=tnt:wind_burst(origin,rules.radius,visible) end
  return result
end
return M
