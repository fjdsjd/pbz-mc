-- One reversible flight owner. MC equations run at 20 Hz; capsule sweeps run
-- every rendered frame. Never teleport through collision or disable damage.
local rules=require('rules.elytra_flight')
local id=require('host.pbz.object_identity')
local valid=require('host.pbz.appearance').valid
local M={};M.__index=M
local function vec(p)return {X=p.X,Y=p.Y,Z=p.Z}end
local function clock(p)return StaticFindObject('/Script/Engine.Default__GameplayStatics'):GetTimeSeconds(p)end
local function equipped(binding)
 local armor=require('host.pbz.campaign_inventory').armor_slots(binding)
 return armor and armor.chest and armor.chest.content_id=='pbzmc:elytra'
end
function M.new(binding,pc)
 return setmetatable({binding=binding,pc=pc,pc_id=id.capture(pc),report={starts=0,stops=0,ticks=0,sweeps=0},
  input=require('input.first_person_controls').new(pc.ControlRotation),fall_distance=0},M)
end
function M:input_batch(batch,allowed)
 local accept_jump=allowed and batch.latest.focused and not batch.overflow and ((batch.blocked_keys or 0)&(1<<18))==0
 local function sample(p)
  if not accept_jump or not p.focused then self.request=nil;self.down=nil;self.epoch=nil;return end
  if self.epoch~=p.epoch then self.request=nil;self.down=nil end
  local held=((p.keys or 0)&(1<<18))~=0
  if self.down==false and held then self.request=true end
  self.epoch=p.epoch;self.down=held
 end
 for _,p in ipairs(batch.samples or {})do sample(p)end;sample(batch.latest)
 if self.active then
  local x,y=self.input:sample_batch(batch,allowed and not batch.overflow)
  if x then self.pc:SetMouseLocation(x,y)end
 end
end
function M:wants_start(camera,allowed)
 local pressed=self.request;self.request=nil
 if not pressed or allowed==false or self.active or self.binding.mc_creative_flight or not equipped(self.binding)then return false end
 local p=self.binding.actor;local m=p.CharacterMovement
 local fluid=self.binding.mc_fluid_contact
 if fluid and fluid.valid_until and clock(p)>fluid.valid_until then fluid=nil end
 return rules.can_start({jump_pressed=true,equipped=true,alive=p.AttributeSetBase.Health.CurrentValue>0,on_ground=m.MovementMode==1 or m.MovementMode==2,
  touching_water=fluid and fluid.active~=false and fluid.kind~=nil,passenger=self.binding.mc_boat_riding~=nil,
  climbing=camera:traversal(self.binding)~=nil,native_flying=m.MovementMode~=3,
  levitating=false})
end
function M:observe_fall()
 if self.active or not self.binding:is_current()then return end
 local p=self.binding.actor;local z=p:K2_GetActorLocation().Z;local mode=p.CharacterMovement.MovementMode
 local fluid=self.binding.mc_fluid_contact
 local water=fluid and fluid.active~=false and fluid.kind and (not fluid.valid_until or clock(p)<=fluid.valid_until)
 if mode==1 or mode==2 or mode==4 or water then self.fall_distance=0
 elseif mode==3 and self.fall_z and self.fall_mode==3 then
  local dz=self.fall_z-z
  -- Developer/map teleports are not distance travelled by falling physics.
  if dz>0 and dz<5000 then self.fall_distance=self.fall_distance+dz end
 end
 self.fall_z=z;self.fall_mode=mode
end
function M:reset_fall()self.fall_distance=0;self.fall_z=nil;self.fall_mode=nil end
function M:start()
 assert(not self.closed and not self.active and self.binding:is_current(),'elytra-flight-owner')
 assert(not self.binding.mc_creative_flight and not self.binding.mc_movement_owner,'elytra-movement-already-owned')
 local p=self.binding.actor;local m=p.CharacterMovement;local v=p:GetVelocity()
 self.physics=rules.new({vx=v.X,vy=v.Y,vz=v.Z});self.velocity=vec(v);self.accumulator=0;self.pending=0;self.last=clock(p)
 self.movement=m;self.movement_id=id.capture(m);self.mode=m.MovementMode;self.custom=m.CustomMovementMode
 self.anim=self.binding.source:GetAnimInstance();self.anim_id=valid(self.anim)and id.capture(self.anim)
 self.root=self.anim_id and self.anim.RootMotionMode;self.use_yaw=p.bUseControllerRotationYaw
 self.active=true;self.binding.mc_gliding=self;self.frame={}
 self.input=require('input.first_person_controls').new(self.pc.ControlRotation)
 self.frame.rotation={Pitch=self.pc.ControlRotation.Pitch,Yaw=self.pc.ControlRotation.Yaw,Roll=0}
 self.look_lease=true;self.pc:SetIgnoreLookInput(true)
 self.move_lease=true;self.pc:SetIgnoreMoveInput(true)
 p.bUseControllerRotationYaw=false
 m:StopMovementImmediately();m:SetMovementMode(0,0)
 if self.anim_id then self.anim:SetRootMotionMode(1)end
 self.report.starts=self.report.starts+1;self.report.reason=nil
 self.binding.log('MC elytra glide started')
