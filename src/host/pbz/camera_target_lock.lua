local valid=require('host.pbz.appearance').valid
local M={}
function M.active(camera,binding)
  if camera.lock_tick~=camera.ticks or camera.lock_binding~=binding then
    if camera.lock_binding~=binding or not valid(camera.targeting) then
      camera.targeting=binding.actor:GetTargetingComponent()
    end
    -- This is the component changed by IA_LockTarget. GetLockingTarget(true)
    -- on the pawn can be null even while this component has a manual lock.
    camera.locked=valid(camera.targeting) and camera.targeting:HasLockTarget() or false
    camera.lock_tick=camera.ticks;camera.lock_binding=binding
  end
  return camera.locked
end
function M.aim(current,binding,pc,locked)
  if not locked then return current end
  -- The native camera component supplies the current target point (including
  -- boss-specific lock sockets); a nearby soft target alone never reaches here.
  local native=binding.actor.NBCamera
  local point=valid(native) and native:GetCurrentLockComponent()
  if valid(point) then
    local at=point:K2_GetComponentLocation()
    local dx,dy,dz=at.X-current.position.X,at.Y-current.position.Y,at.Z-current.position.Z
    if dx*dx+dy*dy+dz*dz>.01 then
      current.rotation={Pitch=math.deg(math.atan(dz,math.sqrt(dx*dx+dy*dy))),Yaw=math.deg(math.atan(dy,dx)),Roll=0}
      return current
    end
  end
  -- A transitioning camera may not yet expose the lock socket. Keep native
  -- control even on this frame, instead of reviving a stale free-look heading.
  current.rotation={Pitch=pc.ControlRotation.Pitch,Yaw=pc.ControlRotation.Yaw,Roll=0}
  return current
end
return M
