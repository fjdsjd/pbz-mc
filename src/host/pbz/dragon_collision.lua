local valid=require('host.pbz.appearance').valid
local M={}
local function transform(p)
 return {Translation=p,Rotation={X=0,Y=0,Z=0,W=1},Scale3D={X=1,Y=1,Z=1}}
end
function M.spawn(world,p)
 -- Ordinary SpawnActor tests the default Character capsule before Lua gets it.
 local t=transform(p);local gs=StaticFindObject('/Script/Engine.Default__GameplayStatics')
 local a=gs:BeginDeferredActorSpawnFromClass(world.pawn,world.char,t,1,nil,0) -- AlwaysSpawn
 if not valid(a) then return end
 local ok,result=pcall(function()return gs:FinishSpawningActor(a,t,0)end)
 if not ok or not valid(result) then a:K2_DestroyActor();if not ok then error(result)end;return end
 return result
end
function M.target_only(component)
 component:SetCollisionResponseToAllChannels(0)
 component:SetCollisionResponseToChannel(3,2) -- weapon/selection visibility traces
 component:SetCollisionEnabled(1) -- QueryOnly
end
-- Java EnderDragonPart dimensions in cm. Attached queries follow the already
-- animated joints and return the same actor to damage, commands and dismissal.
local parts={{'head',50,50},{'neck3',150,150},{'body',250,150},
 {'tail2',100,100},{'tail6',100,100},{'tail10',100,100},
 {'wing',200,100,210},{'wing1',200,100,-210}}
function M.attach(m)
 local cls=StaticFindObject('/Script/Engine.BoxComponent')
 for _,part in ipairs(parts)do
  local component=m.actor:AddComponentByClass(cls,false,transform({X=0,Y=0,Z=0}),false)
  assert(valid(component),'dragon-hitbox:'..part[1])
  component:SetCollisionEnabled(0)
  assert(component:K2_AttachToComponent(m.parts[part[1]].component,FName('None'),2,2,2,false),'dragon-hitbox-parent')
  component:SetBoxExtent({X=part[2],Y=part[2],Z=part[3]},false)
  component:K2_SetRelativeLocation({X=0,Y=part[4] or 0,Z=0},false,{},true)
  component:SetCollisionObjectType(2);M.target_only(component)
 end
end
return M
