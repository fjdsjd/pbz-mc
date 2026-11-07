-- Rigid UE transforms. Scale belongs to the final mesh, never to these parents.
local frames=require('presentation.native_steve_pose')
local M={}
function M.vector(x,y,z) return {X=x,Y=y,Z=z} end
local function rotate_axes(f,r,u,v)
  return M.vector(f.X*v.X+r.X*v.Y+u.X*v.Z,
    f.Y*v.X+r.Y*v.Y+u.Y*v.Z,f.Z*v.X+r.Z*v.Y+u.Z*v.Z)
end
function M.rotate(rotation,value)
  local f,r,u=frames.axes(rotation)
  return rotate_axes(f,r,u,value)
end
function M.compose(parent,child)
  -- All three vectors share one parent rotation. Computing its trigonometry
  -- once also avoids six temporary axis tables per composed part.
  local pf,pr,pu=frames.axes(parent.rotation)
  local offset=rotate_axes(pf,pr,pu,child.position)
  local f,_,u=frames.axes(child.rotation)
  local basis=frames.frame(rotate_axes(pf,pr,pu,f),rotate_axes(pf,pr,pu,u))
  return {position=M.vector(parent.position.X+offset.X,parent.position.Y+offset.Y,parent.position.Z+offset.Z),
    rotation=basis.rotation,scale=child.scale}
end
return M
