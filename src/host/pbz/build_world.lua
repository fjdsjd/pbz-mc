-- All native object/physics operations for buildings live in this adapter.
-- Called only on the game thread. No native handles enter storage records.
local UE=require('UEHelpers')
local geometry=require('rules.placement_geometry')
local identity=require('host.pbz.object_identity')
local MeshBundle=require('host.pbz.mesh_bundle')
local Faces=require('rules.block_faces')
local M={};M.__index=M
-- All reflected EObjectTypeQuery values, verified in PBZ; cached once, not
-- rebuilt per placement. Query all objects so native terrain cannot mask an
-- overlapping character or MC collider behind the first blocking trace hit.
local object_types={}
for i=0,31 do object_types[#object_types+1]=i end
M.object_types=object_types
local function valid(o) return o and o:IsValid() end
local function v(x,y,z) return {X=x,Y=y,Z=z} end
-- PBZ walls need not coincide with a grid face. Keep the electrical cell on
-- the lattice and bind the rendered torch and its aim box to the hit surface.
local function mounted_position(r)
  local p=r.properties
  if p and p.wall_inset and r.content_id=='pbzmc:redstone_torch' and p.face=='wall' then
    local d=require('rules.block_directions').vectors[p.facing or 'north']
    return r.x-d.x*p.wall_inset,r.y-d.y*p.wall_inset,r.z
  end
  return r.x,r.y,r.z
end
local function transform()
  return {Rotation={X=0,Y=0,Z=0,W=1},Translation=v(0,0,0),Scale3D=v(1,1,1)}
end
local function hit_object(hit)
  local ok,obj=pcall(function() return hit.HitObjectHandle.ReferenceObject:Get() end)
  return ok and valid(obj) and obj or nil
end
function M.new(registry,log,assets)
  local pawn=require('host.pbz.local_player').pawn()
  assert(valid(pawn) and not pawn:GetFullName():find('SpectatorPawn',1,true),'gameplay-pawn-required')
  local world=pawn:GetWorld()
  local self=setmetatable({pawn=pawn,world=world,world_id=world:GetFullName():gsub('^World ',''),
    pawn_identity=identity.capture(pawn),world_identity=identity.capture(world),
    registry=registry,log=log or function() end,by_actor={},assets=assets,mesh_cache={},
    face_cache={},surface_cache={},surface_keys={},crack_keys={},crack_surfaces={},faces=Faces.new(),face_queue={},face_head=1,
    catalog=require('host.pbz.building_assets').open(assets..'/building-blocks'),preload_index=1},M)
  assert(self:engine_valid(pawn),'native-validity-preflight-failed')
  return self
end
function M:engine_valid(object)
  if not valid(object) then return false end
  -- IsValid is also a UE4SS wrapper method. Calling system:IsValid(object)
  -- would test the system library itself; explicitly dispatch the UFunction.
  local fn=StaticFindObject('/Script/Engine.KismetSystemLibrary:IsValid')
  assert(valid(fn),'native-validity-function-unavailable')
  -- The installed fork's CallFunction wrapper fails to recognize its UFunction
  -- argument. Direct UFunction invocation accepts an explicit calling context.
  local result=fn(UE.GetKismetSystemLibrary(),object)
  assert(type(result)=='boolean','native-validity-result-unavailable')
  return result
end
function M:is_current()
  local pawn=require('host.pbz.local_player').pawn()
  return identity.matches(pawn,self.pawn_identity) and identity.matches(pawn:GetWorld(),self.world_identity)
end
function M:restore_distance(record)
  local p=self.pawn:K2_GetActorLocation()
  return (p.X-record.x)^2+(p.Y-record.y)^2+(p.Z-record.z)^2
end
function M:box_trace(start,finish,half,yaw)
  assert(self:is_current(),'stale-native-world')
  local hit,color={},{R=0,G=0,B=0,A=0}
  local yes=UE.GetKismetSystemLibrary():BoxTraceSingle(self.pawn,start,finish,
    v(half.x,half.y,half.z),{Pitch=0,Yaw=yaw,Roll=0},0,false,{self.pawn},0,hit,true,color,color,0)
  return yes,hit
end
function M:line_trace(start,finish,ignore_actors)
  assert(self:is_current(),'stale-native-world')
  local hit,color={},{R=0,G=0,B=0,A=0}
  local ignored={self.pawn}
  for _,actor in ipairs(ignore_actors or {})do if valid(actor)then ignored[#ignored+1]=actor end end
  local yes=UE.GetKismetSystemLibrary():LineTraceSingle(self.pawn,start,finish,0,false,ignored,0,hit,true,color,color,0)
  return yes,hit
end
function M:overlap_components(center,half,ignored)
  local out={}
  self.primitive_class=self.primitive_class or StaticFindObject('/Script/Engine.PrimitiveComponent')
  UE.GetKismetSystemLibrary():BoxOverlapComponents(self.pawn,center,v(half.x,half.y,half.z),
    object_types,self.primitive_class,ignored or {self.pawn},out)
  return out
end
function M:placement_obstacle(component,piston_rider)
  -- OutComponents contains UE4SS array parameter wrappers, unlike a direct
  -- UObject return. Unwrap before calling reflected component methods.
  if not component.GetFullName then component=component:get() end
  local owner=component:GetOwner()
  if not valid(owner) then return 'unknown-collider' end
  local handle=self.by_actor[owner:GetFullName()]
  if handle and handle.active and identity.matches(owner,handle.identity) then return 'mc-block',handle end
  if piston_rider and piston_rider(owner)then return 'ignored' end
  local pawn_response=component:GetCollisionResponseToChannel(2)
  self.pawn_class=self.pawn_class or StaticFindObject('/Script/Engine.Pawn')
  if owner:IsA(self.pawn_class) then
    if pawn_response==2 or component:GetCollisionResponseToChannel(3)==2 then return 'character' end
    return 'ignored'
  end
  -- Music/quest volumes and water are not solid occupancy. Fixed native
  -- geometry may intersect the cube; movable solid props remain blockers.
  if pawn_response~=2 then return 'ignored' end
  if component:GetCollisionObjectType()==0 or component.Mobility==0 then return 'terrain' end
  -- PBZ also builds fixed level walls from movable DynamicMeshComponents.
  -- Geometry type, not a particular enemy/level asset name, identifies these.
  -- Keep physics bodies and animated skeletal actors out of this allowance.
  self.mesh_class=self.mesh_class or StaticFindObject('/Script/Engine.MeshComponent')
  self.skeletal_class=self.skeletal_class or StaticFindObject('/Script/Engine.SkeletalMeshComponent')
  if component:GetCollisionObjectType()~=5 and component:IsA(self.mesh_class) and not component:IsA(self.skeletal_class) then return 'terrain' end
  return 'dynamic-collider'
end
function M:mechanism_catalog()
  self.mechanisms=self.mechanisms or require('host.pbz.mechanism_assets').open(self.assets..'/mechanism-blocks')
  return self.mechanisms
end
function M:model(record)
  local definition=self.registry.get(record.content_id)
  if definition.fluid then return 'fluid/'..definition.fluid end
  if definition.mechanism then return self:mechanism_catalog():model(record)end
  return self.catalog:model(record)
end
function M:boxes(record)
  local definition=self.registry.get(record.content_id)
  if definition.fluid then return {}end
  if definition.mechanism then
    local catalog=self:mechanism_catalog();local boxes=catalog:boxes(record)
    if #boxes>0 then return boxes end
    -- Non-solid vanilla devices still need a visibility-only selection
    -- shape. Their manifest collision boxes are deliberately empty.
    local bounds=catalog.manifest.models[catalog:model(record)].bounds_cm
    local center,half={},{}
    for i=1,3 do
      -- The vanilla wall-torch artwork overlaps its support by almost 6 cm.
      -- Keep the original mesh, but confine its selection volume to its own cell.
      local lo,hi=math.max(-50,bounds[i][1]),math.min(50,bounds[i][2])
      center[i]=(lo+hi)*.5;half[i]=math.max(.5,(hi-lo)*.5)
    end
    return {{center=center,half=half}}
  end
  local h=definition.half;return {{center={0,0,0},half={h.x,h.y,h.z}}}
end
local function interior_box(x,y,z,c,s,shape)
  local o,h=shape.center,shape.half
  return v(x+o[1]*c-o[2]*s,y+o[1]*s+o[2]*c,z+o[3]),{
    x=math.max(.05,math.abs(c)*(h[1]-.5)+math.abs(s)*(h[2]-.5)),
    y=math.max(.05,math.abs(s)*(h[1]-.5)+math.abs(c)*(h[2]-.5)),z=math.max(.05,h[3]-.5)}
end
local function needs_placement(a,b)
  return b and (not a or a.content_id~=b.content_id or a.x~=b.x or a.y~=b.y or a.z~=b.z)
end
-- A negative overlap of this enclosing box proves every enclosed placement
-- is clear. In a crowded or irregular scene, keep the individual shape checks.
function M:piston_destinations_clear(rows,piston_rider)
  local destinations=0
  for _,row in ipairs(rows)do
    local a,b=row.before,row.after
    if needs_placement(a,b) then destinations=destinations+1 end
  end
  if destinations<3 then return false end
  local minx,miny,minz=math.huge,math.huge,math.huge
  local maxx,maxy,maxz=-minx,-miny,-minz
  local ignored={self.pawn}
  for _,row in ipairs(rows)do
    local a,b=row.before,row.after
    if row.handle and row.handle.active and identity.matches(row.handle.actor,row.handle.identity) then
      ignored[#ignored+1]=row.handle.actor
    end
    if needs_placement(a,b) then
      local x,y,z=mounted_position(b);local c,s=math.cos(math.rad(b.yaw)),math.sin(math.rad(b.yaw))
      for _,shape in ipairs(self:boxes(b))do
        local p,h=interior_box(x,y,z,c,s,shape)
        minx,miny,minz=math.min(minx,p.X-h.x),math.min(miny,p.Y-h.y),math.min(minz,p.Z-h.z)
        maxx,maxy,maxz=math.max(maxx,p.X+h.x),math.max(maxy,p.Y+h.y),math.max(maxz,p.Z+h.z)
      end
    end
  end
  if minx>maxx then return false end
  -- Small outward margin keeps the float-converted broad phase conservative.
  local center=v((minx+maxx)*.5,(miny+maxy)*.5,(minz+maxz)*.5)
  local pad=math.max(.125,math.abs(center.X)*2e-7,math.abs(center.Y)*2e-7,math.abs(center.Z)*2e-7)
  local extent={x=(maxx-minx)*.5+pad,y=(maxy-miny)*.5+pad,z=(maxz-minz)*.5+pad}
  local found=self:overlap_components(center,extent,ignored)
  if #found>32 then return false end
  for _,component in ipairs(found)do
    if self:placement_obstacle(component,piston_rider)~='ignored' then return false end
  end
  return true
end
function M:can_place(record,ignored,options,destinations_clear)
  assert(self:is_current() and record.world==self.world_id,'stale-native-world')
  local definition=assert(self.registry.get(record.content_id),'unsupported-content')
  local p=self.pawn:K2_GetActorLocation()
  local capsule=self.pawn.CapsuleComponent
  local c,s=math.cos(math.rad(record.yaw)),math.sin(math.rad(record.yaw))
  local rx,ry,rz=mounted_position(record)
  local dx,dy=p.X-rx,p.Y-ry
  local report={terrain=0,components=0};self.last_placement_check=report
  if definition.fluid then return true end
  local piston_rider=options and options.piston_rider
  local player_seated=piston_rider and piston_rider(self.pawn)
  for _,shape in ipairs(self:boxes(record))do
  local h={x=shape.half[1],y=shape.half[2],z=shape.half[3]};local o=shape.center
  if not player_seated and definition.collision~=false and geometry.capsule_overlaps(dx*c+dy*s-o[1],-dx*s+dy*c-o[2],p.Z-rz-o[3],h.x,h.y,h.z,
    capsule:GetScaledCapsuleRadius(),capsule:GetScaledCapsuleHalfHeight()) then
    report.blocked='player';return false,'player'
  end
  -- Test the interior; touching a supporting floor/adjacent cube is legal.
  -- Current full blocks have yaw=0. An enclosing AABB stays conservative for
  -- historical rotated records instead of silently ignoring their corners.
  if not destinations_clear then
  local center,interior=interior_box(rx,ry,rz,c,s,shape)
  for _,component in ipairs(self:overlap_components(center,interior)) do
    report.components=report.components+1
    local kind,handle=self:placement_obstacle(component,piston_rider)
    if handle and ignored and ignored[handle.id]then kind='ignored'end
    if kind=='terrain' then
      report.terrain=report.terrain+1
      if options and options.native_solid then report.blocked='native-terrain';return false,'native-terrain'end
    elseif kind~='ignored' then report.blocked=kind;return false,kind end
  end
  end
  end
  return true
end
function M:part(model)
  if model:sub(1,17)=='mechanism-blocks/'then return self:mechanism_catalog():part(model)end
  local part=self.mesh_cache[model]
  if part then return part end
  if model:sub(1,16)=='building-blocks/' then
    part=self.catalog:part(model);self.mesh_cache[model]=part
    if model:match('_crack_%d$') then
      self.crack_keys[#self.crack_keys+1]=model
      if #self.crack_keys>12 then
        local old=table.remove(self.crack_keys,1);self.mesh_cache[old]=nil;self.face_cache[old]=nil
      end
    end
    return part
  end
  if model=='tnt/tnt' then
    part=require('host.pbz.tnt_assets').open(self.assets..'/tnt'):part('tnt.mesh')
    self.mesh_cache[model]=part;return part
  end
  if not self.asset_records then
    local file=assert(io.open(self.assets..'/sources.json','rb'));local raw=file:read('a');file:close()
    local manifest=assert(require('dkjson').decode(raw));self.asset_records={}
    for _,entry in ipairs(manifest.meshes) do self.asset_records[entry.name]=entry end
  end
  local entry=assert(self.asset_records[model],'unlisted-block-model')
  local file=assert(io.open(self.assets..'/'..model..'.mesh','rb'));local raw=file:read('a');file:close()
  assert(require('storage.sha256')(raw)==entry.sha256,'block-model-digest')
  part=assert(MeshBundle.decode(raw,6.25)[1])
  for _,uv in ipairs(part.uv) do uv.X=433.5/512;uv.Y=139.5/256 end
  self.mesh_cache[model]=part;return part
end
function M:set_crack(handle,model,stage)
  if handle.stage==stage then return end
  if handle.mechanism then
    if not handle.fluid then
      local ok,why=require('host.pbz.mechanism_cracks').setup(self,handle,stage);assert(ok,why)
    end
    handle.stage=stage;return
  end
  handle.stage=stage
  if handle.cubic then self:refresh_faces(handle)
  else MeshBundle.apply(handle.mesh,self:part(stage and handle.model..'_crack_'..stage or handle.model)) end
end
function M:warm_cracks(model)
  if model:sub(1,17)=='mechanism-blocks/'or model:sub(1,6)=='fluid/'then return end
  if self.warm_model==model then return end
  self.warm_model=model;self.warm_stage=0
end
function M:prewarm()
  -- One bounded read/decode per game frame; never all ten stages during a
  -- mouse action. Existing cubes share the same immutable geometry.
  if self.warm_model and self.warm_stage<=9 then
    local model=self.warm_model..'_crack_'..self.warm_stage
    self.warm_stage=self.warm_stage+1;self:part(model);return
  end
  local model=self.catalog.base_keys[self.preload_index]
  if model then self.preload_index=self.preload_index+1;self:part(model) end
end
function M:queue_faces(handle)
  if handle and handle.cubic and not handle.face_queued then
    handle.face_queued=true;self.face_queue[#self.face_queue+1]=handle
  end
end
function M:queue_neighbors(handle)
  for i=1,6 do self:queue_faces(self.faces:neighbor(handle,i)) end
end
function M:refresh_faces(handle)
  if not handle.active or not handle.cubic then return end
  local model=handle.model..(handle.stage~=nil and '_crack_'..handle.stage or '')
  local parts=self.face_cache[model]
  if not parts then parts=Faces.split(self:part(model));self.face_cache[model]=parts end
  local mask=0;for i=1,6 do if not Faces.occludes(handle,self.faces:neighbor(handle,i)) then mask=mask|(1<<(i-1)) end end
  if handle.surface_model==model and handle.face_mask==mask then return end
  if mask==0 then handle.mesh:ClearMeshSection(0)
  else
    local key=model..':'..mask;local part=self.surface_cache[key]
    if not part then
      part=Faces.combine(parts,mask);self.surface_cache[key]=part
      local order=handle.stage~=nil and self.crack_surfaces or self.surface_keys
      order[#order+1]=key
      local limit=handle.stage~=nil and 12 or 96
      if #order>limit then self.surface_cache[table.remove(order,1)]=nil end
    end
    -- One section per block keeps draw calls unchanged; six sections would
    -- multiply the cost for sparse buildings even if fewer pixels were drawn.
    MeshBundle.apply(handle.mesh,part)
  end
  handle.face_mask=mask;handle.surface_model=model
end
function M:poll_faces(limit)
  local count=0
  while self.face_head<=#self.face_queue and count<limit do
    local handle=self.face_queue[self.face_head];self.face_head=self.face_head+1
    handle.face_queued=false
    if handle.active and handle.cubic then self:refresh_faces(handle) end
    count=count+1
  end
  if self.face_head>#self.face_queue then self.face_queue={};self.face_head=1 end
end
function M:render_stats()
  local blocks,faces,sections=0,0,0
  for _,h in pairs(self.by_actor) do
    if h.active then
      blocks=blocks+1
      if (h.face_mask or 0)>0 then sections=sections+1 end
      for i=0,5 do if ((h.face_mask or 0)&(1<<i))~=0 then faces=faces+1 end end
    end
  end
  return {blocks=blocks,visible_faces=faces,draw_sections=sections,full_cube_faces=blocks*6,queued=#self.face_queue-self.face_head+1,
    crack_meshes=#self.crack_keys,crack_surfaces=#self.crack_surfaces,base_surfaces=#self.surface_keys,assets=self.catalog.report}
end
function M:hit_handle(hit)
  local owner=self:hit_actor(hit)
  local handle=valid(owner) and self.by_actor[owner:GetFullName()]
  if handle and handle.active and identity.matches(owner,handle.identity) then return handle end
end
function M:hit_actor(hit)
  local object=hit_object(hit)
  if not object then return end
  return object:IsA(StaticFindObject('/Script/Engine.Actor')) and object or object:GetOwner()
end
function M:ground_position(content_id,impact,yaw)
  local h=assert(self.registry.get(content_id),'unsupported-content').half
  local bottom=v(impact.X,impact.Y,impact.Z+h.z-2)
  for rise=0,100,25 do
    local start=v(bottom.X,bottom.Y,bottom.Z+rise+4)
    if not self:box_trace(start,v(start.X,start.Y,start.Z+.1),h,yaw) then
      local yes,hit=self:box_trace(start,bottom,h,yaw)
      if yes then
        local object=hit_object(hit)
        local owner=object and object:GetOwner()
        if not valid(owner) or not owner:IsA(StaticFindObject('/Script/Engine.Character')) then
          return {x=hit.Location.X,y=hit.Location.Y,z=hit.Location.Z+2,yaw=yaw}
        end
      end
    end
  end
  return nil,'no-free-ground-footprint'
end
function M:test_ground_target(content_id)
  local p,f=self.pawn:K2_GetActorLocation(),self.pawn:GetActorForwardVector()
  local x,y=p.X+250*f.X,p.Y+250*f.Y
  local yes,hit=self:line_trace(v(x,y,p.Z+100),v(x,y,p.Z-1000))
  if not yes then return nil,'no-test-ground' end
  return self:ground_position(content_id,hit.ImpactPoint,0)
end
function M:material_for(record,model)
  local definition=self.registry.get(record.content_id)
  local entry=definition.mechanism and not definition.fluid and self:mechanism_catalog().manifest.models[model]
  if entry and entry.render_layer=='translucent'then
    return require('host.pbz.translucent_blocks').cached(self,self.pawn,self.assets..'/mechanism-blocks',entry.palette)
  end
  if not valid(self.material)or not identity.matches(self.material,self.material_id)then
    self.material=LoadAsset('/Engine/EngineMaterials/DefaultTextMaterialOpaque.DefaultTextMaterialOpaque')
    assert(valid(self.material),'vertex-color-material-unavailable');self.material_id=identity.capture(self.material)
  end
  return self.material
end
function M:create(record)
  assert(self:is_current() and record.world==self.world_id,'stale-native-world')
  local definition=assert(self.registry.get(record.content_id),'unsupported-content')
  assert(type(self.assets)=='string','private-assets-not-configured')
  local model=self:model(record)
  if record.content_id=='pbzmc:piston_head' and self.head_pool then
    for i,spare in ipairs(self.head_pool)do
      if spare.model==model and self:engine_valid(spare.actor)then
        table.remove(self.head_pool,i);spare.record=record;spare.id=record.id
        local ok,why=pcall(function()
          spare.actor:K2_SetActorLocationAndRotation(v(record.x,record.y,record.z),{Pitch=0,Yaw=record.yaw,Roll=0},false,{},true)
          self:set_active(spare,true)
          self.by_actor[spare.identity.name]=spare
        end)
        if not ok then error({reason=why,cleanup_handle=spare})end
        return spare
      end
    end
  end
  local mesh_data=not definition.fluid and self:part(model)or nil
  local material=self:material_for(record,model)
  assert(valid(material),'vertex-color-material-unavailable')
  local p=v(mounted_position(record))
  local actor=self.world:SpawnActor(StaticFindObject('/Script/Engine.Actor'),p,{Pitch=0,Yaw=record.yaw,Roll=0})
  assert(valid(actor),'actor-create-failed')
  local handle={actor=actor,identity=identity.capture(actor),id=record.id,record=record,model=model,
    mechanism=definition.mechanism,fluid=definition.fluid,
    cubic=not definition.mechanism and definition.full_cube==true and record.yaw%360==0,opaque=definition.opaque_cube~=false,cull_same=definition.cull_same,
    sections={},rendered=false,colliding=false,active=false}
  local ok,err=pcall(function()
    handle.root=actor:AddComponentByClass(StaticFindObject('/Script/Engine.SceneComponent'),false,transform(),false)
    assert(valid(handle.root),'building-root-create-failed')
    handle.boxes={};self:update_boxes(handle,record)
    actor:K2_SetActorLocation(p,false,{},true)
    actor:K2_SetActorRotation({Pitch=0,Yaw=record.yaw,Roll=0},true)
    handle.mesh=actor:AddComponentByClass(StaticFindObject('/Script/ProceduralMeshComponent.ProceduralMeshComponent'),false,transform(),false)
    assert(valid(handle.mesh),'mesh-create-failed')
    handle.mesh:SetCollisionEnabled(0)
    handle.mesh:SetCullDistance(20000)
    handle.mesh:SetMaterial(0,material)
    if definition.fluid then
      local yes,reason=self:fluid_renderer():attach(handle,record);assert(yes,reason)
    elseif not handle.cubic then MeshBundle.apply(handle.mesh,mesh_data) end
    assert(self:set_active(handle,true),'native-activation-failed')
    if handle.cubic then self:refresh_faces(handle) end
    handle.rendered=true;handle.colliding=true
    self.by_actor[actor:GetFullName()]=handle
    self:light(handle,definition.light)
  end)
  if not ok then
    local clean,removed=pcall(self.destroy,self,handle)
    if not clean or not removed then error({reason=tostring(err),cleanup_handle=handle}) end
    error(err)
  end
  self:warm_cracks(model)
  return handle
end
function M:fluid_renderer()
  if not self.fluid_visual then self.fluid_visual=require('host.pbz.fluid_visual').new(self,self.assets..'/mechanism-blocks')end
  return self.fluid_visual
end
function M:light(handle,level)
  local enabled=level and (handle.record.properties or {}).lit~=false
  if not enabled then
    if valid(handle.light)then handle.light:SetVisibility(false,false)end
    if handle.light_counted then self.light_count=math.max(0,(self.light_count or 1)-1);handle.light_counted=false end
    handle.light_enabled=false;return
  end
  if not handle.light_counted and (self.light_count or 0)>=16 then handle.light_enabled=false;return end
  local ok,why=pcall(function()
    local light=handle.light
    if not valid(light)then light=handle.actor:AddComponentByClass(StaticFindObject('/Script/Engine.PointLightComponent'),false,transform(),false)end
    assert(valid(light),'light-component-unavailable');handle.light=light
    light:SetCastShadows(false);light:SetIntensity(level*35);light:SetAttenuationRadius(level*65)
    handle.light_enabled=true;light:SetVisibility(handle.active,false)
    if not handle.light_counted then self.light_count=(self.light_count or 0)+1;handle.light_counted=true end
  end)
  if not ok then self.log('mechanism light unavailable '..tostring(why))end
end
function M:update_boxes(handle,record)
  local definition=self.registry.get(record.content_id);local shapes=self:boxes(record)
  local applied=handle.applied_boxes
  local same=applied and #applied==#shapes and handle.applied_query==(definition.collision==false)
  if same then
    for i,shape in ipairs(shapes)do
      for axis=1,3 do
        if shape.center[axis]~=applied[i].center[axis] or shape.half[axis]~=applied[i].half[axis] then same=false;break end
      end
      if not same then break end
    end
    if same then return end
  end
  handle.applied_boxes=nil
  handle.boxes=handle.boxes or (handle.box and {handle.box}or {})
  for i,shape in ipairs(shapes)do
    local box=handle.boxes[i]
    if not valid(box)then
      box=handle.actor:AddComponentByClass(StaticFindObject('/Script/Engine.BoxComponent'),false,transform(),false)
      assert(valid(box),'box-create-failed');handle.boxes[i]=box
      box:SetCollisionObjectType(1)
    end
    box:SetBoxExtent(v(math.max(.1,shape.half[1]),math.max(.1,shape.half[2]),math.max(.1,shape.half[3])),false)
    box:K2_SetRelativeLocation(v(shape.center[1],shape.center[2],shape.center[3]),false,{},true)
    box:SetCollisionResponseToAllChannels(definition.collision==false and 0 or 2)
    if definition.collision==false then box:SetCollisionResponseToChannel(3,2)end -- query aim, no pawn barrier
    box:SetCollisionEnabled(handle.active and (definition.collision==false and 1 or 3)or 0)
  end
  for i=#shapes+1,#handle.boxes do handle.boxes[i]:SetCollisionEnabled(0)end
  handle.box=handle.boxes[1];handle.box_count=#shapes;handle.collision_mode=definition.collision==false and 1 or 3
  handle.applied_boxes=shapes;handle.applied_query=definition.collision==false
end
function M:revise(handle,record,options)
  assert(self:is_current()and self:engine_valid(handle.actor),'stale-building-revision')
  options=options or {};local old=handle.record;local model=self:model(record)
  local definition=self.registry.get(record.content_id)
  local ox,oy,oz=mounted_position(old)
  local x,y,z=mounted_position(record)
  local moved=ox~=x or oy~=y or oz~=z or old.yaw~=record.yaw
  if handle.cubic and (moved or model~=handle.model)then self.faces:remove(handle);self:queue_neighbors(handle)end
  if model~=handle.model or handle.visual_uncertain then
    local previous=not handle.visual_uncertain and handle.model
    handle.visual_uncertain=true
    if handle._mechanism_cracks then
      local ok,why=require('host.pbz.mechanism_cracks').clear(handle);assert(ok,why)
    end
    if handle.fluid and not definition.fluid and self.fluid_visual then self.fluid_visual:remove(handle)end
    handle.model=model;handle.mechanism=definition.mechanism;handle.fluid=definition.fluid
    handle.cubic=not definition.mechanism and definition.full_cube==true and record.yaw%360==0
    handle.opaque=definition.opaque_cube~=false;handle.cull_same=definition.cull_same
    handle.surface_model=nil;handle.face_mask=nil;handle.stage=nil
    self:update_boxes(handle,record)
    if definition.fluid then
      if handle.spare_model then
        require('host.pbz.mechanism_sections').clear(self,handle);handle.mesh:ClearAllMeshSections()
      end
      local renderer=self:fluid_renderer()
      local yes,reason
      if handle.fluid_visual then yes,reason=renderer:update(handle,record)else yes,reason=renderer:attach(handle,record)end
      assert(yes,reason)
    else
      require('host.pbz.mechanism_sections').switch(self,handle,record,model,previous)
    end
    handle.visual_uncertain=nil
  elseif definition.fluid then local yes,reason=self:fluid_renderer():update(handle,record);assert(yes,reason)end
  handle.record=record
  if definition.light or handle.light_counted then self:light(handle,definition.light)end
  if moved then
    handle.actor:K2_SetActorLocation(v(x,y,z),false,{},true)
    if old.yaw~=record.yaw or options.rollback then handle.actor:K2_SetActorRotation({Pitch=0,Yaw=record.yaw,Roll=0},true)end
    if options.animate and not options.rollback then
      handle.motion={x=ox-x,y=oy-y,z=oz-z,start=self.mechanism_now or 0,duration=.1}
      self.motions=self.motions or {};self.motions[handle.id]=handle
      handle.mesh:K2_SetRelativeLocation(v(handle.motion.x,handle.motion.y,handle.motion.z),false,{},true)
    end
  end
  if options.rollback then handle.motion=nil;if self.motions then self.motions[handle.id]=nil end;handle.mesh:K2_SetRelativeLocation(v(0,0,0),false,{},true)end
  if handle.cubic then self.faces:put(handle);self:queue_faces(handle);self:queue_neighbors(handle)end
  if not handle.active or handle.activation_uncertain then return self:set_active(handle,true)end
  return true
end
function M:tick_mechanisms(now)
  self.mechanism_now=now
  for id,handle in pairs(self.motions or {})do
    local m=handle.motion
    if handle.active and m then
      local left=math.max(0,1-(now-m.start)/m.duration)
      handle.mesh:K2_SetRelativeLocation(v(m.x*left,m.y*left,m.z*left),false,{},true)
      if left==0 then handle.motion=nil;self.motions[id]=nil end
    else self.motions[id]=nil end
  end
  if self.fluid_visual then self.fluid_visual:tick(now,8)end
end
function M:set_active(handle,active)
  assert(valid(handle.actor) and valid(handle.mesh),'invalid-native-building')
  handle.activation_uncertain=true
  if not active and handle._mechanism_cracks then
    local ok,why=require('host.pbz.mechanism_cracks').clear(handle);assert(ok,why);handle.stage=nil
  end
  for i,box in ipairs(handle.boxes or {handle.box})do box:SetCollisionEnabled(active and i<=(handle.box_count or 1)and (handle.collision_mode or 3)or 0)end
  handle.mesh:SetVisibility(active,false)
  if valid(handle.light)then handle.light:SetVisibility(active and handle.light_enabled==true,false)end
  handle.active=active
  if handle.cubic then
    if active then self.faces:put(handle);self:queue_faces(handle) else self.faces:remove(handle) end
    self:queue_neighbors(handle)
  end
  handle.activation_uncertain=nil;return true
end
function M:destroy(handle)
  require('host.pbz.mechanism_sections').clear(self,handle)
  if handle._mechanism_cracks then
    local ok,why=require('host.pbz.mechanism_cracks').clear(handle);assert(ok,why);handle.stage=nil
  end
  if self.motions then self.motions[handle.id]=nil end
  if handle.fluid and self.fluid_visual then self.fluid_visual:remove(handle)end
  if handle.cubic then self.faces:remove(handle);self:queue_neighbors(handle) end
  if not self:engine_valid(handle.actor) then return true end
  if not handle.destroy_requested then
    for _,box in ipairs(handle.boxes or {handle.box})do if valid(box)then box:SetCollisionEnabled(0)end end
    if handle.light_counted then self.light_count=math.max(0,(self.light_count or 1)-1);handle.light_counted=false end
    if valid(handle.mesh) then handle.mesh:SetVisibility(false,false) end
    local name=handle.actor:GetFullName()
    handle.actor:K2_DestroyActor()
    handle.destroy_requested=true
    self.by_actor[name]=nil
    handle.active=false
  end
  local gone=not self:engine_valid(handle.actor)
  self.log('build destroy id='..tostring(handle.id)..' engine-invalid='..tostring(gone))
  return gone
end
-- Only a committed retraction may recycle a head. Old logical handles must
-- never become valid for a new block, even when the native carrier is reused.
function M:retire(handle)
  if handle.record.content_id~='pbzmc:piston_head' or handle.active or handle._mechanism_cracks then return self:destroy(handle)end
  self.head_pool=self.head_pool or {}
  if #self.head_pool>=8 or not self:engine_valid(handle.actor)then return self:destroy(handle)end
  local spare={}
  for _,key in ipairs({'actor','identity','root','mesh','boxes','box','box_count','collision_mode',
    'model','mechanism','applied_boxes','applied_query','rendered','colliding','sections','record','id'})do
    spare[key]=handle[key]
  end
  if self.motions then self.motions[handle.id]=nil end
  if handle.motion then spare.mesh:K2_SetRelativeLocation(v(0,0,0),false,{},true)end
  self.by_actor[handle.identity.name]=nil
  handle.actor=nil;handle.mesh=nil;handle.rendered=false;handle.colliding=false
  spare.active=false;self.head_pool[#self.head_pool+1]=spare
  return true
end
function M:trace_record(record)
  local yes,hit=self:line_trace(v(record.x,record.y,record.z+75),v(record.x,record.y,record.z-75))
  local object=yes and hit_object(hit)
  local handle=yes and self:hit_handle(hit)
  return yes,handle and handle.id or nil,object and object:GetFullName() or 'none'
end
function M:close_effects()
  for i=#(self.head_pool or {}),1,-1 do
    assert(self:destroy(self.head_pool[i]),'pooled-piston-head-cleanup-pending')
    table.remove(self.head_pool,i)
  end
  local ok,why=require('host.pbz.mechanism_cracks').close(self);assert(ok,why)
  self.translucent_materials=nil
end
return M
