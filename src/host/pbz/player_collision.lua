-- Steve's footprint is independent of held item and camera. Preserve native
-- capsule height, grounded feet and skeleton offsets; only narrow its radius.
-- Native traversal and cinematics reclaim their incoming configuration.
local ids=require('host.pbz.object_identity')
local M={};M.__index=M
function M.new(binding)
  assert(binding:is_current(),'player-collision-owner')
  local cap=binding.actor.CapsuleComponent
  local move=binding.actor.CharacterMovement
  local self=setmetatable({binding=binding,cap=cap,id=ids.capture(cap),move=move,move_id=ids.capture(move),
    radius=cap:GetUnscaledCapsuleRadius(),step=move.MaxStepHeight},M)
  local scaled=cap:GetScaledCapsuleRadius()
  assert(scaled>0 and self.radius>0,'player-collision-scale')
  self.applied=30*self.radius/scaled -- Minecraft 0.6 m-wide standing player.
  cap:SetCapsuleRadius(self.applied,true)
  move.MaxStepHeight=60
  return self
end
function M:close()
  if self.closed then return end;self.closed=true
  if ids.matches(self.cap,self.id) and math.abs(self.cap:GetUnscaledCapsuleRadius()-self.applied)<.001 then
    self.cap:SetCapsuleRadius(self.radius,true)
  end
  if ids.matches(self.move,self.move_id) and self.move.MaxStepHeight==60 then self.move.MaxStepHeight=self.step end
end
return M
