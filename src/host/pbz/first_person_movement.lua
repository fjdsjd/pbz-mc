-- A reversible MC-only movement lease. CharacterMovement retains collision,
-- gravity, stepping and native health; PBZ equipment never acquires this lease.
local id=require('host.pbz.object_identity')
local valid=require('host.pbz.appearance').valid
local fluid_flow=require('rules.fluid_flow')
local M={};M.__index=M
local settings={MaxWalkSpeed=431.7,GravityScale=3200/980,MaxAcceleration=6000,
  GroundFriction=12.105,bUseSeparateBrakingFriction=false,BrakingFrictionFactor=1,BrakingDecelerationWalking=0,AirControl=.2,
  bOrientRotationToMovement=false,bUseControllerDesiredRotation=false,
  bCanWalkOffLedges=true,bCanWalkOffLedgesWhenCrouching=true,bUseFlatBaseForFloorChecks=true}
local checked
local function check_schema()
  if checked then return end
  local specs={
    ['/Script/Engine.Pawn:AddMovementInput']={75629570,'WorldDirection','ScaleValue','bForce'},
    ['/Script/Engine.Controller:SetControlRotation']={79823874,'NewRotation'},
    ['/Script/Engine.Actor:K2_SetActorRotation']={75629571,'NewRotation','bTeleportPhysics','ReturnValue'},
    ['/Script/Engine.Character:LaunchCharacter']={75629570,'LaunchVelocity','bXYOverride','bZOverride'},
    ['/Script/Engine.AnimInstance:SetRootMotionMode']={67240963,'Value'},
    ['/Script/Engine.PlayerCameraManager:StopAllCameraShakes']={67240962,'bImmediately'},
    ['/Script/Engine.PlayerController:SetMouseLocation']={67240963,'X','Y'},
  }
  for path,spec in pairs(specs) do
    local f=StaticFindObject(path);assert(valid(f) and f:GetFunctionFlags()==spec[1],'mc-movement-schema:'..path)
    local n=1;f:ForEachProperty(function(p) n=n+1;assert(p:GetFName():ToString()==spec[n],'mc-movement-field:'..path) end)
    assert(n==#spec,'mc-movement-fields:'..path)
  end
  checked=true
end
function M.new(binding,pc)
  check_schema()
  assert(binding:is_current() and id.matches(pc.Pawn,binding.actor_id),'mc-movement-owner')
  local self=setmetatable({binding=binding,pc=pc,pc_id=id.capture(pc),before={},written={},ticks=0,
    input=require('input.first_person_controls').new(pc.ControlRotation),jump_count=0,next_jump=0},M)
  assert(not binding.mc_movement_owner or binding.mc_movement_owner.closed,'mc-movement-already-owned')
  self.movement=binding.actor.CharacterMovement
  assert(valid(self.movement),'mc-character-movement-required');self.movement_id=id.capture(self.movement)
  binding.mc_movement_owner=self
  local ok,why=pcall(function()
    for name,value in pairs(settings) do self.before[name]=self.movement[name];self.movement[name]=value;self.written[name]=self.movement[name] end
    self.use_yaw=binding.actor.bUseControllerRotationYaw;binding.actor.bUseControllerRotationYaw=false
    pc:SetIgnoreLookInput(true);self.look=true
    pc:SetIgnoreMoveInput(true);self.move=true
    -- A newly boarded PBZ player already has the passenger's temporary root
    -- mode. Capture the real mode only after dismount; do not snapshot another
    -- lease's IgnoreRootMotion value as PBZ's permanent restoration target.
    if not binding.mc_boat_riding then self:set_anim() end
    self.vitals=assert(require('host.pbz.player_vitals').new(binding,pc,1))
  end)
  if not ok then self:close();error(why) end
  return self
end
function M:set_anim()
  local anim=self.binding.source:GetAnimInstance()
  if self.anim and not id.matches(anim,self.anim_id) then self:restore_anim() end
  if valid(anim) and not self.anim then self.anim=anim;self.anim_id=id.capture(anim);self.root_mode=anim.RootMotionMode end
  if self.anim then self.anim:SetRootMotionMode(1) end
end
function M:restore_anim()
  if valid(self.anim) and id.matches(self.anim,self.anim_id) and self.anim.RootMotionMode==1 then self.anim:SetRootMotionMode(self.root_mode) end
  self.anim=nil
end
function M:input_batch(batch,allowed)
  assert(batch.first_person_controls==true,'native-first-person-input-update-required')
  self.focused=allowed and batch.latest.focused and not batch.overflow
  local x,y=self.input:sample_batch(batch,self.focused)
  if x then self.pc:SetMouseLocation(x,y) end
end
function M:tick()
  assert(not self.closed and self.binding:is_current() and id.matches(self.pc,self.pc_id)
    and id.matches(self.movement,self.movement_id),'mc-movement-stale')
  self.ticks=self.ticks+1
  if self.ticks%10==1 then
    local hp,why=self.vitals:read(1);assert(hp,why);self.hp=hp.hp
    local ok,speed=pcall(function() return self.binding.actor.AttributeSetBase.SprintSpeed.CurrentValue end)
    self.sprint_speed=ok and type(speed)=='number' and speed>431.7 and speed<=2000 and speed or 750
  end
  if not self.focused or not self.hp or self.hp<=0 then return end
  local frame=self.input:frame();self.frame=frame
  if self.binding.mc_boat_riding then
    -- The boat owns translation and body yaw. Mouse look remains live without
    -- re-enabling CharacterMovement, jumping or overwriting the passenger pose.
    self.pc:SetControlRotation(frame.rotation)
    self.movement:StopMovementImmediately()
    return
  end
  local now=StaticFindObject('/Script/Engine.Default__GameplayStatics'):GetTimeSeconds(self.binding.actor)
  local dt=self.motion_time and math.max(.001,math.min(.1,now-self.motion_time)) or 1/60;self.motion_time=now
  -- PBZ updates acceleration/friction continuously from native locomotion
  -- curves. A one-time lease assignment is overwritten on the next frame.
  -- MC ordinary ground retains .6*.91 of horizontal velocity per 20 Hz tick.
  -- Convert this to CharacterMovement's per-step steering friction.
  for name,value in pairs(settings) do
    if name~='MaxWalkSpeed' and name~='bCanWalkOffLedges' and name~='bCanWalkOffLedgesWhenCrouching' then
      if name=='GroundFriction' then value=(1-.546^(dt*20))/dt end
      self.movement[name]=value;self.written[name]=self.movement[name]
    end
  end
  self:set_anim()
  -- PBZ hit reactions may gate the movement component independently of its
  -- controller flags. MC keeps damage/velocity but does not inherit this gate.
  if self.binding.actor.DisableMovement then self.binding.actor:SetDisableMovement(false) end
  if self.movement.MovementMode==0 then self.movement:SetMovementMode(3,0) end
  self.pc:SetControlRotation(frame.rotation)
  self.binding.actor:K2_SetActorRotation({Pitch=0,Yaw=frame.rotation.Yaw,Roll=0},false)
  local speed=frame.sneak and 431.7*.3 or frame.sprint and self.sprint_speed or 431.7
  local fluid=self.binding.mc_fluid_contact
  if fluid and (fluid.active==false or fluid.valid_until and now>fluid.valid_until)then fluid=nil end
  if fluid and fluid.kind then
    local water=fluid.kind=='water'or fluid.kind=='pbzmc:water'
    speed=water and (frame.sprint and 290 or 196.7)or 100
    self.movement.GravityScale=80/980;self.written.GravityScale=self.movement.GravityScale
    self.movement.MaxAcceleration=800;self.written.MaxAcceleration=self.movement.MaxAcceleration
    self.movement.AirControl=1;self.written.AirControl=self.movement.AirControl
    -- MC travel drag is applied at 20 Hz, with native swept CharacterMovement
    -- preserving walls/steps. Held jump adds buoyancy; Shift sinks.
    if now>=(self.next_fluid or 0)then
      local ticks=self.last_fluid and math.max(0,math.min(2,(now-self.last_fluid)*20))or 1
      local velocity=self.binding.actor:GetVelocity();local drag=(water and (frame.sprint and .9 or .8)or .5)^ticks
      local impulse=fluid_flow.impulse(fluid.flow,fluid.kind,velocity,true)
      local vz=(velocity.Z+impulse.Z*ticks)*(fluid.vertical_drag or (water and .8 or .5))^ticks
        +(frame.jump_held and 80*ticks or frame.sneak and -80*ticks or 0)
      self.binding.actor:LaunchCharacter({X=(velocity.X+impulse.X*ticks)*drag,
        Y=(velocity.Y+impulse.Y*ticks)*drag,Z=vz},true,true)
      self.last_fluid=now;self.next_fluid=now+.05
    end
  else self.last_fluid=nil;self.next_fluid=nil end
  local action=require('host.pbz.item_interface').combat_presentation()
  if action and action.shield_active then
    self.input.sprinting=false;frame.sprint=false
    speed=(fluid and fluid.kind)and speed*.2 or (frame.sneak and 431.7*.3 or 431.7)*.2
  end
  self.movement.MaxWalkSpeed=speed;self.written.MaxWalkSpeed=self.movement.MaxWalkSpeed
  -- Minecraft clips unsupported walking while sneaking. Let CharacterMovement
  -- perform this against real floors, including native terrain and MC blocks,
  -- so support, sliding along an edge and stepping stay in the physics update.
  -- These flags do not hold an airborne pawn up or prevent a deliberate jump.
  for _,name in ipairs({'bCanWalkOffLedges','bCanWalkOffLedgesWhenCrouching'}) do
    self.movement[name]=not frame.sneak;self.written[name]=self.movement[name]
  end
  self.binding.actor:AddMovementInput(frame.direction,1,true)
  if not frame.jump_held then self.next_jump=0 end
  if not (fluid and fluid.kind)and (frame.jump or frame.jump_held) and (self.movement.MovementMode==1 or self.movement.MovementMode==2) then
    -- LivingEntity's held-jump delay is ten 20 Hz ticks; release clears it.
    -- Grounding remains native, with no repeated launch while airborne.
    if now>=self.next_jump then
      self.binding.actor:LaunchCharacter({X=0,Y=0,Z=840},false,true)
      self.next_jump=now+.5;self.jump_count=self.jump_count+1
    end
  end
  self.pc.PlayerCameraManager:StopAllCameraShakes(true)
end
function M:close()
  if self.closed then return end
  self:restore_anim()
  if valid(self.movement) and id.matches(self.movement,self.movement_id) then
    for name,value in pairs(self.before) do if self.movement[name]==self.written[name] then self.movement[name]=value end end
  end
  if self.binding:is_current() and self.use_yaw~=nil then self.binding.actor.bUseControllerRotationYaw=self.use_yaw end
  if valid(self.pc) and id.matches(self.pc,self.pc_id) then
    if self.look then self.pc:SetIgnoreLookInput(false);self.look=false end
    if self.move then self.pc:SetIgnoreMoveInput(false);self.move=false end
  end
  if self.binding.mc_movement_owner==self then self.binding.mc_movement_owner=nil end
  self.input:reset();self.closed=true
end
return M
