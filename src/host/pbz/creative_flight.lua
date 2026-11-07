-- One reversible creative movement owner, independent of elytra, equipment
-- and F5. Native capsule sweeps retain map and MC block collision. No health,
-- inventory, save, native weapon dispatch or collision-disable writes here.
local rules=require('rules.creative_flight')
local identity=require('host.pbz.object_identity')
local valid=require('host.pbz.appearance').valid
local M={};M.__index=M
local function vec(p)return {X=p.X,Y=p.Y,Z=p.Z}end
local function clock(p)return StaticFindObject('/Script/Engine.Default__GameplayStatics'):GetTimeSeconds(p)end
local function down(keys,bit)return ((keys or 0)&(1<<bit))~=0 end
function M.new(binding,pc)
 return setmetatable({binding=binding,pc=pc,pc_id=identity.capture(pc),tap={},
  input=require('input.first_person_controls').new(pc.ControlRotation),
  report={starts=0,stops=0,ticks=0,sweeps=0,collisions=0,suspends=0}},M)
end
function M:input_batch(batch,allowed)
 self.latest=batch
 if self.binding.mc_creative~=true and not self.active then
  self.request=nil;if self.tap.epoch~=nil then self.tap={}end;return
 end
 local eligible=allowed and self.binding.mc_creative==true and batch.latest.focused and not batch.overflow
 local function sample(p)
  local held=down(p.keys,18);local t=(p.time_ms or batch.latest.time_ms or 0)/1000
  local accepted=eligible and p.focused and not down(batch.blocked_keys,18)
  if not accepted or self.tap.epoch~=p.epoch then self.request=nil end
  if rules.tap(self.tap,held,p.epoch,t,accepted)then self.request=true end
  if not held then self.takeoff_hold=nil end
 end
 for _,p in ipairs(batch.samples or {})do sample(p)end;sample(batch.latest)
 if not eligible then self.request=nil end
 if self.active then
  local x,y=self.input:sample_batch(batch,eligible and not self.suspended)
  if x then self.pc:SetMouseLocation(x,y)end
 end
end
function M:take_request(camera)
 local pressed=self.request;self.request=nil
 if not pressed or not self.binding.mc_creative then return false end
 if self.active then return 'stop' end
 local p=self.binding.actor;local mode=p.CharacterMovement.MovementMode
 if p.AttributeSetBase.Health.CurrentValue<=0 or self.binding.mc_boat_riding or camera:traversal(self.binding)
  or (mode~=1 and mode~=2 and mode~=3 and not (mode==0 and self.binding.mc_gliding))then return false end
 return 'start'
end
function M:set_input_owned(wanted)
 if not identity.matches(self.pc,self.pc_id)then return end
 if wanted then
  if not self.look_lease then self.pc:SetIgnoreLookInput(true);self.look_lease=true end
  if not self.move_lease then self.pc:SetIgnoreMoveInput(true);self.move_lease=true end
 else
  if self.look_lease then self.pc:SetIgnoreLookInput(false);self.look_lease=nil end
  if self.move_lease then self.pc:SetIgnoreMoveInput(false);self.move_lease=nil end
 end
end
function M:suspend(value)
 if not self.active then return end
 if value and not self.suspended then
  self.report.suspends=self.report.suspends+1
  self.suspended=true;self:set_input_owned(false);self.input:reset()
  self.sprinting=false
  self.physics.vx,self.physics.vy,self.physics.vz=0,0,0;self.velocity={X=0,Y=0,Z=0};self.accumulator=0
 elseif not value and self.suspended then
  self.suspended=nil;self:set_input_owned(true)
  self.input=require('input.first_person_controls').new(self.pc.ControlRotation)
  if self.latest then self.input:sample_batch(self.latest,true)end
 end
