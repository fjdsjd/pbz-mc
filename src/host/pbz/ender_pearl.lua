-- Real private MC item mesh + swept flight. No input injection or native save.
local rules=require('rules.ender_pearl')
local identity=require('host.pbz.object_identity')
local valid=require('host.pbz.appearance').valid
local bundle=require('host.pbz.mesh_bundle')
local M={};M.__index=M
local function clock(pawn)return StaticFindObject('/Script/Engine.Default__GameplayStatics'):GetTimeSeconds(pawn)end
local function vec(p)return {X=p.X,Y=p.Y,Z=p.Z}end
local function transform()return {Rotation={X=0,Y=0,Z=0,W=1},Translation={X=0,Y=0,Z=0},Scale3D={X=1,Y=1,Z=1}}end
function M.new(owner)
  local self=setmetatable({owner=owner,binding=owner.binding,pc=owner.pc,projectiles={},report={fired=0,teleported=0,rejected=0}},M)
  local catalog=require('host.pbz.item_models').new(self.binding.item_models_root)
  self.model=assert(catalog:resolve({content_id=rules.id},'ground',{},6.25))
  self.pose=require('presentation.item_model_transform').solve(self.model.display,'ground',6.25)
  self.collision=require('host.pbz.pearl_collision').new(self.binding)
  return self
end
function M:draw(p)
  local r=self.pc.PlayerCameraManager.CameraCachePrivate.POV.Rotation
  p.mesh:K2_SetWorldLocationAndRotation(p.position,{Pitch=-r.Pitch,Yaw=r.Yaw+180,Roll=0},false,{},true)
end
function M:destroy(p)
  if identity.matches(p.actor,p.identity) then p.actor:K2_DestroyActor() end
