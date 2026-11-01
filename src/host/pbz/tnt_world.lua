-- Native transient actors for primed TNT/fire. Persistent cubes are owned by
-- build_session; these non-colliding entities never become saved buildings.
local valid=require('host.pbz.appearance').valid
local identity=require('host.pbz.object_identity')
local bundle=require('host.pbz.mesh_bundle')
local M={};M.__index=M
local function v(p)return {X=p.x,Y=p.y,Z=p.z}end
local function transform()return {Rotation={X=0,Y=0,Z=0,W=1},Translation={X=0,Y=0,Z=0},Scale3D={X=1,Y=1,Z=1}}end
function M.new(binding,directory)
 return setmetatable({binding=binding,assets=require('host.pbz.tnt_assets').open(directory..'/pbzmc-assets/tnt'),
  handles={},serial=0,materials={}},M)
end
function M:material(kind,actor)
 if valid(self.materials[kind])then return self.materials[kind]end
 local material
 if kind=='tnt' then material=LoadAsset('/Engine/EngineMaterials/DefaultTextMaterialOpaque.DefaultTextMaterialOpaque')
 else
  local path=kind=='fire' and 'original/fire_0.png' or 'particles/atlas.png'
  local library=StaticFindObject('/Script/Engine.Default__KismetRenderingLibrary')
  local tex=StaticFindObject('/Script/Engine.KismetRenderingLibrary:ImportFileAsTexture2D')(library,self.binding.actor,self.assets:path(path))
  assert(valid(tex),'tnt-texture');tex.Filter=0
  material=StaticFindObject('/Script/Engine.Default__KismetMaterialLibrary'):CreateDynamicMaterialInstance(self.binding.actor,
   LoadAsset('/Paper2D/MaskedUnlitSpriteMaterial.MaskedUnlitSpriteMaterial'),FName('PBZMC_TNT_'..kind),1)
  assert(valid(material),'tnt-material');material:SetTextureParameterValue(FName('SpriteTexture'),tex)
  self.materials[kind..'_texture']=tex
 end
 assert(valid(material),'tnt-material');self.materials[kind]=material;return material
end
function M:spawn(kind,state)
 assert(self.binding:is_current(),'stale-tnt-world');self.serial=self.serial+1
 local actor=self.binding.actor:GetWorld():SpawnActor(StaticFindObject('/Script/Engine.Actor'),v(state),{Pitch=0,Yaw=0,Roll=0})
 assert(valid(actor),'tnt-actor-create')
 local h={actor=actor,identity=identity.capture(actor),kind=kind,id=self.serial};self.handles[h.id]=h
 local ok,why=pcall(function()
  h.mesh=actor:AddComponentByClass(StaticFindObject('/Script/ProceduralMeshComponent.ProceduralMeshComponent'),false,transform(),false)
  assert(valid(h.mesh),'tnt-mesh-create');h.mesh_id=identity.capture(h.mesh)
  h.mesh:SetCollisionEnabled(0);h.mesh:SetCastShadow(false)
  h.mesh:SetMaterial(0,self:material(kind,actor));h.mesh:SetCullDistance(20000)
  if kind=='tnt'then bundle.apply(h.mesh,self.assets:part('tnt.mesh'))
  elseif kind=='fire'then bundle.apply(h.mesh,self.assets:fire(0))end
  actor:K2_SetActorLocation(v(state),false,{},true)
 end)
 if not ok then self:destroy(h);error(why)end
 return h
end
function M:destroy(h)
 if identity.matches(h.actor,h.identity) and valid(h.actor)then
  if identity.matches(h.mesh,h.mesh_id) and valid(h.mesh)then h.mesh:SetVisibility(false,false)end
  h.actor:K2_DestroyActor()
 end
 self.handles[h.id]=nil;h.retired=true;return true
end
function M:valid(h)
 return h and not h.retired and identity.matches(h.actor,h.identity) and valid(h.actor)
  and identity.matches(h.mesh,h.mesh_id) and valid(h.mesh)
end
function M:render(h,state,frame)
 assert(self:valid(h),'stale-tnt-entity')
 if h.kind=='tnt'then
  if h.x~=state.x or h.y~=state.y or h.z~=state.z then
   h.actor:K2_SetActorLocation(v(state),false,{},true);h.x,h.y,h.z=state.x,state.y,state.z
  end
  if h.white~=frame.white then
   bundle.apply(h.mesh,self.assets:part(frame.white and 'tnt_flash.mesh' or 'tnt.mesh'));h.white=frame.white
  end
  if h.scale~=frame.scale then h.actor:SetActorScale3D({X=frame.scale,Y=frame.scale,Z=frame.scale});h.scale=frame.scale end
 elseif h.frame~=frame.frame then bundle.apply(h.mesh,self.assets:fire(frame.frame));h.frame=frame.frame end
end
function M:trace(from,to,radius)
 local hit,c={},{R=0,G=0,B=0,A=0};local system=require('UEHelpers').GetKismetSystemLibrary()
 local yes=system:SphereTraceSingle(self.binding.actor,v(from),v(to),radius,0,false,{self.binding.actor},0,hit,true,c,c,0)
 if not yes then return end
 local p,n=hit.Location,hit.ImpactNormal
 if not p or not n then return end
 -- PBZ's packed bStartPenetrating reads true on ordinary valid hits. Use the
 -- numeric penetration fields, already verified against live boat traces.
 if (hit.Time or 1)<=1e-6 and (hit.PenetrationDepth or 0)>1e-3 then
  local depth=math.min(100,hit.PenetrationDepth+.5)
  return {x=from.x+n.X*depth,y=from.y+n.Y*depth,z=from.z+n.Z*depth,nx=n.X,ny=n.Y,nz=n.Z}
 end
 return {x=p.X+n.X*.1,y=p.Y+n.Y*.1,z=p.Z+n.Z*.1,nx=n.X,ny=n.Y,nz=n.Z}
end
function M:close()
 local list={};for _,h in pairs(self.handles)do list[#list+1]=h end
 for _,h in ipairs(list)do self:destroy(h)end
 self.materials={};return true
end
return M