end
function M:start(initial_velocity)
 assert(not self.closed and not self.active and self.binding:is_current()and self.binding.mc_creative,'creative-flight-owner')
 local p=self.binding.actor;local m=p.CharacterMovement
 assert(not self.binding.mc_movement_owner and not self.binding.mc_gliding,'creative-flight-movement-already-owned')
 self.movement=m;self.movement_id=identity.capture(m);self.mode=m.MovementMode;self.custom=m.CustomMovementMode
 self.anim=self.binding.source:GetAnimInstance();self.anim_id=valid(self.anim)and identity.capture(self.anim)
 self.root=self.anim_id and self.anim.RootMotionMode;self.use_yaw=p.bUseControllerRotationYaw
 self.velocity=vec(initial_velocity or p:GetVelocity())
 self.physics=rules.new(self.velocity);if self.mode==1 or self.mode==2 then self.physics.vz=840 end
 self.accumulator=0;self.last=clock(p);self.pending=0
 self.frame={rotation={Pitch=self.pc.ControlRotation.Pitch,Yaw=self.pc.ControlRotation.Yaw,Roll=0},direction={X=0,Y=0,Z=0}}
 self.input=require('input.first_person_controls').new(self.pc.ControlRotation)
 self.active=true;self.binding.mc_creative_flight=self;self.takeoff_hold=true;self.suspended=nil
 local ok,why=pcall(function()
  self:set_input_owned(true);p.bUseControllerRotationYaw=false
  -- PBZ treats leaving Falling (including to None) as a landing callback.
  -- Flying clears Minecraft's fall distance; clear this proven native origin
  -- before the handoff so its later hard-landing hitreact cannot fire here.
  if self.mode==3 then p.BeforeFallingLocation=vec(p:K2_GetActorLocation())end
  m:StopMovementImmediately();m:SetMovementMode(0,0)
  if self.anim_id then self.anim:SetRootMotionMode(1)end
  if self.latest then self.input:sample_batch(self.latest,true)end
 end)
 if not ok then self:stop('start-failed');error(why)end
 self.report.starts=self.report.starts+1;self.report.reason=nil
 self.binding.log('MC creative flight started')
end
function M:stop(reason,grounded)
 if not self.active then return end
 self.active=false;self.suspended=nil;self.takeoff_hold=nil;self.pending=0;self.request=nil
 self.report.stops=self.report.stops+1;self.report.reason=reason
 if self.binding.mc_creative_flight==self then self.binding.mc_creative_flight=nil end
 if identity.matches(self.anim,self.anim_id)and self.anim.RootMotionMode==1 then self.anim:SetRootMotionMode(self.root)end
 if self.binding:is_current()then
  local p=self.binding.actor;p.bUseControllerRotationYaw=self.use_yaw
  if identity.matches(self.movement,self.movement_id)and identity.matches(p.CharacterMovement,self.movement_id)
   and self.movement.MovementMode==0 then
   local alive=p.AttributeSetBase.Health.CurrentValue>0
   self.movement:SetMovementMode(alive and (grounded and 1 or 3)or 0,0)
   -- Native falling begins at the current location. Creative flight altitude
   -- is never replayed as a native fall when the mode or flight is disabled.
   if alive and not grounded and (reason=='double-tap'or reason=='gamemode-changed')then p:LaunchCharacter(self.velocity,true,true)end
  end
 end
 self:set_input_owned(false);self.input:reset();self.tap={}
 self.binding.log('MC creative flight stopped: '..tostring(reason))
end
function M:sweep(dt)
 local p=self.binding.actor;local start=vec(p:K2_GetActorLocation());local v=self.velocity
 local finish={X=start.X+v.X*dt,Y=start.Y+v.Y*dt,Z=start.Z+v.Z*dt};local hit={}
 p:K2_SetActorLocation(finish,true,hit,false);self.report.sweeps=self.report.sweeps+1
 local after=vec(p:K2_GetActorLocation())
 if (finish.X-after.X)^2+(finish.Y-after.Y)^2+(finish.Z-after.Z)^2<=.01 then return end
 local normal=hit.ImpactNormal or hit.Normal
 if not normal then self:stop('invalid-collision');return end
 normal=vec(normal);self.report.collisions=self.report.collisions+1
 if normal.Z>.65 and v.Z<=0 then self:stop('landed',true);return end
 self.velocity=rules.project(v,normal);rules.collide(self.physics,normal)
 if math.abs(normal.Z)<.65 then self.sprinting=false end
 local travelled=math.sqrt((after.X-start.X)^2+(after.Y-start.Y)^2+(after.Z-start.Z)^2)
 local intended=math.sqrt((finish.X-start.X)^2+(finish.Y-start.Y)^2+(finish.Z-start.Z)^2)
 local remaining=dt*(1-math.min(1,travelled/math.max(.001,intended)))
 if remaining>1e-7 then
  local slide={X=after.X+self.velocity.X*remaining,Y=after.Y+self.velocity.Y*remaining,Z=after.Z+self.velocity.Z*remaining}
  local second={};p:K2_SetActorLocation(slide,true,second,false);self.report.sweeps=self.report.sweeps+1
  local at=vec(p:K2_GetActorLocation())
  if (slide.X-at.X)^2+(slide.Y-at.Y)^2+(slide.Z-at.Z)^2>.01 then
   local n=second.ImpactNormal or second.Normal
   if not n then self:stop('invalid-slide-collision');return end
   n=vec(n);self.velocity=rules.project(self.velocity,n);rules.collide(self.physics,n)
   if n.Z>.65 and v.Z<=0 then self:stop('landed',true)end
  end
 end
