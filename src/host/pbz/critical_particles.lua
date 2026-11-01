local valid=require('host.pbz.appearance').valid
local identity=require('host.pbz.object_identity')
local rules=require('rules.critical_particles')
local M={};M.__index=M
local cached
local function clock(actor) return StaticFindObject('/Script/Engine.Default__GameplayStatics'):GetTimeSeconds(actor) end
local function transform() return {Rotation={X=0,Y=0,Z=0,W=1},Translation={X=0,Y=0,Z=0},Scale3D={X=1,Y=1,Z=1}} end
function M.new(binding,pc)
  if not cached then
    local f=assert(io.open(binding.item_models_root..'/../effects/critical_hit.json','rb'));local raw=f:read('a');f:close()
    assert(require('storage.sha256')(raw)=='41538d188ee75cddef42295bc1a94373d80bd0d2d6d707ecb701d3f604138f92','critical-sprite-digest')
    cached=assert(require('dkjson').decode(raw));assert(cached.width==8 and cached.height==8 and #cached.runs==25,'critical-sprite-schema')
  end
  return setmetatable({binding=binding,pc=pc,particles={},emitters={},sprite=cached,spawned=0,peak=0},M)
end
function M:prepare()
  if identity.matches(self.actor,self.actor_id) and valid(self.mesh) and valid(self.material) then return end
  if identity.matches(self.actor,self.actor_id) then self.actor:K2_DestroyActor() end
  local p=self.binding.actor:K2_GetActorLocation()
  self.actor=self.binding.actor:GetWorld():SpawnActor(StaticFindObject('/Script/Engine.Actor'),{X=p.X,Y=p.Y,Z=p.Z},{Pitch=0,Yaw=0,Roll=0})
  assert(valid(self.actor),'critical-particle-actor');self.actor_id=identity.capture(self.actor)
  self.mesh=self.actor:AddComponentByClass(StaticFindObject('/Script/ProceduralMeshComponent.ProceduralMeshComponent'),true,transform(),false)
  assert(valid(self.mesh),'critical-particle-mesh');self.mesh:SetCollisionEnabled(0);self.mesh:SetCastShadow(false)
  local path=self.binding.item_models_root..'/../effects/critical_hit.png'
  local f=assert(io.open(path,'rb'));local raw=f:read('a');f:close()
  assert(require('storage.sha256')(raw)==self.sprite.source_sha256,'critical-png-digest')
  local library=StaticFindObject('/Script/Engine.Default__KismetRenderingLibrary')
  self.texture=StaticFindObject('/Script/Engine.KismetRenderingLibrary:ImportFileAsTexture2D')(library,self.actor,path)
  assert(valid(self.texture),'critical-png-import');self.texture.Filter=0
  local base=StaticFindObject('/Paper2D/MaskedUnlitSpriteMaterial.MaskedUnlitSpriteMaterial')
  assert(valid(base),'critical-masked-material')
  self.material=StaticFindObject('/Script/Engine.Default__KismetMaterialLibrary'):CreateDynamicMaterialInstance(self.actor,base,FName('PBZMC_Critical'),1)
  assert(valid(self.material),'critical-material-instance')
  self.material:SetTextureParameterValue(FName('SpriteTexture'),self.texture)
  assert(identity.matches(self.material:K2_GetTextureParameterValue(FName('SpriteTexture')),identity.capture(self.texture)),'critical-sprite-parameter')
  self.mesh:SetMaterial(0,self.material)
end
function M:emit_tick(e)
  if not identity.matches(e.target,e.id) then return end
  local c=e.target:K2_GetActorLocation();local capsule=e.target.CapsuleComponent
  local width,height=64,180
  if valid(capsule) then width=capsule:GetScaledCapsuleRadius()*2;height=capsule:GetScaledCapsuleHalfHeight()*2 end
  for _,p in ipairs(rules.emit({X=c.X,Y=c.Y,Z=c.Z},width,height)) do
    if #self.particles>=64 then table.remove(self.particles,1) end
    self.particles[#self.particles+1]=p;self.spawned=self.spawned+1
  end
  self.peak=math.max(self.peak,#self.particles)
end
function M:burst(target)
  if not self.binding:is_current() or not valid(target) then return false end
  self:prepare();local now=clock(self.binding.actor)
  local e={target=target,id=identity.capture(target),remaining=2,next_time=now+.05}
  if #self.emitters>=4 then table.remove(self.emitters,1) end
  self.emitters[#self.emitters+1]=e;self:emit_tick(e)
  if not self.timer then
    self.last=now;self.physics=0;self.next_render=0
    self.timer=LoopInGameThreadAfterFrames(1,function()
      local ok,why=pcall(self.tick,self)
      if not ok then self.error=tostring(why);self.binding.log('MC critical particles failed: '..self.error);self:close() end
    end)
  end
  return true
end
function M:tick()
  if not self.binding:is_current() then self:close();return end
  local now=clock(self.binding.actor);local dt=math.max(0,math.min(.15,now-self.last));self.last=now
  self.physics=self.physics+dt
  while self.physics>=.05 do
    self.physics=self.physics-.05
    for i=#self.particles,1,-1 do
      local p=self.particles[i];rules.tick(p)
      if p.ticks>=p.max_ticks then table.remove(self.particles,i) end
    end
  end
  for i=#self.emitters,1,-1 do
    local e=self.emitters[i]
    if now>=e.next_time then self:emit_tick(e);e.remaining=e.remaining-1;e.next_time=e.next_time+.05 end
    if e.remaining<=0 then table.remove(self.emitters,i) end
  end
  if #self.particles==0 and #self.emitters==0 then
    self.mesh:ClearAllMeshSections();CancelDelayedAction(self.timer);self.timer=nil
    self.binding.log('MC critical particles completed spawned='..self.spawned..' peak='..self.peak..' render_peak_ms='..tostring(self.max_render_ms))
    return
  end
  if now<self.next_render then return end
  self.next_render=now+1/30
  local started=os.clock();local p=self.binding.actor:K2_GetActorLocation();local origin={X=p.X,Y=p.Y,Z=p.Z}
  local _,right,up=require('presentation.native_steve_pose').axes(self.pc.PlayerCameraManager.CameraCachePrivate.POV.Rotation)
  local part=rules.mesh(self.particles,right,up,origin)
  self.mesh:K2_SetWorldLocationAndRotation(origin,{Pitch=0,Yaw=0,Roll=0},false,{},true)
  require('host.pbz.mesh_bundle').apply(self.mesh,part)
  self.max_render_ms=math.max(self.max_render_ms or 0,(os.clock()-started)*1000)
end
function M:close()
  if self.timer then CancelDelayedAction(self.timer);self.timer=nil end
  if identity.matches(self.actor,self.actor_id) then self.actor:K2_DestroyActor() end
  self.actor=nil;self.mesh=nil;self.texture=nil;self.material=nil;self.particles={};self.emitters={}
end
return M
