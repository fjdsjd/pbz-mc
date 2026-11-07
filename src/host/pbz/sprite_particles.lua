local identity=require('host.pbz.object_identity')
local valid=require('host.pbz.appearance').valid
local quads=require('presentation.particle_quads')
local axes=require('presentation.native_steve_pose').axes
local bundle=require('host.pbz.mesh_bundle')
local M={};M.__index=M
local limit=96
local zero={Pitch=0,Yaw=0,Roll=0}
local empty={}
function M.new(binding,pc,asset,rules)
  assert(type(rules)=='table' and type(rules.emit)=='function' and type(rules.mesh)=='function','invalid-particle-rules:'..asset)
  return setmetatable({binding=binding,pc=pc,particles={},spawned=0,sections=0,updates=0,peak=0,
    asset_name=asset,rules=rules,interval=rules.interval or 1/30},M)
end
function M.impact(combat,effect)
  if not combat.mace_fx then
    combat.mace_fx=M.new(combat.binding,combat.pc,'mace',require('rules.mace_particles'))
  end
  return combat.mace_fx:burst(effect)
end
function M:prepare()
  local root=self.binding.item_models_root..'/../effects/'
  local f=assert(io.open(root..self.asset_name..'.json','rb'));local raw=f:read('a');f:close()
  self.asset=assert(require('dkjson').decode(raw))
  local path=root..self.asset_name..'.png'
  local f=assert(io.open(path,'rb'));local png=f:read('a');f:close()
  assert(require('storage.sha256')(png)==self.asset.atlas_sha256,'particle-atlas-digest:'..self.asset_name)
  self.game=StaticFindObject('/Script/Engine.Default__GameplayStatics')
  self.actor=self.binding.actor:GetWorld():SpawnActor(StaticFindObject('/Script/Engine.Actor'),{X=0,Y=0,Z=0},zero)
  assert(valid(self.actor),'particle-actor');self.actor_id=identity.capture(self.actor)
  self.mesh=self.actor:AddComponentByClass(StaticFindObject('/Script/ProceduralMeshComponent.ProceduralMeshComponent'),true,
    {Rotation={X=0,Y=0,Z=0,W=1},Translation={X=0,Y=0,Z=0},Scale3D={X=1,Y=1,Z=1}},false)
  assert(valid(self.mesh),'particle-mesh');self.mesh:SetCollisionEnabled(0);self.mesh:SetCastShadow(false)
  local library=StaticFindObject('/Script/Engine.Default__KismetRenderingLibrary')
  self.texture=StaticFindObject('/Script/Engine.KismetRenderingLibrary:ImportFileAsTexture2D')(library,self.actor,path)
  assert(valid(self.texture),'particle-texture');self.texture.Filter=0
  self.material=StaticFindObject('/Script/Engine.Default__KismetMaterialLibrary'):CreateDynamicMaterialInstance(self.actor,
    StaticFindObject('/Paper2D/MaskedUnlitSpriteMaterial.MaskedUnlitSpriteMaterial'),FName('PBZMC_'..self.asset_name),1)
  assert(valid(self.material),'particle-material');self.material:SetTextureParameterValue(FName('SpriteTexture'),self.texture)
  self.mesh:SetMaterial(0,self.material)
  self.mesh:SetHiddenInGame(true,false)
end

function M:burst(effect)
  if not identity.matches(self.actor,self.actor_id) then
    self:close()
    local ok,why=pcall(self.prepare,self)
    if not ok then self:close();error(why) end
  end
  local now=self.game:GetTimeSeconds(self.binding.actor)
  local batch=self.rules.emit(effect,now,self.asset.frames)
  local queue=self.particles
  local count=#queue
  local keep=math.min(count,math.max(0,limit-#batch))
  if keep<count then table.move(queue,count-keep+1,count,1) end
  local added=math.min(#batch,limit)
  table.move(batch,#batch-added+1,#batch,keep+1,queue)
  self.spawned=self.spawned+added
  if not self.timer then
    local point=effect.wind or effect.ground or effect
    self.origin={X=point.X,Y=point.Y,Z=point.Z}
    self.mesh:K2_SetWorldLocationAndRotation(self.origin,zero,false,{},true)
    self.next_render=now
    -- UE4SS may already have queued one invocation when a timer is cancelled.
    local owner={}
    self.tick_owner=owner
    self.timer=assert(LoopInGameThreadAfterFrames(1,function()
      if self.tick_owner~=owner then return end
      local ok,err=pcall(self.tick,self)
      if not ok then self.binding.log('MC '..self.asset_name..' particles failed: '..tostring(err));self:close() end
    end),'particle-scheduler')
    self:tick()
  end
  return added
end
function M:tick()
  if not self.binding:is_current() then self:close();return end
  local now=self.game:GetTimeSeconds(self.binding.actor)
  if now<self.next_render then return end
  self.next_render=now+self.interval-(now-self.next_render)%self.interval
  local queue=self.particles
  local count=0
  for i=1,#queue do
    local p=queue[i]
    if now-p.start<p.life then count=count+1;queue[count]=p end
  end
  for i=#queue,count+1,-1 do queue[i]=nil end
  if count==0 then
    self.mesh:SetHiddenInGame(true,false)
    self.visible=false
    self.tick_owner=nil
    CancelDelayedAction(self.timer);self.timer=nil
    return
  end
  local grow=not self.buffer or count>self.buffer.capacity
  if grow then
    local capacity=8
    while capacity<count do capacity=math.min(limit,capacity*2) end
    self.buffer=quads.new(capacity)
  end
  local _,right,up=axes(self.pc.PlayerCameraManager.CameraCachePrivate.POV.Rotation)
  local part=self.rules.mesh(queue,now,right,up,self.origin,self.asset.frames,self.buffer)
  if grow then
    bundle.apply(self.mesh,part);self.sections=self.sections+1
  else
    self.mesh:UpdateMeshSection_LinearColor(0,part.positions,part.normals,part.uv,empty,empty,empty,part.colors,empty,false)
    self.updates=self.updates+1
  end
  self.peak=math.max(self.peak,part.used)
  if not self.visible then self.mesh:SetHiddenInGame(false,false);self.visible=true end
end
function M:close()
  self.tick_owner=nil
  if self.timer then CancelDelayedAction(self.timer);self.timer=nil end
  if identity.matches(self.actor,self.actor_id) then self.actor:K2_DestroyActor() end
  self.actor=nil;self.actor_id=nil;self.mesh=nil;self.material=nil;self.texture=nil;self.particles={}
  self.buffer=nil;self.visible=false;self.game=nil
end
return M
