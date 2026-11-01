-- Pearl-only query policy. Native player collision and map actors never change.
local valid=require('host.pbz.appearance').valid
local M={};M.__index=M
local types={};for i=0,31 do types[#types+1]=i end
local function component(hit)
  local ok,c=pcall(function()return hit.Component:Get()end)
  return ok and valid(c) and c or nil
end
function M.new(binding)
  return setmetatable({binding=binding,report={air_hits=0},
    primitive=StaticFindObject('/Script/Engine.PrimitiveComponent'),
    pawn_class=StaticFindObject('/Script/Engine.Pawn'),
    blocking_class=StaticFindObject('/Script/Engine.BlockingVolume')},M)
end
function M:air_wall(c,owner)
  if not valid(c) or not valid(owner) or owner:IsA(self.pawn_class) then return false end
  -- Standard UE InvisibleWall[Dynamic] and PBZ Profile_LA_InvisibleWall use
  -- the same explicit collision-profile meaning; no level/actor name matching.
  local profile=c:GetCollisionProfileName():ToString():lower()
  return profile:find('invisiblewall',1,true)~=nil or valid(self.blocking_class) and owner:IsA(self.blocking_class)
end
function M:trace(start,finish,radius,projectile)
  local ignored={self.binding.actor};if valid(projectile)then ignored[#ignored+1]=projectile end
  local seen={};local color={R=0,G=0,B=0,A=0}
  for _=1,32 do
    local hit={}
    local yes=require('UEHelpers').GetKismetSystemLibrary():SphereTraceSingle(self.binding.actor,start,finish,
      radius,0,false,ignored,0,hit,true,color,color,0)
    if not yes then return false end
    local c=component(hit);local owner=valid(c) and c:GetOwner() or nil
    if not self:air_wall(c,owner) then return true,hit end
    local id=owner:GetFullName();if seen[id] then return true,hit end
    seen[id]=true;ignored[#ignored+1]=owner;self.report.air_hits=self.report.air_hits+1
  end
  -- A bounded query exhaustion cannot silently pass a later physical wall.
  error('pearl-air-wall-query-budget')
end
function M:occupied(position,radius,half)
  local out={}
  require('UEHelpers').GetKismetSystemLibrary():CapsuleOverlapComponents(self.binding.actor,position,radius,half,
    types,self.primitive,{self.binding.actor},out)
  for _,wrapped in ipairs(out) do
    local c=wrapped;if not c.GetFullName then c=c:get()end
    if c:GetCollisionResponseToChannel(2)==2 and not self:air_wall(c,c:GetOwner()) then
      self.report.occupied=c:GetFullName();return true
    end
  end
  self.report.occupied=nil;return false
end
return M
