-- PBZ has a 0.1s airborne GE_Kill timer AND a separate landing damage write.
-- A ready held totem defers only that early kill until normal landing damage.
-- This lease is one fall, never an invulnerability window or a gameplay tag.
local M={}
local identity=require('host.pbz.object_identity')
local function api()return StaticFindObject('/Script/Engine.Default__KismetSystemLibrary')end
local function restore(service,lease)
 local pawn=service.binding.actor
 if not lease.paused or not identity.matches(pawn,lease.pawn)or pawn.CharacterMovement.MovementMode~=3 then return end
 pawn.FallingDeathCheckHandle=api():K2_SetTimer(pawn,'TeleportToSafe',.1,true,false,0,0)
 assert(api():K2_IsTimerActiveHandle(pawn,pawn.FallingDeathCheckHandle),'totem-fall-timer-restore-failed')
 lease.paused=false;service.report.fall_timer_restored=(service.report.fall_timer_restored or 0)+1
end
function M.tick(service)
 local pawn=service.binding.actor;local lease=service.totem_fall
 if pawn.CharacterMovement.MovementMode~=3 then
  if lease then service.report.fall_timer_landed=(service.report.fall_timer_landed or 0)+1 end
  service.totem_fall=nil;return
 end
 if not lease then lease={pawn=identity.capture(pawn)};service.totem_fall=lease end
 local eligible=service.value.totem_cooldown<=0 and service:totem_hand()~=nil
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
 if service.totem_fall then restore(service,service.totem_fall);service.totem_fall=nil end
end
return M
