-- Rigid UE transforms. Scale belongs to the final mesh, never to these parents.
local frames=require('presentation.native_steve_pose')
local M={}
function M.vector(x,y,z) return {X=x,Y=y,Z=z} end
function M.rotate(rotation,value)
  local f,r,u=frames.axes(rotation)
  return M.vector(f.X*value.X+r.X*value.Y+u.X*value.Z,
    f.Y*value.X+r.Y*value.Y+u.Y*value.Z,f.Z*value.X+r.Z*value.Y+u.Z*value.Z)
end
function M.compose(parent,child)
  local offset=M.rotate(parent.rotation,child.position)
  local f,_,u=frames.axes(child.rotation)
  local basis=frames.frame(M.rotate(parent.rotation,f),M.rotate(parent.rotation,u))
  return {position=M.vector(parent.position.X+offset.X,parent.position.Y+offset.Y,parent.position.Z+offset.Z),
    rotation=basis.rotation,scale=child.scale}
end
return M
