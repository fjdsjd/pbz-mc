local identity=require('host.pbz.object_identity')
local valid=require('host.pbz.appearance').valid
local rules=require('rules.portal_particles')
local M={};M.__index=M
local function clock(pawn)return StaticFindObject('/Script/Engine.Default__GameplayStatics'):GetTimeSeconds(pawn)end
function M.new(binding,pc)
  return setmetatable({binding=binding,pc=pc,particles={},spawned=0},M)
end
function M:prepare()
  if identity.matches(self.actor,self.actor_id) then return end
  local root=self.binding.item_models_root..'/../effects/'
  local f=assert(io.open(root..'portal.json','rb'));local raw=f:read('a');f:close()
  self.asset=assert(require('dkjson').decode(raw))
  local f=assert(io.open(root..'portal.png','rb'));local png=f:read('a');f:close()
  assert(require('storage.sha256')(png)==self.asset.atlas_sha256,'portal-atlas-digest')
  self.actor=self.binding.actor:GetWorld():SpawnActor(StaticFindObject('/Script/Engine.Actor'),{X=0,Y=0,Z=0},{Pitch=0,Yaw=0,Roll=0})
  assert(valid(self.actor),'portal-particle-actor');self.actor_id=identity.capture(self.actor)
  self.mesh=self.actor:AddComponentByClass(StaticFindObject('/Script/ProceduralMeshComponent.ProceduralMeshComponent'),true,
    {Rotation={X=0,Y=0,Z=0,W=1},Translation={X=0,Y=0,Z=0},Scale3D={X=1,Y=1,Z=1}},false)
  assert(valid(self.mesh),'portal-particle-mesh');self.mesh:SetCollisionEnabled(0);self.mesh:SetCastShadow(false)
  local library=StaticFindObject('/Script/Engine.Default__KismetRenderingLibrary')
  self.texture=StaticFindObject('/Script/Engine.KismetRenderingLibrary:ImportFileAsTexture2D')(library,self.actor,root..'portal.png')
  assert(valid(self.texture),'portal-particle-texture');self.texture.Filter=0
  self.material=StaticFindObject('/Script/Engine.Default__KismetMaterialLibrary'):CreateDynamicMaterialInstance(self.actor,
    StaticFindObject('/Paper2D/MaskedUnlitSpriteMaterial.MaskedUnlitSpriteMaterial'),FName('PBZMC_Portal'),1)
  assert(valid(self.material),'portal-particle-material');self.material:SetTextureParameterValue(FName('SpriteTexture'),self.texture)
  self.mesh:SetMaterial(0,self.material)
end
function M:burst(point)
  self:prepare();local now=clock(self.binding.actor)
  for _,p in ipairs(rules.emit(point,now,self.asset.frames)) do
    if #self.particles>=96 then table.remove(self.particles,1) end
    self.particles[#self.particles+1]=p;self.spawned=self.spawned+1
  end
  if not self.timer then
    self.next_render=0
    self.timer=LoopInGameThreadAfterFrames(1,function()
      local ok,err=pcall(self.tick,self)
      if not ok then self.binding.log('MC pearl particles failed: '..tostring(err));self:close() end
    end)
  end
end
function M:tick()
  if not self.binding:is_current() then self:close();return end
  local now=clock(self.binding.actor)
  for i=#self.particles,1,-1 do if now-self.particles[i].start>=self.particles[i].life then table.remove(self.particles,i) end end
  if #self.particles==0 then self.mesh:ClearAllMeshSections();CancelDelayedAction(self.timer);self.timer=nil;return end
  if now<self.next_render then return end;self.next_render=now+1/30
  local p=self.binding.actor:K2_GetActorLocation();local origin={X=p.X,Y=p.Y,Z=p.Z}
  local _,right,up=require('presentation.native_steve_pose').axes(self.pc.PlayerCameraManager.CameraCachePrivate.POV.Rotation)
  self.mesh:K2_SetWorldLocationAndRotation(origin,{Pitch=0,Yaw=0,Roll=0},false,{},true)
  require('host.pbz.mesh_bundle').apply(self.mesh,rules.mesh(self.particles,now,right,up,origin,self.asset.frames))
end
function M:close()
  if self.timer then CancelDelayedAction(self.timer);self.timer=nil end
  if identity.matches(self.actor,self.actor_id) then self.actor:K2_DestroyActor() end
  self.actor=nil;self.actor_id=nil;self.mesh=nil;self.material=nil;self.texture=nil;self.particles={}
end
return M
