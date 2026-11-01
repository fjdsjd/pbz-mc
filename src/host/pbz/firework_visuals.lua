-- Render-only firework rockets and their original white spark trail. One
-- emitter actor, up to 32 reusable rocket components, one fixed 512-vertex
-- particle component. Caller owns all physics, sound, item and save effects.
local identity=require('host.pbz.object_identity')
local valid=require('host.pbz.appearance').valid
local bundle=require('host.pbz.mesh_bundle')
local rigid=require('presentation.rigid_transform')
local frames=require('presentation.native_steve_pose')
local sparks=require('presentation.firework_sparks')
local sha=require('storage.sha256')
local json=require('dkjson')
local M={max_rockets=32};M.__index=M
local zero={X=0,Y=0,Z=0};local no_rotation={Pitch=0,Yaw=0,Roll=0}
local assets={}
local function transform()
  return {Rotation={X=0,Y=0,Z=0,W=1},Translation={X=0,Y=0,Z=0},Scale3D={X=1,Y=1,Z=1}}
end
local function vec(p)
  local result={}
  for _,k in ipairs({'X','Y','Z'})do
    local n=p[k];assert(type(n)=='number' and n==n and math.abs(n)<math.huge,'invalid-firework-visual-vector');result[k]=n
  end
  return result
end
local function read(path,limit)
  local f=assert(io.open(path,'rb'));local size=f:seek('end');f:seek('set',0)
  if not size or size>limit then f:close();error('firework-visual-file-too-large')end
  local raw=f:read('a');f:close();return assert(raw)
