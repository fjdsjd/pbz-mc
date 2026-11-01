-- A persistent, map-wide 100 cm lattice. Legacy records are never moved.
local M={size=100}
local axes={'x','y','z'}
function M.origin(buildings,world)
  local first
  for id,r in pairs(buildings) do
    if r.world==world and (not first or id<first.id) then first=r end
  end
  if first then return {x=first.x,y=first.y,z=first.z} end
end
function M.snap(value,origin)
  return origin+math.floor((value-origin)/M.size+.5)*M.size
end
function M.above(value,origin)
  return origin+math.ceil((value-origin)/M.size-1e-7)*M.size
end
function M.position(position,origin)
  local p={yaw=0}
  for _,axis in ipairs(axes) do p[axis]=M.snap(position[axis],origin[axis]) end
  return p
end
function M.native_surface(impact,normal,origin)
  -- The native surface belongs to the intersecting cell, not the first cell
  -- whose entire volume clears the terrain. Only resolve exact face ties in
  -- the outward direction; never add a half-block or round the height upward.
  local p={x=impact.X,y=impact.Y,z=impact.Z,yaw=0}
  if not origin then return p end
  local n={normal.X,normal.Y,normal.Z}
  for i,key in ipairs(axes) do
    local value=(p[key]-origin[key])/M.size+.5
    local boundary=math.floor(value+.5)
    if math.abs(value-boundary)<1e-7 and n[i]~=0 then
      value=boundary+(n[i]<0 and -1e-7 or 1e-7)
    end
    p[key]=origin[key]+math.floor(value)*M.size
  end
  return p
end
function M.adjacent(record,normal,origin)
  local axis=require('rules.placement_geometry').face_axis(normal.X,normal.Y,normal.Z)
  local key=axes[axis+1];local sign=({normal.X,normal.Y,normal.Z})[axis+1]<0 and -1 or 1
  local p=M.position(record,origin)
  -- Old off-grid blocks may need a wider gap; never put the new aligned cube
  -- partly inside them. New blocks are always exactly one cell apart.
  p[key]=sign>0 and M.above(record[key]+100,origin[key]) or -M.above(-record[key]+100,-origin[key])
  return p
end
return M