end
function M:_throw(record)
  local status=self.binding.mc_status_service
  if self.closed or not self.binding:is_current() or not status or not status:current() then return false,'fail' end
  if #self.projectiles>=rules.max_projectiles or require('rules.status_effects').remaining(status.value,rules.id)>0 then return false,'fail' end
  local pawn=self.binding.actor
  if pawn.AttributeSetBase.Health.CurrentValue<=0 then return false,'fail' end
  local origin,direction=self.owner:aim()
  local actor=pawn:GetWorld():SpawnActor(StaticFindObject('/Script/Engine.Actor'),origin,{Pitch=0,Yaw=0,Roll=0})
  assert(valid(actor),'pearl-actor-create-failed')
  local p={actor=actor,identity=identity.capture(actor),position=vec(origin),age=0,accumulator=0,action_id=record.action_id,hand=record.hand}
  local ok,why=pcall(function()
    p.mesh=actor:AddComponentByClass(StaticFindObject('/Script/ProceduralMeshComponent.ProceduralMeshComponent'),true,transform(),false)
    assert(valid(p.mesh),'pearl-mesh-create-failed');p.mesh:SetCollisionEnabled(0);p.mesh:SetCastShadow(false)
    p.mesh:SetMaterial(0,self.binding.material);bundle.apply(p.mesh,self.model.part);p.mesh:SetWorldScale3D(self.pose.scale)
    local inherited=self.binding.mc_gliding and self.binding.mc_gliding.velocity or pawn:GetVelocity()
    p.velocity={X=direction.X*rules.speed+inherited.X,Y=direction.Y*rules.speed+inherited.Y,
      Z=direction.Z*rules.speed+((self.binding.mc_gliding or pawn.CharacterMovement.MovementMode==3) and inherited.Z or 0)}
    self:draw(p)
    local committed,reason=status:pearl_cooldown(record);assert(committed,reason)
  end)
  if not ok then self:destroy(p);error(why) end
  self.projectiles[#self.projectiles+1]=p;self.report.fired=self.report.fired+1
  self.report.last_throw={id=record.action_id,hand=record.hand,count=record.equipment[record.hand].count,cooldown_ticks=rules.cooldown}
  self.owner:sound('pearl_throw',origin)
  self.owner.log('MC pearl fired id='..record.action_id..' hand='..record.hand..' cooldown=20t count-unchanged')
  if not self.timer then
    self.last=clock(pawn)
    self.timer=LoopInGameThreadAfterFrames(1,function()
      local success,err=pcall(self.tick,self)
      if not success then self.report.error=tostring(err);self.owner.log('MC pearl unavailable: '..tostring(err));self:close() end
    end)
  end
  return true,'success'
end
function M:throw(record)
  local ok,result,outcome=pcall(self._throw,self,record)
  if not ok then self.report.error=tostring(result);self.owner.log('MC pearl throw rejected: '..tostring(result));return false,'fail' end
  return result,outcome
end
function M:occupied(position,radius,half)
  return self.collision:occupied(position,radius,half)
end
function M:impact(p,hit)
  local pawn=self.binding.actor;local camera=require('host.pbz.first_person_camera').get()
  local fx_ok,fx_error=pcall(function()
    if not self.fx then self.fx=require('host.pbz.portal_particles').new(self.binding,self.pc) end
    self.fx:burst(hit.ImpactPoint)
  end)
  if not fx_ok then self.report.fx_error=tostring(fx_error) end
  local destination,why
  if camera and camera:native_takeover() then why='native-camera-takeover'
  else
    destination,why=rules.landing(hit,pawn.CapsuleComponent:GetScaledCapsuleRadius(),pawn.CapsuleComponent:GetScaledCapsuleHalfHeight(),
      function(a,b)return self.owner:trace(a,b,.1)end,
      function(pos,r,h)return self:occupied(pos,r,h)end)
  end
  local before=vec(pawn:K2_GetActorLocation())
  local result={id=p.action_id,hit=vec(hit.ImpactPoint),before=before,destination=destination,reason=why}
  local moved=destination and pawn:K2_SetActorLocation(destination,false,{},true)
  if moved and self:occupied(pawn:K2_GetActorLocation(),pawn.CapsuleComponent:GetScaledCapsuleRadius(),pawn.CapsuleComponent:GetScaledCapsuleHalfHeight())then
    assert(pawn:K2_SetActorLocation(before,false,{},true),'pearl-postcheck-rollback-failed')
    moved=false;why='occupied-after-teleport'
  end
  if moved and self.binding.mc_boat_riding then
    local boats=require('host.pbz.boat_service').get(self.binding)
    local released,reason
    if boats then released,reason=boats:leave_for_teleport() end
    if not released then
      assert(pawn:K2_SetActorLocation(before,false,{},true),'pearl-seat-rollback-failed')
      moved=false;why=reason or 'boat-seat-release-failed'
    end
  end
  if moved then
    pawn.CharacterMovement:StopMovementImmediately();pawn.CharacterMovement:SetMovementMode(3,0);self.owner.fall_state=nil
    require('host.pbz.item_interface').reset_fall_after_teleport(self.binding)
    self.report.teleported=self.report.teleported+1;result.after=vec(pawn:K2_GetActorLocation());result.health_cost=0
    self.owner:sound('pearl_teleport',result.after)
    self.owner.log('MC pearl teleported id='..p.action_id..' health-cost=0 air-walls-skipped='..self.collision.report.air_hits)
  else
    result.reason=why or 'native-teleport-rejected';self.report.rejected=self.report.rejected+1
    self.owner.log('MC pearl landing rejected: '..result.reason)
  end
  self.report.last_impact=result
end
function M:tick()
  local pawn=self.binding.actor
  if not self.binding:is_current() or pawn.AttributeSetBase.Health.CurrentValue<=0 then self:close();return end
  local now=clock(pawn);local dt=math.max(0,math.min(.1,now-self.last));self.last=now
  for i=#self.projectiles,1,-1 do
    local p=self.projectiles[i];p.age=p.age+dt
    if p.age>rules.lifetime or not identity.matches(p.actor,p.identity) then self:destroy(p);table.remove(self.projectiles,i)
    else
      local hit=rules.advance(p,dt,function(a,b,r)return self.collision:trace(a,b,r,p.actor)end)
      if hit then
        table.remove(self.projectiles,i);self:destroy(p);self:impact(p,hit)
        if self.closed then return end
      else self:draw(p) end
    end
  end
  if #self.projectiles==0 and self.timer then CancelDelayedAction(self.timer);self.timer=nil end
end
function M:close()
  self.closed=true
  if self.timer then CancelDelayedAction(self.timer);self.timer=nil end
  for _,p in ipairs(self.projectiles) do self:destroy(p) end;self.projectiles={}
  if self.fx then self.fx:close() end
end
return M