end
local function asset(root)
  if assets[root]then return assets[root]end
  local raw=read(root..'/manifest.json',4*1024*1024)
  local manifest,pos,why=json.decode(raw)
  assert(manifest and not why and raw:sub(pos):match('^%s*$') and manifest.schema==1
    and manifest.private_local_assets==true,'firework-visual-manifest')
  assert(manifest.particles=='particles/spark-frames.json','firework-particle-manifest-path')
  local records={};for _,r in ipairs(manifest.outputs)do records[r.path]=r end
  local record=assert(records[manifest.particles],'firework-particle-manifest-unlisted')
  raw=read(root..'/'..manifest.particles,1024*1024)
  assert(#raw==record.bytes and sha(raw)==record.sha256,'firework-particle-manifest-digest')
  local spec;spec,pos,why=json.decode(raw)
  assert(spec and not why and raw:sub(pos):match('^%s*$') and spec.schema==1 and #spec.sprites==8,'firework-particle-schema')
  local atlas=assert(spec.atlas,'firework-particle-atlas-missing')
  assert(atlas.path=='particles/spark_atlas.png' and atlas.columns==8 and atlas.opacity_rows==32,'firework-particle-atlas-schema')
  local output=assert(records[atlas.path],'firework-particle-atlas-unlisted')
  assert(output.bytes==atlas.bytes and output.sha256==atlas.sha256,'firework-particle-atlas-record-mismatch')
  assets[root]=spec;return spec
end
function M.new(binding,pc)
  assert(binding and binding:is_current() and valid(binding.actor) and valid(pc),'firework-visual-owner-required')
  return setmetatable({binding=binding,owner=binding.actor,owner_id=identity.capture(binding.actor),
    world_id=identity.capture(binding.actor:GetWorld()),pc=pc,pc_id=identity.capture(pc),
    root=binding.elytra_models_root or binding.item_models_root..'/../elytra-firework',
    pool={},handles={},particles={},accumulator=0,active=0,serial=0,
    report={rockets=0,launched=0,components=0,rocket_uploads=0,particle_uploads=0,particle_updates=0,spawned=0,peak_particles=0,dropped=0}},M)
end
function M:context_current()
  return not self.closed and not self.binding.closed and valid(self.owner) and identity.matches(self.owner,self.owner_id)
    and identity.matches(self.owner:GetWorld(),self.world_id) and valid(self.pc) and identity.matches(self.pc,self.pc_id)
end
function M:is_current()
  if not self:context_current()then return false end
  if self.actor then
    if not self.ready or not valid(self.actor) or not identity.matches(self.actor,self.actor_id)
      or not identity.matches(self.actor:GetWorld(),self.world_id)or not valid(self.mesh)
      or not identity.matches(self.mesh,self.mesh_id)or not identity.matches(self.mesh:GetOwner(),self.actor_id)
      or not identity.matches(self.material,self.material_id)or not identity.matches(self.texture,self.texture_id)then return false end
    for _,entry in ipairs(self.pool)do
      if not entry.ready or not valid(entry.component) or not identity.matches(entry.component,entry.id)
        or not identity.matches(entry.component:GetOwner(),self.actor_id)then return false end
    end
  end
  return true
end
function M:prepare()
  assert(self:context_current(),'firework-visual-stale-owner')
  if self.actor then assert(self:is_current(),'firework-visual-stale-emitter');return end
  if not self.spec then self.spec=asset(self.root)end
  if not self.model then
    local catalog=require('host.pbz.item_models').new(self.binding.item_models_root)
    self.model=assert(catalog:resolve({content_id='pbzmc:firework_rocket'},'ground',{},6.25))
    self.display=require('presentation.item_model_transform').solve(self.model.display,'ground',6.25)
  end
  local actor=self.owner:GetWorld():SpawnActor(StaticFindObject('/Script/Engine.Actor'),zero,no_rotation)
  assert(valid(actor),'firework-emitter-allocation-failed')
  self.actor=actor;self.actor_id=identity.capture(actor)
  self.mesh=actor:AddComponentByClass(StaticFindObject('/Script/ProceduralMeshComponent.ProceduralMeshComponent'),true,transform(),false)
  assert(valid(self.mesh),'firework-particle-component-failed');self.mesh_id=identity.capture(self.mesh)
  self.mesh:SetHiddenInGame(true,false);self.mesh:SetCollisionEnabled(0);self.mesh:SetCastShadow(false)
  -- This cooked PBZ material supports true original PNG transparency. It
  -- ignores vertex colour, so source alpha uses the retained 32-row atlas.
  self.material,self.texture=require('host.pbz.translucent_blocks').new(actor,self.root,self.spec.atlas)
  self.material_id=identity.capture(self.material);self.texture_id=identity.capture(self.texture)
  assert(identity.matches(self.material:K2_GetTextureParameterValue(FName('SlateUI')),self.texture_id),'firework-particle-texture-readback')
  self.mesh:SetMaterial(0,self.material);self.ready=true
  self.report.texture_filter='point';self.report.mip_count='not-read-back';self.report.alpha_rows=32
end
function M:component()
  for _,entry in ipairs(self.pool)do if not entry.handle then assert(entry.ready,'firework-partial-component');return entry end end
  assert(#self.pool<M.max_rockets,'firework-visual-component-cap')
  local c=self.actor:AddComponentByClass(StaticFindObject('/Script/ProceduralMeshComponent.ProceduralMeshComponent'),true,transform(),false)
  assert(valid(c),'firework-rocket-component-failed')
  local entry={component=c,id=identity.capture(c)};self.pool[#self.pool+1]=entry
  c:SetHiddenInGame(true,false);c:SetCollisionEnabled(0);c:SetCastShadow(false)
  c:SetMaterial(0,self.binding.material);bundle.apply(c,self.model.part);c:SetWorldScale3D(self.display.scale)
  entry.ready=true;self.report.rocket_uploads=self.report.rocket_uploads+1;self.report.components=#self.pool
  return entry
end
function M:camera()
  assert(valid(self.pc.PlayerCameraManager),'firework-camera-unavailable')
  local rotation=self.pc.PlayerCameraManager.CameraCachePrivate.POV.Rotation
  return {Pitch=rotation.Pitch,Yaw=rotation.Yaw,Roll=rotation.Roll}
end
local function same(a,b)
  if not a then return false end
  for _,key in ipairs({'X','Y','Z'})do if a.position[key]~=b.position[key]then return false end end
  for _,key in ipairs({'Pitch','Yaw','Roll'})do if a.rotation[key]~=b.rotation[key]then return false end end
  return true
end
function M:draw(handle,rotation)
  local entry=handle.entry
  assert(valid(entry.component) and identity.matches(entry.component,entry.id)
    and identity.matches(entry.component:GetOwner(),self.actor_id),'firework-rocket-component-stale')
  if handle.attached then return end -- MC attached boost rockets render only the trail.
  local target=rigid.compose({position=handle.position,rotation={Pitch=-rotation.Pitch,Yaw=rotation.Yaw+180,Roll=-rotation.Roll}},self.display)
  if not same(entry.pose,target)then
    entry.component:K2_SetWorldLocationAndRotation(target.position,target.rotation,false,{},true);entry.pose=target
  end
end
function M:launch(position,options)
  assert(self:context_current(),'firework-visual-stale-owner')
  if self.active>=M.max_rockets then return nil,'firework-visual-cap' end
  position=vec(position);self:prepare();local entry=self:component()
  self.serial=self.serial+1
  local handle={owner=self,serial=self.serial,entry=entry,position=position,velocity=vec(zero),attached=options and options.attached==true or false}
  -- Retain the handle before draw so an initialization error remains owned.
  entry.handle=handle;self.handles[handle]=true;self.active=self.active+1
  local ok,why=pcall(function()self:draw(handle,self:camera());entry.component:SetHiddenInGame(handle.attached,false)end)
  if not ok then
    self.handles[handle]=nil;entry.handle=nil;self.active=self.active-1
    pcall(function()entry.component:SetHiddenInGame(true,false)end)
    self.report.rockets=self.active;error(why)
  end
  self.report.rockets=self.active;self.report.launched=self.report.launched+1
  return handle
end
function M:update(handle,position,velocity)
  if not self:context_current()then return false,'firework-visual-stale-owner' end
  if not self.handles[handle]or handle.owner~=self or handle.entry.handle~=handle then return false,'firework-handle-inactive' end
  handle.position=vec(position);handle.velocity=vec(velocity or zero)
  self:draw(handle,self:camera());return true
end
function M:remove(handle)
  if not self.handles[handle]or handle.owner~=self or handle.entry.handle~=handle then return false end
  local entry=handle.entry
  if identity.matches(self.actor,self.actor_id) and valid(entry.component) and identity.matches(entry.component,entry.id)
    and identity.matches(entry.component:GetOwner(),self.actor_id)then entry.component:SetHiddenInGame(true,false)end
  self.handles[handle]=nil;entry.handle=nil;self.active=self.active-1;self.report.rockets=self.active
  return true -- No star means no explosion burst, colour or damage.
end
function M:physics()
  for i=#self.particles,1,-1 do if not sparks.tick(self.particles[i])then table.remove(self.particles,i)end end
  for _,entry in ipairs(self.pool)do
    local handle=entry.handle
    if handle then
      if #self.particles>=sparks.max_particles then table.remove(self.particles,1);self.report.dropped=self.report.dropped+1 end
      self.particles[#self.particles+1]=sparks.emit(handle.position,handle.velocity)
      self.report.spawned=self.report.spawned+1
    end
  end
  self.report.peak_particles=math.max(self.report.peak_particles,#self.particles)
end
function M:render(rotation)
  if #self.particles==0 then
    if self.particles_shown then self.mesh:SetHiddenInGame(true,false);self.particles_shown=false end
    return
  end
  local _,right,up=frames.axes(rotation);local origin=vec(self.owner:K2_GetActorLocation())
  local part=sparks.mesh(self.particles,right,up,origin,self.spec.atlas)
  if self.uploaded then
    self.mesh:UpdateMeshSection_LinearColor(0,part.positions,part.normals,part.uv,{},{},{},part.colors,{},false)
    self.report.particle_updates=self.report.particle_updates+1
  else bundle.apply(self.mesh,part);self.uploaded=true;self.report.particle_uploads=self.report.particle_uploads+1 end
  if not self.origin or self.origin.X~=origin.X or self.origin.Y~=origin.Y or self.origin.Z~=origin.Z then
    self.mesh:K2_SetWorldLocationAndRotation(origin,no_rotation,false,{},true);self.origin=origin
  end
  if not self.particles_shown then self.mesh:SetHiddenInGame(false,false);self.particles_shown=true end
end
function M:tick(dt)
  assert(type(dt)=='number' and dt==dt and dt>=0 and dt<math.huge,'invalid-firework-visual-delta')
  if not self:is_current() or not self.binding:is_current()then self:close();return false end
  if not self.actor then return true end
  local rotation=self:camera()
  for _,entry in ipairs(self.pool)do if entry.handle then self:draw(entry.handle,rotation)end end
  self.accumulator=self.accumulator+dt
  local changed=false;local ticks=0
  while self.accumulator+1e-9>=sparks.tick_seconds and ticks<4 do
    ticks=ticks+1
    self.accumulator=math.max(0,self.accumulator-sparks.tick_seconds);self:physics();changed=true
  end
  if changed then self:render(rotation)end
  return true
end
function M:close()
  if self.closed then return true end
  if valid(self.actor) and identity.matches(self.actor,self.actor_id)then
    self.actor:K2_DestroyActor();assert(not valid(self.actor),'firework-emitter-still-active')
  end
  for handle in pairs(self.handles)do handle.entry.handle=nil end
  self.handles={};self.particles={};self.active=0;self.report.rockets=0;self.closed=true
  return true
end
return M
