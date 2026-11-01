-- Destination-only rescue queries. Never disable player/map collision and
-- never discard a terrain actor to make an obstructed destination pass.
local valid=require('host.pbz.appearance').valid
local identity=require('host.pbz.object_identity')
local M={};M.__index=M
local types={};for i=0,31 do types[#types+1]=i end
local color={R=0,G=0,B=0,A=0}
local function v(x,y,z)return {X=x,Y=y,Z=z}end
local function native(p)return v(p.x,p.y,p.z)end
local function finite(n)return type(n)=='number' and n==n and math.abs(n)<math.huge end
local function component(hit)
 local ok,c=pcall(function()return hit.Component:Get()end)
 return ok and valid(c) and c or nil
end
function M.new(binding)
 local self=setmetatable({binding=binding,report={queries=0},kinds={}},M)
 self.kismet=require('UEHelpers').GetKismetSystemLibrary()
 self.primitive=StaticFindObject('/Script/Engine.PrimitiveComponent')
 self.pawn_class=StaticFindObject('/Script/Engine.Pawn')
 self.volume_class=StaticFindObject('/Script/Engine.PhysicsVolume')
 self.barriers=require('host.pbz.pearl_collision').new(binding)
 return self
end
function M:_ground_kind(c)
 if not valid(c)then return 'unknown' end
 local owner=c:GetOwner()
 if not valid(owner)then return 'unknown' end
 if owner:IsA(self.pawn_class)then return 'dynamic' end
 if self.barriers:air_wall(c,owner)then return 'barrier' end
 if valid(self.volume_class) and owner:IsA(self.volume_class)then return 'water' end
 if c:GetCollisionResponseToChannel(2)~=2 then return 'ignored' end
 local physics,simulating=pcall(function()return c:IsSimulatingPhysics(FName('None'))end)
 if not physics or simulating then return 'dynamic' end
 local building=require('host.pbz.building_service').get(self.binding)
 if not building or not building.world then return 'unknown' end
 local kind=building.world:placement_obstacle(c)
 if kind~='terrain' and kind~='mc-block' then return 'dynamic' end
 local ok,velocity=pcall(function()return c:GetComponentVelocity()end)
 if not ok or not finite(velocity.X) or not finite(velocity.Y) or not finite(velocity.Z)
   or velocity.X^2+velocity.Y^2+velocity.Z^2>1 then return 'dynamic' end
 return 'static'
end
function M:ground_kind(c)
 if not valid(c)then return 'unknown' end
 local key=c:GetAddress();local previous=self.kinds[key]
 if previous and identity.matches(c,previous.identity)then return previous.kind end
 local kind=self:_ground_kind(c)
 self.kinds[key]={identity=identity.capture(c),kind=kind}
 return kind
end
function M:column(x,y,top,bottom,budget,cursor)
 assert(self.binding:is_current(),'chorus-world-changed')
 local z=cursor or top;local result={surfaces={},cost=0,complete=false}
 while result.cost<math.min(2,budget)do
  if z<=bottom then result.complete=true;break end
  local hit={};local start=v(x,y,z)
  local yes=self.kismet:LineTraceSingle(self.binding.actor,start,v(x,y,bottom),0,false,{self.binding.actor},0,hit,true,color,color,0)
  self.report.queries=self.report.queries+1;result.cost=result.cost+1
  if not yes then result.complete=true;break end
  local c=component(hit);local kind=self:ground_kind(c)
  local p,n=hit.ImpactPoint,hit.ImpactNormal
  if not p or not n or not finite(p.Z) or not finite(n.Z)then error('chorus-invalid-floor-hit')end
  -- An actor may own both a nonblocking decoration and a physical wall.
  -- Descend past a hit; never ignore that entire actor for later surfaces.
  local start_hit=not finite(hit.Time) or hit.Time<=1e-6
  if not start_hit and p.Z<=z+.1 and p.Z>=bottom then
   result.surfaces[#result.surfaces+1]={z=p.Z,normal_z=n.Z,kind=kind}
  end
  z=math.min(z-(start_hit and 32 or 2),p.Z-2)
 end
 if z<=bottom then result.complete=true end
 if not result.complete then result.cursor=z end
 -- Even an exhausted empty interval owns one unit of the query budget.
 result.cost=math.max(1,result.cost)
 return result
end
function M:clear(position,radius,half)
 assert(self.binding:is_current(),'chorus-world-changed')
 local p=native(position);local hit={};local out={}
 -- A second sweep catches blocking geometry whose overlap representation is
 -- incomplete. Destination tests retain invisible barriers as real blockers.
 local blocked=self.kismet:CapsuleTraceSingle(self.binding.actor,v(p.X,p.Y,p.Z+2),p,radius,half,
  0,false,{self.binding.actor},0,hit,true,color,color,0)
 self.kismet:CapsuleOverlapComponents(self.binding.actor,p,radius,half,types,self.primitive,{self.binding.actor},out)
 self.report.queries=self.report.queries+2
 for _,wrapped in ipairs(out)do
  local c=wrapped;if not c.GetFullName then c=c:get()end
  if not valid(c)then blocked=true;break end
  local owner=c:GetOwner()
  if c:GetCollisionResponseToChannel(2)==2 or valid(owner) and valid(self.volume_class)
    and owner:IsA(self.volume_class) and owner.bWaterVolume then blocked=true;break end
 end
 if blocked then self.report.last_rejection='occupied-destination' end
 return not blocked,2
end
function M:verify(position,radius,half)
 self.kinds={} -- Re-read support mobility/physics at commit.
 local foot=position.z-half-3;local spread=radius;local lowest,highest=foot,foot
 for _,d in ipairs({{0,0},{spread,0},{-spread,0},{0,spread},{0,-spread}})do
  local row=self:column(position.x+d[1],position.y+d[2],foot+8,foot-6,1)
  local supported=false
  for _,s in ipairs(row.surfaces)do
   if s.kind=='static' and s.normal_z>=.97 and math.abs(s.z-foot)<=6 then
    supported=true;lowest=math.min(lowest,s.z);highest=math.max(highest,s.z);break
   end
  end
  if not supported or highest-lowest>6 then return false,'support-changed' end
 end
 local clear=self:clear(position,radius,half)
 if clear then return true end
 return false,'occupied-destination'
end
function M:standing_flat(origin,radius,half)
 -- The live capsule rests closer to the floor than our destination padding.
 -- Find that immediate support first, then validate the padded standing body.
 local foot=origin.z-half+2
 local row=self:column(origin.x,origin.y,foot+12,foot-8,1)
 for _,s in ipairs(row.surfaces)do
  if s.kind=='static' and s.normal_z>=.97 and math.abs(s.z-foot)<=8 then
   return self:verify({x=origin.x,y=origin.y,z=s.z+half+3},radius,half)
  end
 end
 return false,'not-standing-on-flat-ground'
end
function M:callbacks()
 local began=os.clock()
 return {column=function(...)return self:column(...)end,clear=function(...)return self:clear(...)end,
  should_yield=function()return os.clock()-began>=.002 end}
end
return M