end
function M:stop(reason,grounded)
 if not self.active then return end
 self.active=false;self.report.stops=self.report.stops+1;self.report.reason=reason
 if self.collision then self.collision:close();self.collision=nil end
 self.fall_z=nil;self.fall_mode=nil
 if self.binding.mc_gliding==self then self.binding.mc_gliding=nil end
 if id.matches(self.anim,self.anim_id)and self.anim.RootMotionMode==1 then self.anim:SetRootMotionMode(self.root)end
 if self.binding:is_current()then
  local p=self.binding.actor;p.bUseControllerRotationYaw=self.use_yaw
  if id.matches(self.movement,self.movement_id)and id.matches(p.CharacterMovement,self.movement_id)and self.movement.MovementMode==0 then
   local alive=p.AttributeSetBase.Health.CurrentValue>0
   self.movement:SetMovementMode(alive and (grounded and 1 or 3)or 0,0)
   -- The creative controller inherits glide velocity directly. A queued
   -- native launch would return the pawn to Falling on its next engine tick.
   if alive and not grounded and reason~='native-takeover' and reason~='creative-flight' then p:LaunchCharacter(self.velocity,true,true)end
  end
 end
 if id.matches(self.pc,self.pc_id)then
  if self.look_lease then self.pc:SetIgnoreLookInput(false)end
  if self.move_lease then self.pc:SetIgnoreMoveInput(false)end
 end
 self.look_lease=nil;self.move_lease=nil;self.input:reset()
 if type(PBZMC_BlockSound)=='function'then pcall(PBZMC_BlockSound,'{"clip":"elytra-stop"}')end
 self.binding.log('MC elytra glide stopped: '..tostring(reason))
end
function M:damage(amount,kind,position,normal)
 if amount<=0 or self.binding.mc_creative then return end
 if not self.damage_adapter then self.damage_adapter=require('host.pbz.tnt_damage').new(self.binding,self.binding.log)end
 local p=self.binding.actor
 local row={actor=p,id=self.binding.actor_id,player=true}
 self.report.last_damage=self.damage_adapter:hit(row,math.min(10000,amount*p.AttributeSetBase.Health_Max.CurrentValue/20),
  'elytra/'..self.report.starts..'/'..self.report.ticks,kind,position,normal)
end
function M:sweep(dt)
 local p=self.binding.actor;local start=vec(p:K2_GetActorLocation());local v=self.velocity
 local finish={X=start.X+v.X*dt,Y=start.Y+v.Y*dt,Z=start.Z+v.Z*dt};local hit={}
 self:move(finish,hit)
 local after=vec(p:K2_GetActorLocation())
 local dx,dy,dz=finish.X-after.X,finish.Y-after.Y,finish.Z-after.Z
 local collision=dx*dx+dy*dy+dz*dz>.01
 self.fall_distance=rules.limit_fall_distance(self.fall_distance,v.Z)
 if after.Z<start.Z then self.fall_distance=self.fall_distance+start.Z-after.Z end
 if not collision then return end
 local n=hit.ImpactNormal or hit.Normal
 if not n then self:stop('invalid-collision');return end
 local normal=vec(n)
 if normal.Z>.65 and v.Z<=0 then
  local distance=self.fall_distance
  local lift=self.binding.mc_wind_lift
  if lift then distance=math.min(distance,math.max(0,lift.z-after.Z));self.binding.mc_wind_lift=nil end
  local damage=math.max(0,math.ceil(distance/100-3))
  self:stop('landed',true);self:damage(damage,'fall',after,{X=0,Y=0,Z=-1});return
 end
 local dot=v.X*normal.X+v.Y*normal.Y+v.Z*normal.Z
 if dot<0 then v={X=v.X-dot*normal.X,Y=v.Y-dot*normal.Y,Z=v.Z-dot*normal.Z}end
 local before=math.sqrt(self.velocity.X^2+self.velocity.Y^2)
 self.velocity=v
 local collision_result=rules.collide(self.physics,{before_horizontal_speed=self.tick_before_speed or before},
  {velocity=v,horizontal_collision=math.abs(normal.Z)<.65,on_ground=false})
 if (collision_result.wall_damage or 0)>0 and self.damage_tick~=self.report.ticks then
  self.damage_tick=self.report.ticks;self:damage(collision_result.wall_damage,'fly_into_wall',after,normal)
 end
 -- Finish the remaining tangent movement with a second native sweep. A
 -- corner may block it; no recursive push-out or unswept correction occurs.
 local distance=math.sqrt((after.X-start.X)^2+(after.Y-start.Y)^2+(after.Z-start.Z)^2)
 local speed=math.sqrt((finish.X-start.X)^2+(finish.Y-start.Y)^2+(finish.Z-start.Z)^2)
 local remaining=dt*(1-math.min(1,distance/math.max(.001,speed)))
 if remaining>0 then self:move({X=after.X+v.X*remaining,Y=after.Y+v.Y*remaining,Z=after.Z+v.Z*remaining},{})end
 self.report.collisions=(self.report.collisions or 0)+1
