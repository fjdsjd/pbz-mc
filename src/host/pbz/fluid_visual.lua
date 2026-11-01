-- One existing actor/mesh per fluid cell; original strip textures are shared
-- only within this world instance. Animation changes UV, never world geometry.
local valid=require('host.pbz.appearance').valid
local identity=require('host.pbz.object_identity')
local Mesh=require('rules.fluid_mesh')
local Fluid=require('rules.fluid_network')
local bundle=require('host.pbz.mesh_bundle')
local sha=require('storage.sha256')
local M={};M.__index=M
local roles={'still','flow'}
local function linear(v)return v<=.04045 and v/12.92 or ((v+.055)/1.055)^2.4 end
local manifest_cache
local function read(path,limit)
  local file=assert(io.open(path,'rb'));local size=file:seek('end');file:seek('set',0)
  if not size or size>(limit or 8*1024*1024)then file:close();error('fluid-asset-size')end
  local raw=file:read('a');file:close();return raw
end
local function safe_path(path)
  return type(path)=='string'and path:match('^[%w_/%-.]+$')and not path:find('..',1,true)
    and path:sub(1,1)~='/'and not path:find(':',1,true)
end
local function assets(root)
  if manifest_cache and manifest_cache.root==root then return manifest_cache.fluids end
  local manifest=assert(require('dkjson').decode(read(root..'/manifest.json',32*1024*1024)))
  assert(manifest.schema==1 and manifest.private_local_assets==true,'fluid-manifest-schema')
  local fluids=assert(manifest.fluids,'fluid-manifest-definitions')
  for _,id in ipairs({Fluid.water,Fluid.lava})do
    local definition=assert(fluids[id],'fluid-manifest-entry:'..id)
    for _,role in ipairs(roles)do
      local texture=assert(definition.textures[role],'fluid-manifest-texture')
      assert(safe_path(texture.path),'fluid-texture-path')
      assert(texture.image_size[1]==texture.frame_size[1]and texture.image_size[2]==texture.frame_size[2]*texture.frame_count,'fluid-vertical-strip-required')
      texture.timeline=Mesh.timeline(texture)
    end
  end
  -- Only one bounded pure-data manifest cache; never cache UObject references.
  manifest_cache={root=root,fluids=fluids};return fluids
end
function M.new(worldAdapter,assetsRoot)
  assert(type(worldAdapter)=='table'and type(worldAdapter.readNeighbor)=='function','fluid-neighbor-adapter-required')
  assert(type(assetsRoot)=='string','fluid-assets-root-required')
  return setmetatable({world=worldAdapter,root=assetsRoot,fluids=assets(assetsRoot),materials={},textures={},
    entries={},by_handle={},cursor=1,closed=false,max_handles=worldAdapter.fluid_visual_limit or 1024,
    animation_distance=worldAdapter.fluid_animation_distance or 5000,uploads=0,neighbor_reads=0,last_tick=0},M)
end
function M:_current()
  return not self.closed and (not self.world.is_current or self.world:is_current())
