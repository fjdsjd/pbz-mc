-- MC FlowingFluid.getFlow / EntityFluidInteraction.CurrentAccumulator.
-- Neighbour offsets and vectors are already PBZ X/Y/Z-up; no actors or scans.
local fluids=require('rules.fluid_network')
local M={water_scale=.014,lava_scale=.007/3,velocity_scale=2000}
local sides={{1,0,0},{-1,0,0},{0,1,0},{0,-1,0}}
local function normalized(x,y,z)
  local length=math.sqrt(x*x+y*y+z*z)
  if length<1e-8 then return {x=0,y=0,z=0}end
  return {x=x/length,y=y/length,z=z/length}
end
function M.vector(cell,read,solid)
  local kind=fluids.kind(cell);if not kind then return {x=0,y=0,z=0}end
  local own=fluids.height(cell);local x,y,z=0,0,0
  for _,d in ipairs(sides)do
    local other=read(d[1],d[2],0);local other_kind=fluids.kind(other)
    if not other_kind or other_kind==kind then
      local height=fluids.height(other);local delta=0
      if height==0 then
        if not solid(other,d[1],d[2],0)then
          local below=read(d[1],d[2],-1)
          if fluids.kind(below)==kind then delta=own-(fluids.height(below)-8/9)end
        end
      else delta=own-height end
      x=x+d[1]*delta;y=y+d[2]*delta
    end
  end
  if fluids.falling(cell)then
    for _,d in ipairs(sides)do
      local side,above=read(d[1],d[2],0),read(d[1],d[2],1)
      if fluids.kind(side)~=kind and solid(side,d[1],d[2],0)
          or fluids.kind(above)~=kind and solid(above,d[1],d[2],1)then
        local n=normalized(x,y,0);x,y,z=n.x,n.y,-6;break
      end
    end
  end
  return normalized(x,y,z)
end
-- Each fluid cell is included once. depth is its surface above entity feet in
-- blocks, not a fraction of the entity's full height. No native pointers kept.
function M.average(samples)
  local x,y,z,height,count=0,0,0,0,0
  for _,row in ipairs(samples or {})do
    height=math.max(height,row.depth or 0)
    local scale=height<.4 and height or 1;local f=row.flow
    x=x+f.x*scale;y=y+f.y*scale;z=z+f.z*scale;count=count+1
  end
  if count==0 or x*x+y*y+z*z<1e-5 then return {x=0,y=0,z=0,count=count}end
  return {x=x/count,y=y/count,z=z/count,count=count}
end
-- Returns an additive cm/s impulse for ONE 20-Hz game tick. The host applies
-- this through CharacterMovement/LaunchCharacter or the boat's swept move.
function M.impulse(current,kind,velocity,player)
  if not current then return {X=0,Y=0,Z=0}end
  local x,y,z=current.x or 0,current.y or 0,current.z or 0
  if x*x+y*y+z*z<1e-10 then return {X=0,Y=0,Z=0}end
  if not player then local n=normalized(x,y,z);x,y,z=n.x,n.y,n.z end
  local scale=(kind=='lava'or kind==fluids.lava)and M.lava_scale or M.water_scale
  scale=scale*M.velocity_scale;x,y,z=x*scale,y*scale,z*scale
  velocity=velocity or {};local vx,vy=velocity.X or 0,velocity.Y or 0
  if math.abs(vx)<6 and math.abs(vy)<6 and x*x+y*y+z*z<81 then
    local n=normalized(x,y,z);x,y,z=n.x*9,n.y*9,n.z*9
  end
  return {X=x,Y=y,Z=z}
end
return M
