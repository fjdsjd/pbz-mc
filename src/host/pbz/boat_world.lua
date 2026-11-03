-- Game-thread-only world ownership for the original oak boat. No input,
-- passenger control, gameplay state or disk save is performed here.
local UE=require('UEHelpers')
local identity=require('host.pbz.object_identity')
local bundle=require('host.pbz.mesh_bundle')
local axes=require('presentation.native_steve_pose')
local rules=require('rules.boat')
local M={};M.__index=M
local half={X=68.75,Y=68.75,Z=28.125}
local inset={X=68.5,Y=68.5,Z=27.875}
local zero={Pitch=0,Yaw=0,Roll=0}
local color={R=0,G=0,B=0,A=0}
local names={'hull','left_paddle','right_paddle'}
local caches={}
local object_types={};for i=0,31 do object_types[#object_types+1]=i end
local function finite(n)return type(n)=='number' and n==n and math.abs(n)<math.huge end
local function penetrating(hit)
  -- PBZ's UE4SS packed-bool read reports bStartPenetrating=true even for a
  -- normal mid-ray hit. Numeric contact fields are verified by the live probe.
  return finite(hit.Time) and hit.Time<=1e-6 and finite(hit.PenetrationDepth) and hit.PenetrationDepth>1e-3
end
local function v(x,y,z)return {X=x,Y=y,Z=z}end
local function add(a,b)return v(a.X+b.X,a.Y+b.Y,a.Z+b.Z)end
local function sub(a,b)return v(a.X-b.X,a.Y-b.Y,a.Z-b.Z)end
local function mul(a,n)return v(a.X*n,a.Y*n,a.Z*n)end
local function dot(a,b)return a.X*b.X+a.Y*b.Y+a.Z*b.Z end
local function length(a)return math.sqrt(dot(a,a))end
local function vec_ok(p)return p and finite(p.X) and finite(p.Y) and finite(p.Z)end
local function record_ok(p)return p and finite(p.x) and finite(p.y) and finite(p.z) and finite(p.yaw)end
local function transform(z)return {Rotation={X=0,Y=0,Z=0,W=1},Translation=v(0,0,z or 0),Scale3D=v(1,1,1)}end
local function valid(o)return o and o:IsValid()end
local function apply_basis(b,p)return add(add(mul(b[1],p.X),mul(b[2],p.Y)),mul(b[3],p.Z))end
local function center(p)return v(p.x,p.y,p.z+half.Z)end
local function native_rotation(p)return {Pitch=0,Yaw=p.yaw,Roll=0}end
local function error_result(fn,self,...)
  local ok,a,b=pcall(fn,self,...)
  if not ok then return nil,tostring(a) end
  return a,b
end

function M.new(binding,directory,log)
  assert(binding and valid(binding.actor),'boat-player-unavailable')
  assert(type(directory)=='string' and #directory>0,'boat-directory-unavailable')
  local pawn=binding.actor;local world=pawn:GetWorld()
  local self=setmetatable({binding=binding,pawn=pawn,world=world,
    pawn_identity=identity.capture(pawn),world_identity=identity.capture(world),
    world_id=world:GetFullName():gsub('^World ',''),directory=directory..'/pbzmc-assets/boat',
    handles={},by_actor={},log=log or function()end},M)
  self.native_valid=StaticFindObject('/Script/Engine.KismetSystemLibrary:IsValid')
  self.actor_class=StaticFindObject('/Script/Engine.Actor')
  self.pawn_class=StaticFindObject('/Script/Engine.Pawn')
  self.root_class=StaticFindObject('/Script/Engine.SceneComponent')
  self.box_class=StaticFindObject('/Script/Engine.BoxComponent')
  self.mesh_class=StaticFindObject('/Script/ProceduralMeshComponent.ProceduralMeshComponent')
  assert(valid(self.native_valid) and valid(self.actor_class) and valid(self.pawn_class)
    and valid(self.root_class) and valid(self.box_class) and valid(self.mesh_class),'boat-native-api-unavailable')
  assert(self:engine_valid(pawn) and self:engine_valid(world),'boat-native-context-invalid')
  return self
end
function M:engine_valid(object)
  if not valid(object) then return false end
  local result=self.native_valid(UE.GetKismetSystemLibrary(),object)
  assert(type(result)=='boolean','boat-native-validity-result-unavailable')
  return result
end
-- The query uses the entities' collision bounds, including tall boss capsules.
-- The service applies the exact seat test to each candidate.
function M:characters_near_boats(region)
  self.character_class=self.character_class or StaticFindObject('/Script/ProjectPBZ.PBZCharacter')
  local x,y,z=(region.x0+region.x1)*.5,(region.y0+region.y1)*.5,(region.z0+region.z1)*.5
  local actors={}
  UE.GetKismetSystemLibrary():BoxOverlapActors(self.pawn,v(x,y,z+28.125),
    v(region.x1-x+220,region.y1-y+220,region.z1-z+28.125),object_types,self.character_class,{self.pawn},actors)
  return actors
end
function M:is_current()
  return not self.closed and not self.closing and identity.matches(self.binding.actor,self.pawn_identity)
    and identity.matches(self.pawn:GetWorld(),self.world_identity) and self:engine_valid(self.pawn)
    and (not self.binding.is_current or self.binding:is_current()) or false
end
function M:valid(handle)
  if not self:is_current() or not handle or not handle.active or self.handles[handle.id]~=handle
    or not identity.matches(handle.actor,handle.identity) or not self:engine_valid(handle.actor) then return false end
  for _,entry in ipairs(handle.components)do
    if not identity.matches(entry.object,entry.identity) or not self:engine_valid(entry.object) then return false end
  end
  return true
end
function M:part(name)
  local cache=caches[self.directory]
  if not cache then cache={};caches[self.directory]=cache end
  if not cache[name] then
    local part=assert(bundle.read(self.directory..'/'..name..'.mesh',6.25)[1],'boat-model-empty')
    assert(part.name==name,'boat-model-part-mismatch')
    -- Existing vertex-color text material samples a known white atlas texel.
    for _,uv in ipairs(part.uv)do uv.X=433.5/512;uv.Y=139.5/256 end
    cache[name]=part
  end
  return cache[name]
end
function M:reload_parts()
  -- Explicit developer/resource reload only. Instances keep their collision
  -- and identity; normal rendering never reads files or uploads geometry.
  caches[self.directory]=nil
  for _,name in ipairs(names)do self:part(name)end
end
function M:refresh_mesh(handle,state)
  assert(self:valid(handle),'invalid-native-boat')
  for _,name in ipairs(names)do bundle.apply(handle.meshes[name],self:part(name))end
  handle.render_signature=nil
  return self:render(handle,state)
end
function M:material()
  if self:engine_valid(self.binding.material) then return self.binding.material end
  if not self:engine_valid(self.fallback_material) then
    self.fallback_material=LoadAsset('/Engine/EngineMaterials/DefaultTextMaterialOpaque.DefaultTextMaterialOpaque')
  end
  assert(self:engine_valid(self.fallback_material),'boat-material-unavailable')
  return self.fallback_material
end
function M:hit_actor(hit)
  local ok,object=pcall(function()return hit.HitObjectHandle.ReferenceObject:Get()end)
  if not ok or not valid(object) then
    ok,object=pcall(function()return hit.Component:Get()end)
  end
  if not ok or not valid(object) then return end
  return object:IsA(self.actor_class) and object or object:GetOwner()
end
function M:trace(start,finish,extent,yaw,handle,skip_pawns,extra)
  assert(self:is_current(),'stale-boat-world')
  local ignore={self.pawn};local seen={[self.pawn_identity.address]=true}
  local function exclude(actor)
    if valid(actor) and not seen[actor:GetAddress()] then
      seen[actor:GetAddress()]=true;ignore[#ignore+1]=actor
    end
  end
  if handle then exclude(handle.actor) end
  if type(extra)=='table'and not extra.IsValid then for _,actor in ipairs(extra)do exclude(actor)end
  else exclude(extra)end
  -- Pawn response is Overlap on the real box. A Visibility shape trace would
  -- otherwise hit riders' capsules; repeat through only those actors, never walls.
  for _=1,32 do
    local hit={};local yes
    if extent then
      yes=UE.GetKismetSystemLibrary():BoxTraceSingle(self.pawn,start,finish,extent,
        {Pitch=0,Yaw=yaw or 0,Roll=0},0,false,ignore,0,hit,true,color,color,0)
    else
      yes=UE.GetKismetSystemLibrary():LineTraceSingle(self.pawn,start,finish,0,false,ignore,0,hit,true,color,color,0)
    end
    if not yes then return false,hit end
    local actor=self:hit_actor(hit)
    local sampler=self.binding.mc_fluid_sampler
    local fluid=skip_pawns and sampler and sampler:fluid_actor(actor)
    local pawn=skip_pawns==true and valid(actor)and actor:IsA(self.pawn_class)
    if not fluid and not pawn then return true,hit end
    assert(not seen[actor:GetAddress()],'boat-pawn-query-repeat')
    exclude(actor)
  end
  error('boat-pawn-query-budget')
end
-- Strict, read-only preflight for transactional external pushes. Unlike
-- ordinary steering it never accepts a partial slide along a blocking wall.
function M:external_push_target(handle,delta,ignore)
  local before=self:pose(handle)
  assert(vec_ok(delta)and length(delta)<=2000,'boat-external-delta-range')
  local target={x=before.x+delta.X,y=before.y+delta.Y,z=before.z+delta.Z,yaw=before.yaw}
  if self:trace(center(before),center(target),inset,before.yaw,handle,true,ignore)then return nil,'boat-external-sweep-blocked'end
  return target,before
end
-- Used only after a strict preflight (or to restore a ticket's own old pose).
-- Native objects are not re-created, so mesh/seat identities remain stable.
function M:external_push_apply(handle,pose)
  assert(self:valid(handle)and record_ok(pose),'boat-external-pose-invalid')
  assert(handle.actor:K2_SetActorLocation(v(pose.x,pose.y,pose.z),false,{},true)~=false,'boat-external-location-rejected')
  assert(handle.actor:K2_SetActorRotation(native_rotation(pose),true)~=false,'boat-external-rotation-rejected')
  local actual=self:pose(handle)
  assert(math.abs(actual.x-pose.x)+math.abs(actual.y-pose.y)+math.abs(actual.z-pose.z)<.05,'boat-external-readback-mismatch')
  return actual
end
function M:fits(p,handle,extent,extra,skip_pawns)
  local c=extent and v(p.x,p.y,p.z) or center(p)
  return not self:trace(c,add(c,v(0,0,.01)),extent or inset,p.yaw,handle,skip_pawns~=false,extra)
end
function M:ground(p,handle)
  local a=center(p);a.Z=a.Z+2
  local b=center(p);b.Z=b.Z-6
  local yes,hit=self:trace(a,b,half,p.yaw,handle,true)
  if yes and not penetrating(hit) and vec_ok(hit.Location) and vec_ok(hit.ImpactNormal) and hit.ImpactNormal.Z>=.5 then
    local z=hit.Location.Z-half.Z
    if math.abs(z-p.z)<=6.1 then return {kind='land',friction=.6,ground_z=z} end
  end
  return {kind='air',friction=.9}
end
function M:_spawn(record)
  assert(self:is_current(),'stale-boat-world')
  assert(record_ok(record) and type(record.id)=='string' and #record.id>0,'invalid-boat-record')
  assert(record.world==self.world_id,'boat-record-world-mismatch')
  assert(not self.handles[record.id],'boat-id-already-owned')
  local parts={};for _,name in ipairs(names)do parts[name]=self:part(name) end
  local material=self:material()
  assert(self:fits(record),'boat-space-occupied')
  local actor=self.world:SpawnActor(self.actor_class,v(record.x,record.y,record.z),native_rotation(record))
  assert(self:engine_valid(actor),'boat-actor-create-failed')
  local h={actor=actor,identity=identity.capture(actor),id=record.id,world_owner=self,
    components={},meshes={},mesh_identities={},active=false}
  self.handles[h.id]=h;self.by_actor[h.identity.address]=h
  local ok,why=pcall(function()
    local function component(class,offset)
      -- AddComponentByClass(false) assigns the first scene component as root
      -- and auto-attaches later components, as in the existing building adapter.
      local object=actor:AddComponentByClass(class,false,transform(offset),false)
      assert(self:engine_valid(object),'boat-component-create-failed')
      h.components[#h.components+1]={object=object,identity=identity.capture(object)}
      return object
    end
    h.root=component(self.root_class)
    assert(identity.matches(actor.RootComponent,identity.capture(h.root)),'boat-root-assignment-failed')
    h.box=component(self.box_class,half.Z)
    h.box_identity=identity.capture(h.box)
    h.box:SetBoxExtent(half,true);h.box:SetCollisionEnabled(0)
    h.box:SetCollisionObjectType(1);h.box:SetCollisionResponseToAllChannels(2)
    h.box:SetCollisionResponseToChannel(2,1) -- Pawn Overlap, other channels Block.
    h.box:K2_SetRelativeLocationAndRotation(v(0,0,half.Z),zero,false,{},true)
    assert(actor:K2_SetActorLocation(v(record.x,record.y,record.z),false,{},true)~=false,'boat-initial-location-rejected')
    assert(actor:K2_SetActorRotation(native_rotation(record),true)~=false,'boat-initial-rotation-rejected')
    for _,name in ipairs(names)do
      local mesh=component(self.mesh_class);h.meshes[name]=mesh
      h.mesh_identities[name]=identity.capture(mesh)
      mesh:SetCollisionEnabled(0);mesh:SetHiddenInGame(true,false);mesh:SetCastShadow(true)
      mesh:SetCullDistance(20000);mesh:SetMaterial(0,material);bundle.apply(mesh,parts[name])
    end
    h.active=true
    assert(self:render(h,rules.new(record)))
    h.box:SetCollisionEnabled(3)
    for _,name in ipairs(names)do h.meshes[name]:SetHiddenInGame(false,false) end
  end)
  if not ok then
    local clean,reason=self:destroy(h)
    error(tostring(why)..(clean and '' or '; cleanup='..tostring(reason)))
  end
  return h
end
function M:spawn(record)return error_result(self._spawn,self,record)end
function M:pose(handle)
  assert(self:valid(handle),'invalid-native-boat')
  local p=handle.actor:K2_GetActorLocation();local r=handle.actor:K2_GetActorRotation()
  assert(vec_ok(p) and finite(r.Yaw),'boat-pose-unavailable')
  return {x=p.X,y=p.Y,z=p.Z,yaw=r.Yaw}
end
local function paddle_vector(p,angle)
  local x,y,z=p.X,p.Y,p.Z
  local c,s=math.cos(angle.pitch),math.sin(angle.pitch);y,z=c*y-s*z,s*y+c*z
  c,s=math.cos(angle.yaw),math.sin(angle.yaw);x,z=c*x+s*z,-s*x+c*z
  c,s=math.cos(angle.roll),math.sin(angle.roll);x,y=c*x-s*y,s*x+c*y
  return v(x,-z,-y)
end
function M:render(handle,state)
  local wobble=rules.wobble(state,state.partial or 0)
  local left=rules.paddle_angles(state,1,state.partial);local right=rules.paddle_angles(state,2,state.partial)
  local signature={wobble,left.phase,right.phase}
  local unchanged=handle.render_signature~=nil
  if unchanged then for i,n in ipairs(signature)do if handle.render_signature[i]~=n then unchanged=false;break end end end
  if unchanged then return true end
  assert(self:valid(handle),'invalid-native-boat')
  -- Renderer wobble pivots around its original +0.375-block translation.
  -- Original renderer-X rotation maps to local UE negative Pitch.
  -- The root already moves/turns every component. Only local animation needs
  -- a transform write; translation alone never dirties the three mesh poses.
  local body={axes.axes({Pitch=-wobble,Yaw=0,Roll=0})};local anchor=v(0,0,37.5)
  local function point(localp)return add(anchor,apply_basis(body,sub(localp,anchor)))end
  if not handle.render_signature or handle.render_signature[1]~=wobble then
    handle.meshes.hull:K2_SetRelativeLocationAndRotation(point(v(0,0,0)),{Pitch=-wobble,Yaw=0,Roll=0},false,{},true)
  end
  for i,name in ipairs({'left_paddle','right_paddle'})do
    if not handle.render_signature or handle.render_signature[1]~=wobble or handle.render_signature[i+1]~=signature[i+1]then
      local angle=i==1 and left or right
      local forward=apply_basis(body,paddle_vector(v(1,0,0),angle))
      local up=apply_basis(body,paddle_vector(v(0,-1,0),angle))
      local rotation=axes.frame(forward,up).rotation
      handle.meshes[name]:K2_SetRelativeLocationAndRotation(point(self:part(name).pivot),rotation,false,{},true)
    end
  end
  handle.render_signature=signature
  return true
end
function M:surface(handle)return self:ground(self:pose(handle),handle)end
function M:move(handle,frame)
  local before=self:pose(handle);assert(record_ok(frame),'invalid-boat-move')
  local delta=sub(v(frame.x,frame.y,frame.z),v(before.x,before.y,before.z))
  assert(length(delta)<=2000,'boat-move-out-of-range')
  local yaw=frame.yaw
  if yaw~=before.yaw and not self:fits({x=before.x,y=before.y,z=before.z,yaw=yaw},handle) then yaw=before.yaw end
  local a=center(before);local target=center(frame)
  for _=1,3 do
    local d=sub(target,a);local distance=length(d)
    if distance<1e-5 then break end
    local yes,hit=self:trace(a,target,inset,yaw,handle,true)
    if not yes then a=target;break end
    if penetrating(hit) then break end
    assert(finite(hit.Time) and vec_ok(hit.ImpactNormal),'boat-sweep-hit-unavailable')
    local t=math.max(0,math.min(1,hit.Time)-.5/distance)
    a=add(a,mul(d,t))
    local normal=hit.ImpactNormal;local norm=length(normal)
    assert(norm>.1,'boat-sweep-normal-unavailable');normal=mul(normal,1/norm)
    local remaining=sub(target,a)
    remaining=sub(remaining,mul(normal,math.min(0,dot(remaining,normal))))
    target=add(a,remaining)
  end
  local destination=v(a.X,a.Y,a.Z-half.Z)
  if destination.X~=before.x or destination.Y~=before.y or destination.Z~=before.z then
    assert(handle.actor:K2_SetActorLocation(destination,false,{},true)~=false,'boat-move-location-rejected')
  end
  if yaw~=before.yaw and handle.actor:K2_SetActorRotation({Pitch=0,Yaw=yaw,Roll=0},true)==false then
    error('boat-move-rotation-rejected')
  end
  local actual=self:pose(handle)
  return actual,self:ground(actual,handle)
end
function M:aim(aim,reach)
  assert(self:is_current(),'stale-boat-world')
  assert(type(aim)=='function','boat-aim-function-required')
  local origin,direction=aim();reach=reach or 500
  assert(vec_ok(origin) and vec_ok(direction) and finite(reach) and reach>0 and reach<=10000,'invalid-boat-aim')
  local n=length(direction);assert(n>1e-6,'empty-boat-aim')
  direction=mul(direction,1/n)
  return origin,add(origin,mul(direction,reach)),direction
end
function M:target(aim,reach)
  local a,b=self:aim(aim,reach);local yes,hit=self:trace(a,b)
  if not yes then return nil end
  local actor=self:hit_actor(hit)
  local handle=valid(actor) and self.by_actor[actor:GetAddress()]
  if handle and self:valid(handle) and identity.matches(actor,handle.identity) then return handle,hit end
  -- The first blocking world/character hit occludes boats behind it.
  return nil,hit
end
function M:_placement(aim)
  local a,b,direction=self:aim(aim,500);local yes,hit=self:trace(a,b,nil,nil,nil,'fluids')
  local sampler=self.binding.mc_fluid_sampler
  local water=sampler and sampler:water_target(a,yes and hit.ImpactPoint or b)
  if water then
    local p={x=water.X,y=water.Y,z=water.Z+.5,yaw=math.deg(math.atan(direction.Y,direction.X))}
    if self:fits(p)then return p end
    return nil,'boat-space-occupied'
  end
  if not yes then return nil,'no-boat-surface-in-reach' end
  local owner=self:hit_actor(hit)
  if valid(owner) and owner:IsA(self.pawn_class) then return nil,'character-is-not-boat-support' end
  if penetrating(hit) or not vec_ok(hit.ImpactPoint) or not vec_ok(hit.ImpactNormal)
    or hit.ImpactNormal.Z<.5 then return nil,'boat-needs-ground' end
  local p={x=hit.ImpactPoint.X,y=hit.ImpactPoint.Y,z=hit.ImpactPoint.Z+.5,
    yaw=math.deg(math.atan(direction.Y,direction.X))}
  local base=p.z;local free=false
  -- A point ray can touch the low part of a rock while the 137.5-cm footprint
  -- intersects a higher part. Find free full-box space above it, then descend
  -- onto the highest contact. The short ground() probe is for settled boats.
  for rise=0,80,5 do
    p.z=base+rise
    local start=center(p)
    if not self:trace(start,add(start,v(0,0,.01)),half,p.yaw,nil,true) then
      free=true
      local yes,support=self:trace(start,v(start.X,start.Y,base-8+half.Z),half,p.yaw,nil,true)
      if yes and not penetrating(support) and vec_ok(support.Location) and vec_ok(support.ImpactNormal)
          and support.ImpactNormal.Z>=.5 then
        p.z=support.Location.Z-half.Z+.5
        local final=center(p)
        if p.z>=base-8 and p.z<=base+80.5 and not self:trace(final,add(final,v(0,0,.01)),half,p.yaw,nil,true) then
          return p
        end
      end
    end
  end
  return nil,free and 'boat-needs-ground' or 'boat-space-occupied'
end
function M:placement(aim)return error_result(self._placement,self,aim)end
function M:capsule_trace(start,finish,radius,height,handle,actor,extra)
  assert(self:is_current(),'stale-boat-world')
  local ignore={self.pawn,handle.actor};local seen={[self.pawn:GetAddress()]=true,[handle.actor:GetAddress()]=true}
  if not seen[actor:GetAddress()] then ignore[#ignore+1]=actor;seen[actor:GetAddress()]=true end
  for _,other in ipairs(extra or {})do
    if valid(other)and not seen[other:GetAddress()]then ignore[#ignore+1]=other;seen[other:GetAddress()]=true end
  end
  for _=1,32 do
    local hit={}
    local yes=UE.GetKismetSystemLibrary():CapsuleTraceSingle(self.pawn,start,finish,radius,height,
      0,false,ignore,0,hit,true,color,color,0)
    if not yes then return false,hit end
    local owner=self:hit_actor(hit)
    local sampler=self.binding.mc_fluid_sampler
    local fluid=sampler and sampler:fluid_actor(owner)
    if not fluid and (not valid(owner) or not owner:IsA(self.pawn_class))then return true,hit end
    -- Seated capsules may overlap each other. Retain all world geometry;
    -- final occupancy below still rejects another pawn at the destination.
    assert(not seen[owner:GetAddress()],'boat-exit-pawn-query-repeat')
    seen[owner:GetAddress()]=true;ignore[#ignore+1]=owner
  end
  error('boat-exit-pawn-query-budget')
end
function M:capsule_occupied(position,radius,height,handle,actor,ignore_pawns)
  local out={};self.primitive_class=self.primitive_class or StaticFindObject('/Script/Engine.PrimitiveComponent')
  UE.GetKismetSystemLibrary():CapsuleOverlapComponents(self.pawn,position,radius,height,
    object_types,self.primitive_class,{self.pawn,handle.actor,actor},out)
  for _,wrapped in ipairs(out)do
    local c=wrapped;if not c.GetFullName then c=c:get()end
    local owner=c:GetOwner()
    if c:GetCollisionResponseToChannel(2)==2 and not (ignore_pawns and valid(owner) and owner:IsA(self.pawn_class)) then return true end
  end
  return false
end
function M:_exit_position(handle,actor,half_height)
  local p=self:pose(handle)
  assert(self:engine_valid(actor),'boat-exit-actor-invalid')
  local capsule=actor.CapsuleComponent
  assert(self:engine_valid(capsule),'boat-exit-capsule-unavailable')
  local radius=capsule:GetScaledCapsuleRadius()
  half_height=half_height or capsule:GetScaledCapsuleHalfHeight()
  assert(finite(radius) and radius>0 and finite(half_height) and half_height>=radius,'boat-exit-capsule-invalid')
  local from=actor:K2_GetActorLocation();assert(vec_ok(from),'boat-exit-position-invalid')
  local function sweep(a,b)return self:capsule_trace(a,b,radius,half_height,handle,actor)end
  local function occupied(point,ignore_pawns)return self:capsule_occupied(point,radius,half_height,handle,actor,ignore_pawns)end
  local safe=from
  local initial,contact=sweep(from,add(from,v(0,0,.01)))
  if initial or occupied(from,true) then
    -- Only an initial shallow floor penetration may be escaped upward.
    -- Reverse-sweep from the clear endpoint: this sees intervening walls or
    -- ceilings without ignoring the terrain actor that also owns the floor.
    if not initial or not finite(contact.Time) or contact.Time>1e-6 or not finite(contact.PenetrationDepth)
        or not vec_ok(contact.ImpactNormal) or contact.ImpactNormal.Z<.5 then return nil,'no-safe-boat-exit' end
    local depth=math.max(0,contact.PenetrationDepth)/contact.ImpactNormal.Z
    safe=nil
    for rise=math.ceil(depth+2),80,8 do
      local lifted=add(from,v(0,0,rise))
      if not occupied(lifted,true) then
        local blocked,back=sweep(lifted,from)
        if not blocked or not penetrating(back) and vec_ok(back.ImpactNormal) and back.ImpactNormal.Z>=.5
            and vec_ok(back.Location) and back.Location.Z<=from.Z+depth+2 then safe=lifted;break end
      end
    end
    if not safe then return nil,'no-safe-boat-exit' end
  end
  for _,extra in ipairs({0,70})do
    for _,angle in ipairs({90,-90,180,0})do
      local radians=math.rad(p.yaw+angle);local distance=half.X+radius+16+extra
      local x,y=p.x+math.cos(radians)*distance,p.y+math.sin(radians)*distance
      local yes,hit=self:trace(v(x,y,p.z+80),v(x,y,p.z-180),nil,0,handle,true,actor)
      if yes and not penetrating(hit) and vec_ok(hit.ImpactPoint) and vec_ok(hit.ImpactNormal) and hit.ImpactNormal.Z>=.5 then
        local base=hit.ImpactPoint.Z+half_height+2
        for rise=0,80,8 do
          local above=v(x,y,base+rise)
          if not occupied(above,false) then
            local supported,floor=sweep(above,v(x,y,base-32))
            if supported and not penetrating(floor) and vec_ok(floor.Location) and vec_ok(floor.ImpactNormal)
                and floor.ImpactNormal.Z>=.5 then
              local point=add(floor.Location,v(0,0,1))
              if not occupied(point,false) then
                for _,clearance in ipairs({2,16,32,64})do
                  local z=math.max(safe.Z,point.Z)+clearance
                  local up,across=v(safe.X,safe.Y,z),v(point.X,point.Y,z)
                  if not sweep(safe,up) and not sweep(up,across) and not sweep(across,point) then return point end
                end
              end
              break
            end
          end
        end
      end
    end
  end
  return nil,'no-safe-boat-exit'
end
function M:exit_position(handle,actor,half_height)return error_result(self._exit_position,self,handle,actor,half_height)end
function M:destroy(handle)
  if not handle then return true end
  if handle.world_owner~=self then return false,'boat-handle-not-owned' end
  if not identity.matches(handle.actor,handle.identity) or not self:engine_valid(handle.actor) then
    if self.handles[handle.id]==handle then self.handles[handle.id]=nil end
    if self.by_actor[handle.identity.address]==handle then self.by_actor[handle.identity.address]=nil end
    handle.active=false;return true
  end
  handle.active=false;local failures={}
  local function attempt(fn)
    local ok,why=pcall(fn);if not ok then failures[#failures+1]=tostring(why) end
  end
  attempt(function()if identity.matches(handle.box,handle.box_identity) then handle.box:SetCollisionEnabled(0) end end)
  for name,mesh in pairs(handle.meshes)do
    attempt(function()if identity.matches(mesh,handle.mesh_identities[name]) then mesh:SetHiddenInGame(true,false) end end)
  end
  attempt(function()handle.actor:K2_DestroyActor()end)
  local gone=not self:engine_valid(handle.actor)
  if gone then
    if self.handles[handle.id]==handle then self.handles[handle.id]=nil end
    if self.by_actor[handle.identity.address]==handle then self.by_actor[handle.identity.address]=nil end
  else failures[#failures+1]='boat-destroy-pending' end
  if #failures>0 then return false,table.concat(failures,'; ') end
  return true
end
function M:close()
  self.closing=true;local failures={};local pending={}
  for _,h in pairs(self.handles)do pending[#pending+1]=h end
  for _,h in ipairs(pending)do
    local ok,a,b=pcall(self.destroy,self,h)
    if not ok or not a then failures[#failures+1]=tostring(ok and b or a) end
  end
  if #failures>0 then return false,table.concat(failures,'; ') end
  self.closed=true;return true
end
return M