end
function M:tick(camera,reason)
 if not self.active then return end
 if not self.binding:is_current()or not identity.matches(self.pc,self.pc_id)then self:stop('owner-replaced');return end
 local p=self.binding.actor
 if not identity.matches(p.CharacterMovement,self.movement_id)then self:stop('movement-replaced');return end
 if not self.binding.mc_creative or p.AttributeSetBase.Health.CurrentValue<=0 or self.binding.mc_boat_riding or reason then
  self:stop(reason and 'native-takeover'or not self.binding.mc_creative and 'gamemode-changed'or 'player-unavailable');return
 end
 if self.movement.MovementMode~=0 then self:stop('native-movement-takeover');return end
 local now=clock(p);local dt=math.max(0,now-self.last);self.last=now
 local game=StaticFindObject('/Script/Engine.Default__GameplayStatics')
 local paused=camera.inventory or not camera.focused or camera.transition or self.binding.mc_native_selection_pending
  or self.pc.bShowMouseCursor or game:IsGamePaused(self.pc)
 self:suspend(paused==true)
 if paused then self.pending=0;return end
 self.pending=self.pending+dt
 if self.pending>2 then self:stop('clock-interruption');return end
 dt=math.min(.2,self.pending);self.pending=self.pending-dt
 if identity.matches(self.anim,self.anim_id)then self.anim:SetRootMotionMode(1)end
 local batch=self.latest;local pstate=batch and batch.latest
 local keys=0
 if pstate and pstate.focused then
  -- Flying uses continuous ascent/descent, not the ground controller's jump
  -- repeat. The accepted second tap may remain held across the one necessary
  -- native input-context handoff; unrelated inherited action keys stay blocked.
  keys=(pstate.keys or 0)&~(batch.blocked_keys or 0)
  if self.takeoff_hold and down(pstate.keys,18)then keys=keys|(1<<18)end
  self.input.keys=keys
 end
 local action=require('host.pbz.item_interface').combat_presentation()
 local using=action and (action.shield_active or (action.eating or 0)>0 or (action.bow_charge or 0)>0 or (action.trident_charge or 0)>0)
 if not down(keys,14)or down(keys,16)then self.sprinting=false
 elseif down(keys,20)and not using then self.sprinting=true end
 self.frame=self.input:frame();self.frame.sprint=self.sprinting==true;self.frame.using_item=using==true
 local forward=(down(keys,14)and 1 or 0)-(down(keys,16)and 1 or 0)
 local right=(down(keys,17)and 1 or 0)-(down(keys,15)and 1 or 0)
 self.frame.input_length=math.sqrt(forward*forward+right*right)
 self.pc:SetControlRotation(self.frame.rotation)
 p:K2_SetActorRotation({Pitch=0,Yaw=self.frame.rotation.Yaw,Roll=0},false)
 while dt>1e-7 and self.active do
  if self.accumulator<=1e-7 then
   local next=rules.step(self.physics,self.frame);self.velocity=next.travel_velocity
   self.report.ticks=self.report.ticks+1;self.accumulator=.05
  end
  local step=math.min(dt,self.accumulator);self:sweep(step);dt=dt-step;self.accumulator=self.accumulator-step
 end
 self.report.velocity=self.velocity;self.report.backlog=self.pending
end
function M:close()
 if self.closed then return end
 self:stop('closed');self.closed=true
end
return M
