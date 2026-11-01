-- A reversible boat seat lease; native health/damage/collision remain enabled.
-- StopLogic/RestartLogic is the API actually exposed by this PBZ build. Restart
-- starts the brain again; it does not resume the previous behavior-tree stack.
-- A cancelled montage and old velocity are deliberately never replayed.
local identity=require('host.pbz.object_identity')
local valid=require('host.pbz.appearance').valid
local M={};local Lease={};Lease.__index=Lease
local checked,active={},{}
local function finite(v)return type(v)=='number' and v==v and v~=math.huge and v~=-math.huge end
local function same(o,id)return valid(o) and identity.matches(o,id) end
local function thread()assert(type(IsInGameThread)=='function' and IsInGameThread(),'boat-passenger-game-thread-required')end

-- Raw flags, types and byte offsets from boat-schema-20261101.json and the
-- previously captured minecraft-movement-metadata-20261031.json. Reflection
-- callbacks must return nil to continue; UE4SS treats true as an early stop.
local functions={
  ['/Script/AIModule.BrainComponent:StopLogic']={67240962,{'Reason','StrProperty',0}},
  ['/Script/AIModule.BrainComponent:RestartLogic']={67240962},
  ['/Script/AIModule.BrainComponent:IsPaused']={1409418242,{'ReturnValue','BoolProperty',0}},
  ['/Script/AIModule.BrainComponent:IsRunning']={1409418242,{'ReturnValue','BoolProperty',0}},
  ['/Script/Engine.AnimInstance:Montage_Stop']={67240963,{'InBlendOutTime','FloatProperty',0},{'Montage','ObjectProperty',8}},
  ['/Script/Engine.AnimInstance:SetRootMotionMode']={67240963,{'Value','ByteProperty',0}},
  ['/Script/Engine.SkeletalMeshComponent:GetAnimInstance']={1409418243,{'ReturnValue','ObjectProperty',0}},
  ['/Script/Engine.CapsuleComponent:GetScaledCapsuleHalfHeight']={1409418241,{'ReturnValue','FloatProperty',0}},
  ['/Script/Engine.CharacterMovementComponent:SetMovementMode']={67240962,
    {'NewMovementMode','ByteProperty',0},{'NewCustomMode','ByteProperty',1}},
  ['/Script/Engine.MovementComponent:StopMovementImmediately']={67240960},
  ['/Script/Engine.Actor:K2_SetActorLocationAndRotation']={79823875,
    {'NewLocation','StructProperty',0,'/Script/CoreUObject.Vector'},
    {'NewRotation','StructProperty',24,'/Script/CoreUObject.Rotator'},
    {'bSweep','BoolProperty',48},{'SweepHitResult','StructProperty',56,'/Script/Engine.HitResult'},
    {'bTeleport','BoolProperty',312},{'ReturnValue','BoolProperty',313}},
}
local fields={
  ['/Script/Engine.Character']={Mesh={'ObjectProperty',816},CharacterMovement={'ObjectProperty',824},CapsuleComponent={'ObjectProperty',832}},
  ['/Script/Engine.Pawn']={Controller={'ObjectProperty',736}},
  ['/Script/Engine.Actor']={CustomTimeDilation={'FloatProperty',104}},
  ['/Script/AIModule.AIController']={BrainComponent={'ObjectProperty',912}},
  ['/Script/Engine.SkeletalMeshComponent']={bPauseAnims={'BoolProperty',2720}},
  ['/Script/Engine.AnimInstance']={RootMotionMode={'ByteProperty',48}},
  ['/Script/Engine.CharacterMovementComponent']={MovementMode={'ByteProperty',577},CustomMovementMode={'ByteProperty',578}},
}
local function declaration(path,spec,is_function)
  local object=StaticFindObject(path)
  assert(valid(object),'boat-passenger-schema-unavailable:'..path)
  if same(object,checked[path]) then return object end
  assert(object:GetFullName()==(is_function and 'Function ' or 'Class ')..path,'boat-passenger-schema-owner:'..path)
  if is_function then
    assert(object:GetFunctionFlags()==spec[1],'boat-passenger-schema-flags:'..path)
    local count=0
    object:ForEachProperty(function(p)
      count=count+1;local e=spec[count+1]
      assert(e and p:GetFullName()==e[2]..' '..path..':'..e[1] and p:GetOffset_Internal()==e[3],
        'boat-passenger-schema-parameter:'..path)
      if e[4] then assert(p:GetStruct():GetFullName()=='ScriptStruct '..e[4],'boat-passenger-schema-struct:'..path) end
      return nil
    end)
    assert(count==#spec-1,'boat-passenger-schema-arity:'..path)
  else
    local seen={}
    object:ForEachProperty(function(p)
      local name=p:GetFName():ToString();local e=spec[name]
      if e then
        assert(not seen[name] and p:GetFullName()==e[1]..' '..path..':'..name and p:GetOffset_Internal()==e[2],
          'boat-passenger-schema-property:'..path..':'..name)
        seen[name]=true
      end
      return nil
    end)
    for name in pairs(spec) do assert(seen[name],'boat-passenger-schema-missing:'..path..':'..name) end
  end
  checked[path]=identity.capture(object);return object
end
local function schemas(kind)
  for path,spec in pairs(functions) do
    if kind=='mob' or not path:find('/Script/AIModule.',1,true) then declaration(path,spec,true) end
  end
  for path,spec in pairs(fields) do
    if kind=='mob' or path~='/Script/AIModule.AIController' and path~='/Script/Engine.Pawn' and path~='/Script/Engine.Actor' then
      declaration(path,spec,false)
    end
  end
end
local function capture(object,label)
  assert(valid(object),'boat-passenger-invalid-'..label);return identity.capture(object)
end
local function component(object,owner_id,label)
  local id=capture(object,label)
  assert(same(object:GetOuter(),owner_id),'boat-passenger-owner-'..label)
  return id
end
local function owned(object,id,owner_id)
  return same(object,id) and same(object:GetOuter(),owner_id)
end
local function health(self)
  local ok,value=pcall(function()
    if not same(self.actor,self.id) then return nil end
    return self.actor.AttributeSetBase.Health.CurrentValue
  end)
  return ok and finite(value) and value or nil
end
local function alive_now(self)local hp=health(self);return hp~=nil and hp>0 end
function Lease:is_current()
  if self.closed or self.releasing then return false end
  local ok,current=pcall(function()
    if not same(self.actor,self.id) or not same(self.actor:GetWorld(),self.world_id)
      or not owned(self.movement,self.movement_id,self.id) or not same(self.actor.CharacterMovement,self.movement_id)
      or not owned(self.mesh,self.mesh_id,self.id) or not same(self.actor.Mesh,self.mesh_id)
      or not owned(self.anim,self.anim_id,self.mesh_id) or not same(self.mesh:GetAnimInstance(),self.anim_id)
      or not owned(self.capsule,self.capsule_id,self.id) or not same(self.actor.CapsuleComponent,self.capsule_id) then return false end
    if self.controller and (not same(self.actor.Controller,self.controller_id)
      or not same(self.controller,self.controller_id) or not same(self.controller.BrainComponent,self.brain_id)
      or not owned(self.brain,self.brain_id,self.controller_id)) then return false end
    return true
  end)
  return ok and current or false
end
local function change(self,key,object,field,value)
  if object[field]==value then return end
  -- Arm rollback before writing, including wrappers that throw after applying.
  self.written[key]=value;object[field]=value
  assert(object[field]==value,'boat-passenger-write-rejected:'..key)
end
local function root(self)
  if self.anim.RootMotionMode==1 then return end
  self.written.root=1;self.anim:SetRootMotionMode(1)
  assert(self.anim.RootMotionMode==1,'boat-passenger-root-mode-rejected')
end
local function stop_movement(self,validated)
  if not validated then
    assert(self:is_current(),'boat-passenger-stale-before-stop-movement')
    assert(alive_now(self),'boat-passenger-dead-before-stop-movement')
  end
  local velocity=self.movement.Velocity
  if not velocity or velocity.X~=0 or velocity.Y~=0 or velocity.Z~=0 then
    self.movement:StopMovementImmediately()
    assert(self:is_current(),'boat-passenger-stale-after-stop-movement')
    assert(alive_now(self),'boat-passenger-dead-after-stop-movement')
  end
  if self.movement.MovementMode~=0 or self.movement.CustomMovementMode~=0 then
    self.written.movement={pending=true};self.movement:SetMovementMode(0,0)
    assert(self.movement.MovementMode==0 and self.movement.CustomMovementMode==0,'boat-passenger-move-mode-rejected')
    self.written.movement.pending=false
    assert(self:is_current(),'boat-passenger-stale-after-move-mode')
    assert(alive_now(self),'boat-passenger-dead-after-move-mode')
  end
end

-- Cleanup is intentionally independent of the player binding or current seat.
-- Each restoration is isolated so one failed wrapper cannot strand the other
-- owned fields. A failed restoration remains retryable through release().
function Lease:release(alive)
  if self.closed then return true end
  local game_ok,game_error=pcall(thread);if not game_ok then return false,tostring(game_error) end
  self.releasing=true
  if alive==false then self.dead=true end
  alive=alive==true and not self.dead
  local function can_resume()
    -- A native restoration may synchronously dispatch death/overlap events.
    -- Do not reuse the caller's earlier health sample across those callbacks.
    local hp=health(self)
    if hp and hp<=0 then self.dead=true;alive=false end
    return alive
  end
  local errors={}
  local function attempt(key,action)
    if self.written[key]==nil then return end
    local ok,err=pcall(action)
    if ok then self.written[key]=nil else errors[#errors+1]=tostring(err) end
  end
  local function actor_current()
    local ok,current=pcall(same,self.actor,self.id);return ok and current or false
  end
  attempt('time',function()
    if actor_current() and self.actor.CustomTimeDilation==self.written.time then
      self.actor.CustomTimeDilation=self.before.time
      assert(self.actor.CustomTimeDilation==self.before.time,'boat-passenger-time-restore-rejected')
    end
  end)
  attempt('paused',function()
    if actor_current() and owned(self.mesh,self.mesh_id,self.id) and self.mesh.bPauseAnims==self.written.paused then
      self.mesh.bPauseAnims=self.before.paused
      assert(self.mesh.bPauseAnims==self.before.paused,'boat-passenger-animation-restore-rejected')
    end
  end)
  attempt('root',function()
    if actor_current() and owned(self.mesh,self.mesh_id,self.id) and owned(self.anim,self.anim_id,self.mesh_id)
      and self.anim.RootMotionMode==self.written.root then
      self.anim:SetRootMotionMode(self.before.root)
      assert(self.anim.RootMotionMode==self.before.root,'boat-passenger-root-restore-rejected')
    end
  end)
  attempt('movement',function()
    local mode_ok=owned(self.movement,self.movement_id,self.id) and
      (self.movement.MovementMode==0 and self.movement.CustomMovementMode==0
        or self.written.movement.pending and
          (self.movement.MovementMode==0 or self.movement.MovementMode==self.before.mode) and
          (self.movement.CustomMovementMode==0 or self.movement.CustomMovementMode==self.before.custom))
    if actor_current() and can_resume() and same(self.actor:GetWorld(),self.world_id)
      and mode_ok then
      self.movement:SetMovementMode(self.before.mode,self.before.custom)
      assert(self.movement.MovementMode==self.before.mode and self.movement.CustomMovementMode==self.before.custom,
        'boat-passenger-movement-restore-rejected')
    end
  end)
  -- Restart last, after the animation clock and locomotion are usable again.
  -- Never resume another owner's pause, a brain already restarted externally,
  -- a changed controller, a dead actor, or an actor which moved to another world.
  attempt('brain',function()
    if #errors>0 then error('boat-passenger-cleanup-pending-before-brain') end
    if actor_current() and can_resume() and same(self.actor:GetWorld(),self.world_id)
      and same(self.actor.Controller,self.controller_id) and same(self.controller,self.controller_id)
      and same(self.controller.BrainComponent,self.brain_id) and owned(self.brain,self.brain_id,self.controller_id)
      and self.brain:IsRunning()==false and self.brain:IsPaused()==false then self.brain:RestartLogic() end
  end)
  if #errors>0 then return false,table.concat(errors,'; ') end
  self.closed=true;if active[self.key]==self then active[self.key]=nil end
  return true
end

function Lease:pin(position,yaw,now)
  if self.closed then return false,'boat-passenger-closed' end
  if self.releasing then return false,'boat-passenger-cleanup-pending' end
  local ok,why=pcall(function()
    thread();assert(self:is_current(),'boat-passenger-stale')
    assert(type(position)=='table' and finite(position.X) and finite(position.Y) and finite(position.Z)
      and finite(yaw) and finite(now) and now>=self.last,'boat-passenger-invalid-seat')
    self.last=now
    -- Native landing/teleport code can change the movement mode while this
    -- seat is still owned. Reassert None without replacing the original
    -- acquisition snapshot; normal exit still restores only our current write.
    assert(alive_now(self),'boat-passenger-dead-before-stop-movement')
    stop_movement(self,true)
    local unchanged=self.seat and self.seat.X==position.X and self.seat.Y==position.Y and self.seat.Z==position.Z and self.seat.yaw==yaw
    if unchanged then
      -- Compare the real pose too: native knockback/teleport must wake the
      -- seat even if the boat itself did not move. No cached ownership bypass.
      local p=self.actor:K2_GetActorLocation();local r=self.actor:K2_GetActorRotation()
      unchanged=math.abs(p.X-position.X)+math.abs(p.Y-position.Y)+math.abs(p.Z-position.Z)<.0001
        and math.abs((r.Yaw-yaw+180)%360-180)<.0001 and math.abs(r.Pitch)+math.abs(r.Roll)<.0001
    end
    if not unchanged then
      assert(self.actor:K2_SetActorLocationAndRotation({X=position.X,Y=position.Y,Z=position.Z},
        {Pitch=0,Yaw=yaw,Roll=0},false,{},true)==true,'boat-passenger-seat-rejected')
      assert(self:is_current(),'boat-passenger-stale-after-seat')
      assert(alive_now(self),'boat-passenger-dead-after-seat')
      self.seat={X=position.X,Y=position.Y,Z=position.Z,yaw=yaw}
    end
    if not self.frozen and now-self.started>=.35 then
      change(self,'paused',self.mesh,'bPauseAnims',true)
      assert(self:is_current(),'boat-passenger-stale-after-pause')
      if self.kind=='mob' then change(self,'time',self.actor,'CustomTimeDilation',0) end
      self.frozen=true
    end
  end)
  if ok then return true end
  local released,err=self:release(alive_now(self))
  return false,tostring(why)..(released and '' or '; cleanup: '..tostring(err))
end

function M.acquire(actor,kind,now)
  local self
  local ok,why=pcall(function()
    thread();assert(kind=='mob' or kind=='player','boat-passenger-kind')
    assert(finite(now),'boat-passenger-invalid-time');schemas(kind)
    local id=capture(actor,'actor');local world_id=capture(actor:GetWorld(),'world')
    assert(actor:IsA(StaticFindObject('/Script/Engine.Character')),'boat-passenger-character-required')
    local key=tostring(id.address)..'\0'..id.name
    local prior=active[key]
    if prior and not prior.closed then error('boat-passenger-already-owned') end
    self=setmetatable({actor=actor,id=id,world_id=world_id,key=key,kind=kind,started=now,last=now,
      before={},written={}},Lease)
    self.movement=actor.CharacterMovement;self.movement_id=component(self.movement,id,'movement')
    self.mesh=actor.Mesh;self.mesh_id=component(self.mesh,id,'mesh')
    self.anim=self.mesh:GetAnimInstance();self.anim_id=component(self.anim,self.mesh_id,'anim')
    self.capsule=actor.CapsuleComponent;self.capsule_id=component(self.capsule,id,'capsule')
    self.capsuleHalfHeight=self.capsule:GetScaledCapsuleHalfHeight()
    assert(finite(self.capsuleHalfHeight) and self.capsuleHalfHeight>0,'boat-passenger-capsule-height')
    self.before.mode=self.movement.MovementMode;self.before.custom=self.movement.CustomMovementMode
    self.before.root=self.anim.RootMotionMode;self.before.paused=self.mesh.bPauseAnims
    assert(type(self.before.mode)=='number' and self.before.mode%1==0 and self.before.mode>=0 and self.before.mode<=6
      and type(self.before.custom)=='number' and self.before.custom%1==0 and self.before.custom>=0 and self.before.custom<=255
      and type(self.before.root)=='number' and self.before.root%1==0 and self.before.root>=0 and self.before.root<=3
      and type(self.before.paused)=='boolean','boat-passenger-invalid-snapshot')
    if kind=='mob' then
      self.before.time=actor.CustomTimeDilation
      assert(finite(self.before.time) and self.before.time>=0,'boat-passenger-invalid-time-dilation')
      self.controller=actor.Controller;self.controller_id=capture(self.controller,'controller')
      self.brain=self.controller.BrainComponent;self.brain_id=component(self.brain,self.controller_id,'brain')
      self.before.running=self.brain:IsRunning();self.before.brain_paused=self.brain:IsPaused()
      assert(type(self.before.running)=='boolean' and type(self.before.brain_paused)=='boolean','boat-passenger-invalid-brain-state')
    end
    assert(self:is_current(),'boat-passenger-stale-before-acquire')
    assert(alive_now(self),'boat-passenger-living-character-required');active[key]=self
    -- Invoke the ordinary wrapper with a real nil ObjectProperty. If this UE4SS
    -- build cannot marshal it, fail before touching AI/movement/time. Do not
    -- substitute an unverified null pointer or a per-monster animation asset.
    self.anim:Montage_Stop(.12,nil)
    assert(self:is_current(),'boat-passenger-stale-after-montage')
    if kind=='mob' and self.before.running and not self.before.brain_paused then
      self.written.brain=true;self.brain:StopLogic('PBZMC boat passenger')
      assert(self.brain:IsRunning()==false,'boat-passenger-brain-stop-rejected')
      assert(self:is_current(),'boat-passenger-stale-after-brain-stop')
    end
    root(self);assert(self:is_current(),'boat-passenger-stale-after-root-mode');stop_movement(self)
    assert(self:is_current(),'boat-passenger-stale-after-acquire')
    assert(alive_now(self),'boat-passenger-dead-during-acquire')
  end)
  if ok then return self end
  if self then
    local restored,restore_error=self:release(alive_now(self))
    if not restored then
      -- Keep the registered lease discoverable to the caller for cleanup retry;
      -- acquire never reports a usable seat after a partial failure.
      return nil,tostring(why)..'; cleanup: '..tostring(restore_error),self
    end
  end
  return nil,tostring(why)
end
return M