end
function M:move(finish,hit)
 for attempt=1,8 do
  for k in pairs(hit)do hit[k]=nil end
  self.binding.actor:K2_SetActorLocation(finish,true,hit,false);self.report.sweeps=self.report.sweeps+1
  if not hit.Component then return end
  if not self.collision then self.collision=require('host.pbz.glide_collision').new(self.binding)end
  if attempt==8 or not self.collision:ignore(hit) then return end
  self.report.air_walls=(self.report.air_walls or 0)+1
 end
end
function M:tick(camera,reason)
 if not self.active then return end
 if not self.binding:is_current()or not id.matches(self.pc,self.pc_id)then self:stop('owner-replaced');return end
 if not id.matches(self.binding.actor.CharacterMovement,self.movement_id)then self:stop('movement-replaced');return end
 local p=self.binding.actor;local now=clock(p);local elapsed=math.max(0,now-self.last);self.last=now
 self.pending=self.pending+elapsed
 if self.pending>2 then self:stop('clock-interruption');return end
 local dt=math.min(.2,self.pending);self.pending=self.pending-dt;self.report.backlog=self.pending
 local fluid=self.binding.mc_fluid_contact
 local in_fluid=fluid and fluid.active~=false and fluid.kind and (not fluid.valid_until or now<=fluid.valid_until)
 if in_fluid then self:reset_fall()end
 if reason or p.AttributeSetBase.Health.CurrentValue<=0 or not equipped(self.binding)or self.binding.mc_boat_riding
   or in_fluid then
  self:stop(reason and 'native-takeover'or 'equipment-or-environment');return
 end
 if self.movement.MovementMode~=0 then self:stop('native-movement-takeover');return end
 if self.anim_id and id.matches(self.anim,self.anim_id)then self.anim:SetRootMotionMode(1)end
 if camera.focused and not camera.inventory then self.frame=self.input:frame();self.pc:SetControlRotation(self.frame.rotation)end
 local r=self.frame.rotation
 p:K2_SetActorRotation({Pitch=0,Yaw=r.Yaw,Roll=0},false)
 local look=rules.look_from_angles(r.Yaw,r.Pitch)
 while dt>1e-7 and self.active do
  if self.accumulator<=1e-7 then
   self.physics.vx,self.physics.vy,self.physics.vz=self.velocity.X,self.velocity.Y,self.velocity.Z
   local next=rules.step(self.physics,{look=look,pitch=r.Pitch},{})
   self.velocity=next.velocity;self.tick_before_speed=next.before_horizontal_speed
   local rockets=self.binding.mc_fireworks
   if rockets then self.velocity=rockets:boost_tick(self.velocity,look)end
   self.physics.vx,self.physics.vy,self.physics.vz=self.velocity.X,self.velocity.Y,self.velocity.Z
   self.report.ticks=self.report.ticks+1;self.accumulator=.05
  end
  local step=math.min(dt,self.accumulator);self:sweep(step);dt=dt-step;self.accumulator=self.accumulator-step
 end
 self.report.velocity=self.velocity;self.report.fall_distance=self.fall_distance
 if self.active and now>=(self.next_sound or 0)then
  self.next_sound=now+.1
  local ticks=self.physics.ticks;local v=self.velocity
  local volume=math.min(1,(v.X^2+v.Y^2+v.Z^2)/16000000)
  volume=volume*math.max(0,math.min(1,(ticks-20)/20))
  local raw,why=PBZMC_BlockSound(require('dkjson').encode({clip='item_elytra_elytra_loop',sustain=true,
    gain=volume*.6,pitch=volume>.8 and 1+volume-.8 or 1}))
  if not raw then self.report.audio_error=tostring(why)end
 end
end
function M:close()
 if self.closed then return end
 self:stop('closed');if self.damage_adapter then self.damage_adapter:close()end;self.closed=true
end
return M
