-- One selected-model destruction overlay per world. Original MC crumbling
-- pixels multiply each original face color; never show the gray mask itself.
-- Clip only the current source model, keep at most three uploaded stage buffers.
local identity=require('host.pbz.object_identity')
local valid=require('host.pbz.appearance').valid
local bundle=require('host.pbz.mesh_bundle')
local sha=require('storage.sha256')
local M={}
local field='_mechanism_cracks'
local material_path='/Engine/EngineMaterials/DefaultTextMaterialOpaque.DefaultTextMaterialOpaque'
local white_uv={X=433.5/512,Y=139.5/256}
local eps=1e-6
local function current(o,id)return valid(o)and identity.matches(o,id)end
local function native(world,o)return valid(o)and (not world.engine_valid or world:engine_valid(o))end
local function transform()
  return {Rotation={X=0,Y=0,Z=0,W=1},Translation={X=0,Y=0,Z=0},Scale3D={X=1,Y=1,Z=1}}
end
local function read(path,limit)
  local f=assert(io.open(path,'rb'),'mechanism-crack-file:'..path)
  local n=f:seek('end');f:seek('set',0)
  if not n or n>limit then f:close();error('mechanism-crack-file-size')end
  local raw=f:read('a');f:close();return raw
end
local function state(world)
  local s=world[field];if s then return s end
  assert(type(world.assets)=='string','mechanism-crack-assets-required')
  local root=world.assets..'/mechanism-cracks'
  local manifest=assert(require('dkjson').decode(read(root..'/manifest.json',65536)))
  assert(manifest.schema==1 and manifest.private_local_assets==true and #manifest.stages==10,'mechanism-crack-manifest')
  local stages={}
  for _,row in ipairs(manifest.stages)do
    assert(type(row.stage)=='number'and row.stage%1==0 and row.stage>=0 and row.stage<=9
      and row.path=='textures/destroy_stage_'..row.stage..'.png'and not stages[row.stage]
      and row.samples and row.samples.path=='samples/destroy_stage_'..row.stage..'.gray8'
      and row.samples.bytes==256,'mechanism-crack-stage-entry')
    stages[row.stage]=row
  end
  s={world=world,root=root,stages=stages,masks={},geometry={},order={},report={uploads=0,geometry_builds=0,
    source_builds=0,stages=0,texture_imports=0,material_instances=0,attachments=0,components=0,max_vertices=0}}
  world[field]=s;return s
end
local function material(s)
  if s.material and current(s.material,s.material_id)then return s.material end
  local world=s.world
  local base=StaticFindObject(material_path);if not valid(base)then base=LoadAsset(material_path)end
  assert(native(world,base),'mechanism-crack-material-unavailable')
  s.material=base;s.material_id=identity.capture(base);return base
end
local function mask(s,stage)
  if s.masks[stage]then return s.masks[stage]end
  local row=s.stages[stage];local sample=row.samples
  local raw=read(s.root..'/'..sample.path,256)
  assert(#raw==256 and sha(raw)==sample.sha256,'mechanism-crack-sample-digest')
  for i=1,256 do local value=raw:byte(i);assert(value==0 or value==61 or value==155,'mechanism-crack-sample-value')end
  s.masks[stage]=raw;return raw
end
local function linear(v)return v<=.04045 and v/12.92 or ((v+.055)/1.055)^2.4 end
local function source8(v)
  local srgb=v<=.0031308 and v*12.92 or 1.055*v^(1/2.4)-.055
  return math.min(255,math.max(0,math.floor(srgb*255+.5)))
end
local function crack_color(c,gray)
  local function channel(v)return linear(math.min(255,math.floor(2*source8(v)*gray/255+.5))/255)end
  return {R=channel(c.R),G=channel(c.G),B=channel(c.B),A=1}
end
local function facing(n)
  -- Direction.getFacing scans DOWN, UP, NORTH, SOUTH, WEST, EAST; preserve
  -- that tie order for rotated lever faces. MC(x,y,z) == PBZ(X,Z,-Y).
  local dots={-n.Z,n.Z,n.Y,-n.Y,-n.X,n.X};local best,index=0,3
  for i,d in ipairs(dots)do if d>best then best,index=d,i end end
  return index
end
local function project(p,side)
  local x,y,z=p.X/6.25+8,p.Z/6.25+8,-p.Y/6.25+8
  if side==1 then return x,16-z elseif side==2 then return x,z
  elseif side==3 then return 16-x,16-y elseif side==4 then return x,16-y
  elseif side==5 then return 16-z,16-y else return z,16-y end
end
local function clip(poly,axis,bound,keep_high)
  local out={};if #poly==0 then return out end
  local a=poly[#poly];local av=a[axis]-bound;local inside_a=keep_high and av>=0 or not keep_high and av<=0
  for _,b in ipairs(poly)do
    local bv=b[axis]-bound;local inside_b=keep_high and bv>=0 or not keep_high and bv<=0
    if inside_a~=inside_b then
      local t=av/(av-bv)
      out[#out+1]={X=a.X+(b.X-a.X)*t,Y=a.Y+(b.Y-a.Y)*t,Z=a.Z+(b.Z-a.Z)*t,
        u=a.u+(b.u-a.u)*t,v=a.v+(b.v-a.v)*t}
    end
    if inside_b then out[#out+1]=b end
    a,av,inside_a=b,bv,inside_b
  end
  return out
end
local function prepare(part)
  assert(part and #part.positions<=100000 and #part.positions%4==0 and #part.positions==#part.normals
    and #part.positions==#part.colors,'mechanism-crack-geometry')
  local bins={};local total=0;local colors={}
  for i=1,#part.positions,4 do
    local n,c=part.normals[i],part.colors[i]
    assert(c.A==1,'mechanism-crack-opaque-source-required')
    local side=facing(n);local poly={};local lo_u,lo_v,hi_u,hi_v=math.huge,math.huge,-math.huge,-math.huge
    for j=i,i+3 do
      local p=part.positions[j];local u,v=project(p,side);local color=part.colors[j]
      assert(color.R==c.R and color.G==c.G and color.B==c.B and color.A==c.A,'mechanism-crack-uniform-source-quad')
      poly[#poly+1]={X=p.X,Y=p.Y,Z=p.Z,u=u,v=v}
      lo_u,lo_v,hi_u,hi_v=math.min(lo_u,u),math.min(lo_v,v),math.max(hi_u,u),math.max(hi_v,v)
    end
    local min_u,max_u=math.floor(lo_u+eps),math.ceil(hi_u-eps)-1
    local min_v,max_v=math.floor(lo_v+eps),math.ceil(hi_v-eps)-1
    assert(max_u-min_u<64 and max_v-min_v<64,'mechanism-crack-projection-bounds')
    local ck=source8(c.R)*65536+source8(c.G)*256+source8(c.B)
    local shades=colors[ck]
    if not shades then shades={[61]=crack_color(c,61),[155]=crack_color(c,155)};colors[ck]=shades end
    for y=min_v,max_v do for x=min_u,max_u do
      local cell=clip(clip(clip(clip(poly,'u',x,true),'u',x+1,false),'v',y,true),'v',y+1,false)
      local clean={}
      for _,p in ipairs(cell)do
        local last=clean[#clean]
        if not last or (p.X-last.X)^2+(p.Y-last.Y)^2+(p.Z-last.Z)^2>eps*eps then clean[#clean+1]=p end
      end
      if #clean>2 then
        local a,b=clean[1],clean[#clean]
        if (a.X-b.X)^2+(a.Y-b.Y)^2+(a.Z-b.Z)^2<=eps*eps then clean[#clean]=nil end
      end
      -- Plane clipping can retain a source corner on a pixel boundary. Drop
      -- collinear corners so the triangle fan never uploads zero-area faces.
      local changed=true
      while changed and #clean>3 do
        changed=false
        for j=1,#clean do
          local a,b,c=clean[(j-2)%#clean+1],clean[j],clean[j%#clean+1]
          if math.abs((b.u-a.u)*(c.v-b.v)-(b.v-a.v)*(c.u-b.u))<=1e-8 then
            table.remove(clean,j);changed=true;break
          end
        end
      end
      if #clean>=3 then
        local area=0;local a=clean[1]
        for j=2,#clean-1 do
          local b,d=clean[j],clean[j+1];local bx,by,bz=b.X-a.X,b.Y-a.Y,b.Z-a.Z
          local dx,dy,dz=d.X-a.X,d.Y-a.Y,d.Z-a.Z
          area=area+(by*dz-bz*dy)*n.X+(bz*dx-bx*dz)*n.Y+(bx*dy-by*dx)*n.Z
        end
        if math.abs(area)>eps then
          local pts={}
          for j=1,#clean do local p=clean[area>0 and j or #clean-j+1]
            pts[j]={X=p.X+n.X*.1,Y=p.Y+n.Y*.1,Z=p.Z+n.Z*.1}
          end
          local at=(y%16)*16+x%16+1;bins[at]=bins[at]or {}
          bins[at][#bins[at]+1]={positions=pts,normal=n,shades=shades};total=total+#pts
          assert(total<=100000,'mechanism-crack-clipped-vertex-budget')
        end
      end
    end end
  end
  return bins,total
end
local function geometry(s,stage)
  if s.geometry[stage]then return s.geometry[stage]end
  local pixels=mask(s,stage)
  local out={positions={},normals={},triangles={},uv={},colors={}}
  for cell,pieces in pairs(s.prepared)do
    local gray=pixels:byte(cell)
    if gray~=0 then for _,piece in ipairs(pieces)do
      local offset=#out.positions;local color=piece.shades[gray]
      for _,p in ipairs(piece.positions)do
        out.positions[#out.positions+1]=p;out.normals[#out.normals+1]=piece.normal
        out.colors[#out.colors+1]=color;out.uv[#out.uv+1]=white_uv
      end
      for j=2,#piece.positions-1 do
        out.triangles[#out.triangles+1]=offset;out.triangles[#out.triangles+1]=offset+j-1;out.triangles[#out.triangles+1]=offset+j
      end
    end end
  end
  s.geometry[stage]=out;s.order[#s.order+1]=stage
  while #s.order>3 do s.geometry[table.remove(s.order,1)]=nil end
  s.report.geometry_builds=s.report.geometry_builds+1;s.report.max_vertices=math.max(s.report.max_vertices,#out.positions)
  return out
end
local function clear(handle)
  local entry=handle and handle[field];if not entry then return true end
  entry.retiring=true
  local s=entry.owner;local world=s.world
  if current(entry.component,entry.id)and native(world,entry.component)then
    entry.component:SetHiddenInGame(true,false);entry.component:SetVisibility(false,false)
    entry.component:SetCollisionEnabled(0)
    if current(handle.actor,entry.actor_id)then entry.component:K2_DestroyComponent(handle.actor)end
  end
  handle[field]=nil;if s.active==handle then s.active=nil end
  s.report.components=0;return true
end
function M.clear(handle)
  local ok,why=pcall(clear,handle);return ok,not ok and tostring(why)or nil
end
function M.setup(world,handle,stage)
  if stage==nil then return M.clear(handle)end
  local ok,why=pcall(function()
    assert(type(stage)=='number'and stage%1==0 and stage>=0 and stage<=9,'mechanism-crack-stage')
    assert(not world.is_current or world:is_current(),'mechanism-crack-world-stale')
    assert(handle and type(handle.model)=='string'and native(world,handle.actor)and native(world,handle.mesh),
      'mechanism-crack-handle-stale')
    local s=state(world)
    if s.active and s.active~=handle then assert(M.clear(s.active))end
    local entry=handle[field]
    if entry and (entry.retiring or entry.owner~=s or not current(entry.component,entry.id)
        or not current(handle.actor,entry.actor_id)or not current(handle.mesh,entry.mesh_id))then
      assert(M.clear(handle));entry=nil
    end
    if s.geometry_model~=handle.model then
      local source=world:part(handle.model)
      -- These retain original transparent layers and break instantly. There is
      -- no opaque overlay approximation over the scene visible through them.
      if source.translucent_two_sided then assert(M.clear(handle));return end
      s.prepared,s.prepared_vertices=prepare(source);s.geometry_model=handle.model;s.geometry={};s.order={}
      s.report.source_builds=s.report.source_builds+1
    end
    local base=material(s)
    if not entry then
      local component=handle.actor:AddComponentByClass(StaticFindObject('/Script/ProceduralMeshComponent.ProceduralMeshComponent'),
        true,transform(),false)
      assert(native(world,component),'mechanism-crack-component-create')
      entry={component=component,id=identity.capture(component),actor_id=identity.capture(handle.actor),
        mesh_id=identity.capture(handle.mesh),owner=s}
      handle[field]=entry;s.active=handle -- retain partial allocation for cleanup
      component:SetHiddenInGame(true,false);component:SetCollisionEnabled(0);component:SetCastShadow(false)
      component:SetCullDistance(20000)
      assert(component:K2_AttachToComponent(handle.mesh,FName('None'),2,2,2,false),'mechanism-crack-attachment')
      assert(identity.matches(component:GetAttachParent(),entry.mesh_id),'mechanism-crack-parent-readback')
      if handle.mesh.bVisibleInSceneCaptureOnly then component:SetVisibleInSceneCaptureOnly(true)end
      s.report.attachments=s.report.attachments+1;s.report.components=1
    end
    if entry.model~=handle.model or entry.stage~=stage then
      local part=geometry(s,stage)
      entry.component:ClearAllMeshSections()
      if #part.positions>0 then bundle.apply(entry.component,part)end
      entry.model=handle.model;entry.stage=stage;s.report.uploads=s.report.uploads+1;s.report.stages=s.report.stages+1
    end
    if entry.material_id~=s.material_id then entry.component:SetMaterial(0,base);entry.material_id=s.material_id end
    local visible=handle.active~=false
    if entry.visible~=visible then entry.component:SetVisibility(visible,false);entry.visible=visible end
    if not entry.exposed then entry.component:SetHiddenInGame(false,false);entry.exposed=true end
  end)
  if not ok then
    local clean,clean_why=M.clear(handle)
    return false,tostring(why)..(clean and ''or '; cleanup: '..tostring(clean_why))
  end
  return true
end
function M.close(world)
  local s=world[field];if not s then return true end
  local ok,why=M.clear(s.active);if not ok then return false,why end
  s.masks={};s.material=nil;s.material_id=nil;s.prepared=nil;s.geometry={};s.order={};s.geometry_model=nil;s.world=nil;world[field]=nil
  return true
end
function M.state(world)
  local s=world[field];if not s then return {active=false,components=0,texture_imports=0,uploads=0}end
  local out={};for k,v in pairs(s.report)do out[k]=v end
  out.active=s.active and s.active.id or false;out.cached_stages=#s.order
  out.prepared_vertices=s.prepared_vertices or 0;return out
end
return M
