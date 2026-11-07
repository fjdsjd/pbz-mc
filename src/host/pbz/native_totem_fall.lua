-- PBZ has a 0.1s airborne GE_Kill timer AND a separate landing damage write.
-- A ready totem, or a held mace approaching a surface, can defer the early
-- kill until landing. Only a confirmed mace hit resets the fall's origin.
-- This lease is one fall, never an invulnerability window or a gameplay tag.
local M={}
local identity=require('host.pbz.object_identity')
local function api()return StaticFindObject('/Script/Engine.Default__KismetSystemLibrary')end
local function now(pawn)return StaticFindObject('/Script/Engine.Default__GameplayStatics'):GetTimeSeconds(pawn)end
function M.wind_lift(binding,p)
 local pawn=binding.actor;local airborne=pawn.CharacterMovement.MovementMode==3
 binding.mc_wind_lift={z=p.Z,airborne=airborne or binding.mc_gliding~=nil,deadline=now(pawn)+.25}
 if airborne then pawn.BeforeFallingLocation={X=p.X,Y=p.Y,Z=p.Z} end
end
local function update_wind(binding,pawn,mode)
 local lift=binding.mc_wind_lift
 if not lift then return end
 if mode==3 then
  lift.airborne=true
  -- A native movement transition (e.g. closing the elytra) can set a new
  -- falling origin above the burst. Preserve lower origins from a safe landing.
  local from=pawn.BeforeFallingLocation
  if from.Z>lift.z then pawn.BeforeFallingLocation={X=from.X,Y=from.Y,Z=lift.z} end
 elseif binding.mc_gliding then lift.airborne=true
 elseif lift.airborne or (mode~=1 and mode~=2) or now(pawn)>lift.deadline then binding.mc_wind_lift=nil end
end
local function mace_approach(service,pawn,lease)
 local binding=service.binding
 if not binding.mc_mace_owner or binding.mc_gliding or binding.mc_boat_riding or binding.mc_creative_flight then return false end
 local p=pawn:K2_GetActorLocation();local vz=pawn:GetVelocity().Z
 -- PBZ can kill the player midair before a high smash can reach its target.
 -- Defer that timer only on a descending approach with a surface below.
 -- A miss retains the original fall height and the original landing damage.
 if vz>=0 or pawn.BeforeFallingLocation.Z-p.Z<pawn.DeadDepth-math.max(350,-vz*.25) then return false end
 local now=StaticFindObject('/Script/Engine.Default__GameplayStatics'):GetTimeSeconds(pawn)
 if not lease.next_floor or now>=lease.next_floor or math.abs(p.X-lease.x)>70 or math.abs(p.Y-lease.y)>70 then
  local color={R=0,G=0,B=0,A=0}
  lease.floor=api():LineTraceSingle(pawn,{X=p.X,Y=p.Y,Z=p.Z},{X=p.X,Y=p.Y,Z=p.Z-25600},0,false,{pawn},0,{},true,color,color,0)
  lease.next_floor=now+.1;lease.x=p.X;lease.y=p.Y
 end
 return lease.floor==true
end
local function restore(service,lease)
 local pawn=service.binding.actor
 if not lease.paused or not identity.matches(pawn,lease.pawn)or pawn.CharacterMovement.MovementMode~=3 then return end
 pawn.FallingDeathCheckHandle=api():K2_SetTimer(pawn,'TeleportToSafe',.1,true,false,0,0)
 assert(api():K2_IsTimerActiveHandle(pawn,pawn.FallingDeathCheckHandle),'totem-fall-timer-restore-failed')
 lease.paused=false;service.report.fall_timer_restored=(service.report.fall_timer_restored or 0)+1
end
function M.tick(service)
 local pawn=service.binding.actor;local lease=service.totem_fall
 local mode=pawn.CharacterMovement.MovementMode
 local gentle=service.value.effects.levitation or service.value.effects.slow_falling
 if gentle then
  pawn.BeforeFallingLocation=pawn:K2_GetActorLocation()
  require('host.pbz.item_interface').reset_fall_after_teleport(service.binding)
 end
 if service.binding.mc_wind_lift then update_wind(service.binding,pawn,mode) end
 if mode~=3 then
  if lease then service.report.fall_timer_landed=(service.report.fall_timer_landed or 0)+1 end
  service.totem_fall=nil;return
 end
 if not lease then lease={pawn=identity.capture(pawn)};service.totem_fall=lease end
 local eligible=gentle~=nil or (service.value.totem_cooldown<=0 and service:totem_hand()~=nil) or mace_approach(service,pawn,lease)
 if eligible==lease.eligible then return end -- no repeated timer calls per frame
 lease.eligible=eligible
 if eligible then
  if api():K2_IsTimerActiveHandle(pawn,pawn.FallingDeathCheckHandle)then
   api():K2_ClearTimerHandle(pawn,pawn.FallingDeathCheckHandle)
   lease.paused=true;service.report.fall_timer_deferred=(service.report.fall_timer_deferred or 0)+1
  end
 else restore(service,lease)end
end
function M.close(service)
 service.binding.mc_wind_lift=nil
 if service.totem_fall then restore(service,service.totem_fall);service.totem_fall=nil end
end
return M
