-- Collision-checked entity displacement owned by one piston transaction.
-- MC PistonMovingBlockEntity: moving shape overlap, <=1 block + .01 clearance,
-- slime velocity and grounded honey passengers. No NPC names or actor scans.
local D=require('rules.block_directions')
local Identity=require('host.pbz.object_identity')
local M={MAX_ENTITIES=32,MAX_COMPONENTS=256,CLEARANCE=1}
local Native={};Native.__index=Native
local Ticket={};Ticket.__index=Ticket
local axes={'X','Y','Z'}
local function v(x,y,z)return {X=x,Y=y,Z=z}end
local function copy(p)return v(p.X,p.Y,p.Z)end
local function plus(a,b)return v(a.X+b.X,a.Y+b.Y,a.Z+b.Z)end
local function minus(a,b)return v(a.X-b.X,a.Y-b.Y,a.Z-b.Z)end
local function valid(o)return o and o:IsValid()end
local function near(a,b)return math.abs(a.X-b.X)<.3 and math.abs(a.Y-b.Y)<.3 and math.abs(a.Z-b.Z)<.3 end
local function box(center,half)return {min=minus(center,half),max=plus(center,half)}end
local function shifted(b,delta)return {min=plus(b.min,delta),max=plus(b.max,delta)}end
local function union(a,b)
 local r={min={},max={}}
 for _,k in ipairs(axes)do r.min[k]=math.min(a.min[k],b.min[k]);r.max[k]=math.max(a.max[k],b.max[k])end
 return r
end
local function overlaps(a,b,epsilon)
 epsilon=epsilon or .01
 for _,k in ipairs(axes)do if a.min[k]>=b.max[k]-epsilon or a.max[k]<=b.min[k]+epsilon then return false end end
 return true
end
local function centerhalf(b)
 return v((b.min.X+b.max.X)/2,(b.min.Y+b.max.Y)/2,(b.min.Z+b.max.Z)/2),
  v((b.max.X-b.min.X)/2,(b.max.Y-b.min.Y)/2,(b.max.Z-b.min.Z)/2)
