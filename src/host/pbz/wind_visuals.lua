-- Original textured WindChargeModel. Each recycled projectile uploads the
-- static core and shell once; flying only changes transforms and a cached UV phase.
local identity=require('host.pbz.object_identity')
local valid=require('host.pbz.appearance').valid
local mesh=require('host.pbz.mesh_bundle')
local M={};M.__index=M
local assets={}
local zero={Pitch=0,Yaw=0,Roll=0}
local transform={Rotation={X=0,Y=0,Z=0,W=1},Translation={X=0,Y=0,Z=0},Scale3D={X=1,Y=1,Z=1}}
local function read(path)
  local file=assert(io.open(path,'rb'));local bytes=file:read('a');file:close();return bytes
end
local function source(root)
  if assets[root] then return assets[root] end
  local spec=assert(require('dkjson').decode(read(root..'/manifest.json')))
  local result={texture=spec.texture,bones={}}
  for _,name in ipairs({'core','shell'}) do
    local file=name..'.mesh';local raw=read(root..'/'..file)
    assert(require('storage.sha256')(raw)==spec.files[file],'wind-projectile-mesh-hash:'..name)
    local part=assert(mesh.decode(raw,6.25)[1])
    result.bones[name]={part=part,frames={[0]=part.uv}}
  end
  assets[root]=result;return result
end
local function uv(bone,tick)
  local key=tick%100
  local values=bone.frames[key]
  if not values then
    values={};local scroll=(key*3%100)/100
    for i,p in ipairs(bone.part.uv) do values[i]={X=p.X+scroll,Y=p.Y} end
    bone.frames[key]=values
  end
  return values
end
function M.new(binding)
  local root=binding.item_models_root..'/../wind-charge'
  return setmetatable({binding=binding,root=root,source=source(root),pool={},all={}},M)
end
function M:acquire(position)
  local handle=table.remove(self.pool)
  if handle and identity.matches(handle.actor,handle.id) then return handle end
  if handle then self.all[handle]=nil end
  local pawn=self.binding.actor
  local actor=pawn:GetWorld():SpawnActor(StaticFindObject('/Script/Engine.Actor'),position,zero)
  assert(valid(actor),'wind-projectile-actor')
  handle={actor=actor,id=identity.capture(actor),parts={}}
  local ok,why=pcall(function()
    if not valid(self.material) then
      self.material,self.texture=require('host.pbz.translucent_blocks').new(pawn,self.root,self.source.texture)
      self.texture.AddressX=0 -- Wrap the original Breeze UV scroll.
    end
    local class=StaticFindObject('/Script/ProceduralMeshComponent.ProceduralMeshComponent')
    for _,name in ipairs({'core','shell'}) do
      local c=actor:AddComponentByClass(class,true,transform,false);assert(valid(c),'wind-projectile-'..name)
      c:SetHiddenInGame(true,false);c:SetCastShadow(false);c:SetCollisionEnabled(0);c:SetMaterial(0,self.material)
      mesh.apply(c,self.source.bones[name].part);handle.parts[name]=c
    end
  end)
  if not ok then actor:K2_DestroyActor();error(why) end
  self.all[handle]=true;return handle
end
function M:draw(handle,p,age,eye)
  assert(identity.matches(handle.actor,handle.id),'wind-projectile-visual-retired')
  local dx,dy,dz=p.X-eye.X,p.Y-eye.Y,p.Z-eye.Z
  local shown=age>=.1 or dx*dx+dy*dy+dz*dz>=350^2
  local tick=math.floor(age*20)
  for name,c in pairs(handle.parts) do
    if shown then
      local yaw=(name=='core' and -320 or 320)*age
      c:K2_SetWorldLocationAndRotation(p,{Pitch=0,Yaw=yaw,Roll=0},false,{},true)
      if handle.tick~=tick then
        local bone=self.source.bones[name];local part=bone.part
        c:UpdateMeshSection_LinearColor(0,part.positions,part.normals,uv(bone,tick),{},{},{},part.colors,{},false)
      end
    end
    if handle.shown~=shown then c:SetHiddenInGame(not shown,false) end
  end
  handle.shown=shown;handle.tick=shown and tick or nil
end
function M:release(handle)
  if not handle or not self.all[handle] then return end
  if not identity.matches(handle.actor,handle.id) then self.all[handle]=nil;return end
  if #self.pool>=4 then handle.actor:K2_DestroyActor();self.all[handle]=nil;return end
  for _,c in pairs(handle.parts) do c:SetHiddenInGame(true,false) end
  handle.shown=false;handle.tick=nil;self.pool[#self.pool+1]=handle
end
function M:close()
  for h in pairs(self.all) do if identity.matches(h.actor,h.id) then h.actor:K2_DestroyActor() end end
  self.all={};self.pool={}
end
return M
