-- MC GUI-pixel atan response, expressed in the preview's UE +X-forward frame.
-- The renderer owns its own parts; these transforms never target the player.
local frame=require('presentation.native_steve_pose')
local M={}
local function vector(x,y,z) return {X=x,Y=y,Z=z} end
local function transform(value,forward,right,up)
  return vector(value.X*forward.X+value.Y*right.X+value.Z*up.X,
    value.X*forward.Y+value.Y*right.Y+value.Z*up.Y,value.X*forward.Z+value.Y*right.Z+value.Z*up.Z)
end
function M.look(pointer,layout)
  local rect=layout.preview
  if not pointer or not pointer.focused then return {body_yaw=0,head_yaw=0,head_pitch=0,tilt=0} end
  local a=math.atan(((rect.x+rect.w/2)-pointer.x)/(40*layout.scale))
  local b=math.atan(((rect.y+rect.h/2)-pointer.y)/(40*layout.scale))
  -- The factors multiply atan's radian result into degrees, as in MC.
  return {body_yaw=20*a,head_yaw=40*a,head_pitch=20*b,tilt=20*b}
end
function M.solve(parts,look,anchor)
  local global_f,global_r,global_u=frame.axes({Pitch=look.tilt,Yaw=0,Roll=0})
  local body_f,body_r,body_u=frame.axes({Pitch=0,Yaw=look.body_yaw,Roll=0})
  local head_f,_,head_u=frame.axes({Pitch=look.head_pitch,Yaw=look.head_yaw,Roll=0})
  local body=frame.frame(transform(body_f,global_f,global_r,global_u),transform(body_u,global_f,global_r,global_u))
  local head=frame.frame(transform(head_f,global_f,global_r,global_u),transform(head_u,global_f,global_r,global_u))
  local center=vector(0,0,-8*frame.scale)
  local result={}
  for _,part in ipairs(parts) do
    local point=transform(part.pivot,body_f,body_r,body_u)
    point=vector(point.X-center.X,point.Y-center.Y,point.Z-center.Z)
    point=transform(point,global_f,global_r,global_u)
    result[part.name]={position=vector(anchor.X+center.X+point.X,anchor.Y+center.Y+point.Y,anchor.Z+center.Z+point.Z),
      rotation=(part.name=='head' or part.name=='hat') and head.rotation or body.rotation}
  end
  return result
end
return M