end
local function address(a)return a:GetAddress()end
function M.shapes(service,plan,changes)
 local world=service.world;local shapes={};local vector=D.vectors[plan.movement or (plan.extend and plan.direction or D.opposite(plan.direction))]
 local delta=v(vector.x*100,vector.y*100,vector.z*100)
 local function add(record,from,to)
  for _,s in ipairs(world:boxes(record))do
   local c=v(from.x+s.center[1],from.y+s.center[2],from.z+s.center[3]);local h=v(s.half[1],s.half[2],s.half[3])
   local a=box(c,h);local b=shifted(a,v(to.x-from.x,to.y-from.y,to.z-from.z))
   shapes[#shapes+1]={from=a,to=b,swept=union(a,b),kind=record.content_id}
  end
 end
 for _,row in ipairs(changes)do
  local a,b=row.before,row.after
  if a and b and (a.x~=b.x or a.y~=b.y or a.z~=b.z)then add(a,a,b)
  elseif b and not a and b.content_id=='pbzmc:piston_head'then
   add(b,{x=b.x-delta.X,y=b.y-delta.Y,z=b.z-delta.Z},b)
  end
 end
 return shapes,delta
end
function Native.new(service)
 local UE=require('UEHelpers')
 local boat=require('host.pbz.boat_service').get(service.binding)
 return setmetatable({service=service,world=service.world,pawn=service.binding.actor,
  system=UE.GetKismetSystemLibrary(),boat=boat,types={},primitive=StaticFindObject('/Script/Engine.PrimitiveComponent'),
  pawn_class=StaticFindObject('/Script/Engine.Pawn')},Native)
end
function Native:current()return self.service.binding:is_current()and self.world:is_current()end
function Native:is_rider(actor)
 if not self.boat or not valid(actor)then return false end
 local key=address(actor);local riders=self.riders
 if not riders then riders={};self.riders=riders end
 if riders[key]==nil then riders[key]=self.boat:piston_rider(actor) or false end
 return riders[key]
end
function Native:owner(actor)
 if self.boat and self.boat.external_push_owner then return self.boat:external_push_owner(actor)or actor end
 return actor
end
function Native:describe(actor)
 if not valid(actor)then return nil end
 local pawn=actor:IsA(self.pawn_class)
 local root
 if not pawn then
  root=actor.RootComponent
  if not valid(root)or not root:IsA(self.primitive)then return nil end
  self.no_bone=self.no_bone or FName('None')
  if not root:IsSimulatingPhysics(self.no_bone)then return nil end
 end
 if self:is_rider(actor) or self:owner(actor)~=actor then return nil end
 if self.boat and self.boat.world.by_actor[actor:GetAddress()]then return nil end
 local p=copy(actor:K2_GetActorLocation());local row={actor=actor,id=Identity.capture(actor),position=p}
 if pawn then
  local capsule=actor.CapsuleComponent
  if not valid(capsule)then return nil,'unsupported-pawn-collision'end
  row.radius=capsule:GetScaledCapsuleRadius();row.height=capsule:GetScaledCapsuleHalfHeight()
  if row.radius<=0 or row.radius>1000 or row.height<row.radius or row.height>2000 then return nil,'invalid-pawn-collision'end
  row.bounds=box(p,v(row.radius,row.radius,row.height));row.kind='character'
  local ok,grounded=pcall(function()return not actor.CharacterMovement:IsFalling()end);row.grounded=ok and grounded
 else
  local bounds_ok,bounds=pcall(function()return root.Bounds end)
  if not bounds_ok or not bounds then return nil,'unsupported-physics-bounds'end
  row.kind='physics';row.component=root;row.offset=minus(copy(bounds.Origin),p)
  row.half=copy(bounds.BoxExtent);row.bounds=box(copy(bounds.Origin),row.half)
 end
 return row
end
function Native:query(bounds,allow_fallback)
 local center,half=centerhalf(bounds)
 local components=self.world:overlap_components(center,{x=half.X,y=half.Y,z=half.Z})
 if allow_fallback and #components>M.MAX_COMPONENTS then return nil end
 assert(#components<=M.MAX_COMPONENTS,'piston-component-budget')
 local rows,seen={},{}
 local function append(actor)
  if not valid(actor)then return end
  local key=address(actor)
  if seen[key]then return end;seen[key]=true
  local row,why=self:describe(actor)
  if why then error(why)end
  if row and overlaps(bounds,row.bounds)then rows[#rows+1]=row end
 end
 append(self.pawn)
 for _,wrapped in ipairs(components)do
  local component=wrapped;if not component.GetFullName then component=component:get()end
  append(component:GetOwner())
 end
 return rows
end
function Native:prefetch(bounds)
 self.nearby=self:query(bounds,true)
 if self.boat then self.hulls=self.boat:external_push_candidates(bounds)end
end
function Native:candidates(bounds)
 local rows
 if self.nearby then
  rows={}
  for _,row in ipairs(self.nearby)do if overlaps(bounds,row.bounds)then rows[#rows+1]=row end end
 else rows=self:query(bounds,false)end
 if self.boat and self.boat.external_push_candidates then
  for _,candidate in ipairs(self.hulls or self.boat:external_push_candidates(bounds))do
   local actor=candidate.actor
   if (not self.hulls or candidate:intersects(bounds)) and valid(actor)then
    local b=candidate.bounds or box(candidate.center,candidate.half)
    rows[#rows+1]={actor=actor,id=Identity.capture(actor),position=copy(actor:K2_GetActorLocation()),
     kind='boat',bounds=b,grounded=true}
   end
  end
 end
 return rows
end
function Native:hit_actor(hit)
 local ok,o=pcall(function()return hit.HitObjectHandle.ReferenceObject:Get()end)
 if not ok or not valid(o)then
  ok,o=pcall(function()return hit.Component:Get():GetOwner()end)
 end
 return ok and valid(o)and o or nil
end
function Native:sweep(row,to,ignored)
 if not self:current()or not Identity.matches(row.actor,row.id)then return false,'piston-entity-stale'end
 local start=row.actor:K2_GetActorLocation();local color={R=0,G=0,B=0,A=0};local hit={}
 local exclude={row.actor};for _,actor in ipairs(ignored)do exclude[#exclude+1]=actor end
 for _=1,16 do
  local yes
  if row.kind=='character'then
   yes=self.system:CapsuleTraceSingle(self.pawn,start,to,row.radius,row.height,
    0,false,exclude,0,hit,false,color,color,0)
  else
   yes=self.system:BoxTraceSingle(self.pawn,plus(start,row.offset),plus(to,row.offset),row.half,
    {Pitch=0,Yaw=0,Roll=0},0,false,exclude,0,hit,false,color,color,0)
  end
  if not yes then return true end
  local owner=self:hit_actor(hit)
  if self:is_rider(owner)then exclude[#exclude+1]=owner
  else
   local handle=self.world:hit_handle(hit)
   local definition=handle and require('content.blocks').get(handle.content_id or handle.record and handle.record.content_id)
   if not definition or definition.collision~=false then return false,'piston-entity-sweep-blocked'end
   exclude[#exclude+1]=handle.actor
  end
 end
 return false,'piston-entity-trace-budget'
end
function Native:prepare(row,delta,now,ignored)
 if row.kind=='boat'then
  return self.boat:external_push_prepare(row.actor,delta,now,ignored)
 end
 local to=plus(row.position,delta);local ok,why=self:sweep(row,to,ignored)
 if not ok then return nil,why end
 local adapter=self
 return {
  apply=function()
   if not adapter:current()or not Identity.matches(row.actor,row.id)or not near(row.actor:K2_GetActorLocation(),row.position)then return false,'piston-entity-changed'end
   local clear,reason=adapter:sweep(row,to,ignored);if not clear then return false,reason end
   -- The real full capsule/body sweep above ignores only this atomic move's
   -- replaced MC bodies. Root-component sweep cannot take that ignore set and
   -- would hit the old piston head during honey retraction. After a second
   -- collision check immediately before writing, commit the verified pose.
   -- Native walls and every unrelated building remain in both sweeps.
   local accepted=row.actor:K2_SetActorLocation(to,false,{},true)
   return accepted~=false and near(row.actor:K2_GetActorLocation(),to),'piston-native-sweep-incomplete'
  end,
  rollback=function()
   if not Identity.matches(row.actor,row.id)then return true end
   local current=row.actor:K2_GetActorLocation();if near(current,row.position)then return true end
   if not adapter:current()then return false,'piston-rollback-scene-changed'end
   local clear,reason=adapter:sweep(row,row.position,ignored);if not clear then return false,reason end
   local accepted=row.actor:K2_SetActorLocation(row.position,false,{},true)
   return accepted~=false and near(row.actor:K2_GetActorLocation(),row.position),'piston-rollback-sweep-blocked'
  end,
  finish=function()
   if row.slime and Identity.matches(row.actor,row.id)then
    local velocity=copy(row.actor:GetVelocity());local axis=delta.X~=0 and 'X'or delta.Y~=0 and 'Y'or 'Z'
    velocity[axis]=delta[axis]>0 and 2000 or -2000
    if row.kind=='character'then row.actor:LaunchCharacter(velocity,true,true)
    else row.component:SetPhysicsLinearVelocity(velocity,false,'None')end
   end
  end,
 }
end
function Ticket:apply()
 if self.applied or self.finished then return false,'piston-ticket-used'end
 self.applied=true
 for _,row in ipairs(self.rows)do
  self.attempted[#self.attempted+1]=row
  local call,ok,why=pcall(row.ticket.apply,row.ticket)
  if not call or not ok then return false,call and why or tostring(ok)end
 end
 return true
end
function Ticket:rollback()
 local all=true
 for i=#self.attempted,1,-1 do
  local row=self.attempted[i];local call,ok=pcall(row.ticket.rollback,row.ticket)
  if call and ok then table.remove(self.attempted,i)else all=false end
 end
 return all,all and nil or 'piston-entity-rollback-pending'
end
function Ticket:finish()
 self.finished=true;local errors={}
 for _,row in ipairs(self.rows)do if row.ticket.finish then
  local call,ok,why=pcall(row.ticket.finish,row.ticket)
  if not call or ok==false then errors[#errors+1]=tostring(call and why or ok)end
 end end
 self.attempted={};return #errors==0,errors
end
function M.prepare(service,plan,changes,now,adapter)
 local shapes,delta=M.shapes(service,plan,changes)
 local ticket=setmetatable({rows={},attempted={}},Ticket)
 if #shapes==0 then return ticket end
 adapter=adapter or Native.new(service)
 if not adapter:current()then return nil,'piston-entity-stale'end
 if adapter.is_rider then ticket.is_rider=function(actor)return adapter:is_rider(actor)end end
 local axis=delta.X~=0 and 'X'or delta.Y~=0 and 'Y'or 'Z';local positive=delta[axis]>0
 local candidates,byid={},{};local ignored={}
 for _,row in ipairs(changes)do
  local h=row.before and service.session.handles[row.before.id]
  if h then ignored[#ignored+1]=h.actor end
 end
 local broadphase
 for _,shape in ipairs(shapes)do
  local area=shape.swept
  if shape.kind=='pbzmc:honey_block'and axis~='Z'then
   area=union(area,{min=copy(shape.from.min),max=plus(shape.from.max,v(0,0,50))})
  end
  shape.area=area
  broadphase=broadphase and union(broadphase,area) or area
 end
 if adapter.prefetch and #shapes>1 then adapter:prefetch(broadphase)end
 for _,shape in ipairs(shapes)do
  for _,row in ipairs(adapter:candidates(shape.area))do
   local key=row.id and tostring(row.id.address)..'/'..tostring(row.id.name)or row.actor
   local entry=byid[key]
   if not entry then
    if #candidates>=M.MAX_ENTITIES then return nil,'piston-entity-budget'end
    entry=row;entry.amount=0;byid[key]=entry;candidates[#candidates+1]=entry
   end
   if overlaps(shape.swept,row.bounds)then
    local amount=positive and shape.to.max[axis]-row.bounds.min[axis]or row.bounds.max[axis]-shape.to.min[axis]
    if amount>0 then entry.amount=math.max(entry.amount,math.min(100,amount)+M.CLEARANCE)
     entry.slime=entry.slime or shape.kind=='pbzmc:slime_block'
    end
   end
   -- MC honey carries grounded entities on its upper surface while sliding
   -- sideways. Ordinary side contacts still use the same swept-box push.
   if shape.kind=='pbzmc:honey_block'and axis~='Z'and row.grounded then
    local c=centerhalf(row.bounds);local floor=row.bounds.min.Z
    if floor>=shape.from.max.Z-1 and floor<=shape.from.max.Z+2
     and c.X>=shape.from.min.X and c.X<=shape.from.max.X and c.Y>=shape.from.min.Y and c.Y<=shape.from.max.Y then
      entry.amount=math.max(entry.amount,100);entry.honey=true
    end
   end
  end
 end
 table.sort(candidates,function(a,b)
  local da,db=a.position[axis],b.position[axis]
  if da~=db then return positive and da>db or not positive and da<db end
  return tostring(a.id and a.id.address or a.actor)<tostring(b.id and b.id.address or b.actor)
 end)
 -- Ignore only this transaction's swept bodies in preflight. Actual swept
 -- movement happens farthest first; other characters/map collision remain.
 for _,row in ipairs(candidates)do if row.amount>0 then ignored[#ignored+1]=row.actor end end
 for _,row in ipairs(candidates)do if row.amount>0 then
  local displacement=v(0,0,0);displacement[axis]=positive and row.amount or -row.amount
  local body,why=adapter:prepare(row,displacement,now,ignored)
  if not body then return nil,why end
  row.ticket=body;row.delta=displacement;ticket.rows[#ticket.rows+1]=row
 end end
 return ticket
end
M.overlaps=overlaps
M.bounds=box
return M