end
function M:_material(id,role,actor)
  local key=id..':'..role;local old=self.materials[key]
  if old and identity.matches(old.object,old.identity)and identity.matches(self.textures[key].object,self.textures[key].identity)then return old.object end
  local definition=self.fluids[id];local texture=definition.textures[role]
  local raw=read(self.root..'/'..texture.path)
  assert((not texture.bytes or #raw==texture.bytes)and sha(raw)==texture.sha256,'fluid-texture-digest:'..texture.path)
  local context=self.world.context or self.world.pawn or actor
  assert(valid(context),'fluid-material-world-context')
  local library=StaticFindObject('/Script/Engine.Default__KismetRenderingLibrary')
  local importer=StaticFindObject('/Script/Engine.KismetRenderingLibrary:ImportFileAsTexture2D')
  local native_texture=importer(library,context,self.root..'/'..texture.path)
  assert(valid(native_texture),'fluid-texture-import:'..texture.path);native_texture.Filter=0
  -- PBZ cooks the widget pass-through material, but not Paper2D translucent.
  -- Its one-sided instance plus reversed triangles also keeps the original
  -- texture visible from underwater without Widget's blank back-face branch.
  local water=id==Fluid.water
  local path=water and '/Engine/EngineMaterials/Widget3DPassThrough_Translucent_OneSided.Widget3DPassThrough_Translucent_OneSided'
    or '/Paper2D/MaskedUnlitSpriteMaterial.MaskedUnlitSpriteMaterial'
  local base=StaticFindObject(path)
  if not valid(base)then base=LoadAsset(path)end
  assert(valid(base),'fluid-material-unavailable:'..path)
  local material=StaticFindObject('/Script/Engine.Default__KismetMaterialLibrary'):CreateDynamicMaterialInstance(
    context,base,FName('PBZMC_Fluid_'..id:match(':(.+)$')..'_'..role),1)
  assert(valid(material),'fluid-material-instance')
  local parameter=water and 'SlateUI'or 'SpriteTexture'
  material:SetTextureParameterValue(FName(parameter),native_texture)
  assert(identity.matches(material:K2_GetTextureParameterValue(FName(parameter)),identity.capture(native_texture)),'fluid-sprite-parameter')
  if water then
    local rgb=definition.tint_rgb
    material:SetVectorParameterValue(FName('TintColorAndOpacity'),{R=linear(rgb[1]/255),G=linear(rgb[2]/255),B=linear(rgb[3]/255),A=1})
    material:SetVectorParameterValue(FName('BackColor'),{R=0,G=0,B=0,A=0})
    material:SetScalarParameterValue(FName('OpacityFromTexture'),1)
  end
  self.textures[key]={object=native_texture,identity=identity.capture(native_texture)}
  self.materials[key]={object=material,identity=identity.capture(material)}
  return material
end
function M:_valid(entry)
  return entry and identity.matches(entry.handle.actor,entry.actor_id)and identity.matches(entry.handle.mesh,entry.mesh_id)
    and valid(entry.handle.actor)and valid(entry.handle.mesh)
end
function M:_solid(cell)
  if self.world.isSolid then return self.world.isSolid(cell)==true end
  local registry=self.world.registry;local definition=cell and registry and registry.get(cell.content_id)
  return definition and definition.full_cube==true or false
end
function M:_geometry(entry,record)
  local definition=assert(self.fluids[record.content_id],'fluid-definition-unavailable')
  local generated=Mesh.build(record,function(dx,dy,dz)return self.world.readNeighbor(record,dx,dy,dz)end,{
    tint_rgb=record.content_id==Fluid.water and {255,255,255}or definition.tint_rgb,vertex_alpha=definition.vertex_alpha,
    is_solid=function(cell)return self:_solid(cell)end,
    occludes=self.world.occludes,
  })
  self.neighbor_reads=self.neighbor_reads+generated.reads
  local mesh=entry.handle.mesh
  for index,role in ipairs(roles)do
    local part=generated.sections[role];local texture=definition.textures[role]
    if record.content_id==Fluid.water then
      local triangles=part.triangles;local n=#triangles
      for i=1,n,3 do triangles[#triangles+1]=triangles[i];triangles[#triangles+1]=triangles[i+2];triangles[#triangles+1]=triangles[i+1]end
    end
    local frame=Mesh.frame(texture.timeline,self.last_tick);Mesh.animate(part,frame,texture.frame_count)
    mesh:SetMaterial(index-1,self:_material(record.content_id,role,entry.handle.actor))
    if #part.positions>0 then bundle.apply(mesh,part,index-1);self.uploads=self.uploads+1
    else mesh:ClearMeshSection(index-1)end
    entry.frames[role]=frame
  end
  entry.record=record;entry.geometry=generated;entry.content_id=record.content_id
  return true
end
function M:attach(handle,record)
  if not self:_current()then return false,'fluid-renderer-world-stale'end
  if self.by_handle[handle]then return self:update(handle,record)end
  if #self.entries>=self.max_handles then return false,'fluid-visual-capacity'end
  if not handle or not valid(handle.actor)or not valid(handle.mesh)then return false,'fluid-existing-mesh-required'end
  local entry={handle=handle,actor_id=identity.capture(handle.actor),mesh_id=identity.capture(handle.mesh),frames={}}
  local ok,why=pcall(function()
    handle.mesh:SetCollisionEnabled(0);handle.mesh:SetCastShadow(false);handle.mesh:SetCullDistance(20000)
    handle.mesh:ClearAllMeshSections();self:_geometry(entry,record)
  end)
  if not ok then return false,tostring(why)end
  entry.index=#self.entries+1;self.entries[entry.index]=entry;self.by_handle[handle]=entry;handle.fluid_visual=entry
  return true
end
function M:update(handle,record)
  local entry=self.by_handle[handle]
  if not self:_current()or not self:_valid(entry)then return false,'fluid-renderer-handle-stale'end
  local ok,why=pcall(self._geometry,self,entry,record)
  return ok,ok and nil or tostring(why)
end
function M:_origin()
  if self.world.renderOrigin then return self.world.renderOrigin()end
  if valid(self.world.pawn)then return self.world.pawn:K2_GetActorLocation()end
end
function M:tick(now,budget)
  if not self:_current()then return {visited=0,updated=0,stale=true}end
  local tick=math.max(0,math.floor(now*20));self.last_tick=tick
  budget=math.max(0,math.floor(budget or 8));local count=#self.entries
  if count==0 or budget==0 then return {visited=0,updated=0,neighbor_reads=0}end
  local origin=self:_origin();local max_d2=self.animation_distance^2;local visited,updated=0,0
  while visited<math.min(count,budget)and #self.entries>0 do
    if self.cursor>#self.entries then self.cursor=1 end
    local entry=self.entries[self.cursor];self.cursor=self.cursor+1;visited=visited+1
    if self:_valid(entry)then
      local record=entry.record
      local near=not origin or (record.x-origin.X)^2+(record.y-origin.Y)^2+(record.z-origin.Z)^2<=max_d2
      if near then
        local changed=false;local definition=self.fluids[entry.content_id]
        for index,role in ipairs(roles)do
          local texture=definition.textures[role];local frame=Mesh.frame(texture.timeline,tick)
          local part=entry.geometry.sections[role]
          if frame~=entry.frames[role]and #part.positions>0 then
            Mesh.animate(part,frame,texture.frame_count)
            entry.handle.mesh:UpdateMeshSection_LinearColor(index-1,part.positions,part.normals,part.uv,{},{},{},part.colors,{},false)
            self.uploads=self.uploads+1;changed=true
          end
          entry.frames[role]=frame
        end
        if changed then updated=updated+1 end
      end
    else self:remove(entry.handle)end
  end
  return {visited=visited,updated=updated,neighbor_reads=0,handles=#self.entries}
end
function M:remove(handle)
  local entry=self.by_handle[handle];if not entry then return true end
  if self:_valid(entry)then handle.mesh:ClearAllMeshSections()end
  local last=self.entries[#self.entries];self.entries[#self.entries]=nil
  if entry~=last then self.entries[entry.index]=last;last.index=entry.index end
  self.by_handle[handle]=nil;if handle.fluid_visual==entry then handle.fluid_visual=nil end
  return true
end
function M:close()
  if self.closed then return true end
  while #self.entries>0 do self:remove(self.entries[#self.entries].handle)end
  self.materials={};self.textures={};self.closed=true;return true
end
return M
