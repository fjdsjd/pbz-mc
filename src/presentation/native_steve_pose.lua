-- Pure rigid-part retargeting. Coordinates are UE centimetres; no host handles.
-- Steve proportions/part pivots match the pinned upstream mesh recipe.
local M={}
local scale=100*.9375/16
local function v(x,y,z) return {X=x,Y=y,Z=z} end
local function add(a,b) return v(a.X+b.X,a.Y+b.Y,a.Z+b.Z) end
local function sub(a,b) return v(a.X-b.X,a.Y-b.Y,a.Z-b.Z) end
local function mul(a,n) return v(a.X*n,a.Y*n,a.Z*n) end
local function dot(a,b) return a.X*b.X+a.Y*b.Y+a.Z*b.Z end
local function cross(a,b) return v(a.Y*b.Z-a.Z*b.Y,a.Z*b.X-a.X*b.Z,a.X*b.Y-a.Y*b.X) end
local function unit(a,fallback)
  local length=math.sqrt(dot(a,a))
  if length<1e-6 then assert(fallback,'degenerate-pose-axis');return fallback end
  return mul(a,1/length)
end
-- Unreal FRotator basis (positive pitch points up, positive roll rotates Y down).
function M.axes(rotation)
  local p,y,r=math.rad(rotation.Pitch),math.rad(rotation.Yaw),math.rad(rotation.Roll)
  local cp,sp,cy,sy,cr,sr=math.cos(p),math.sin(p),math.cos(y),math.sin(y),math.cos(r),math.sin(r)
  return v(cp*cy,cp*sy,sp),v(sr*sp*cy-cr*sy,sr*sp*sy+cr*cy,-sr*cp),v(-cr*sp*cy-sr*sy,sr*cy-cr*sp*sy,cr*cp)
end
function M.frame(forward,up)
  up=unit(up,v(0,0,1))
  local right=cross(up,forward)
  if dot(right,right)<1e-10 then right=cross(up,math.abs(up.X)<.9 and v(1,0,0) or v(0,1,0)) end
  right=unit(right)
  forward=unit(cross(right,up))
  local horizontal=math.sqrt(forward.X^2+forward.Y^2)
  return {forward=forward,right=right,up=up,rotation={
    Pitch=math.deg(math.atan(forward.Z,horizontal)),
    Yaw=horizontal<1e-6 and 0 or math.deg(math.atan(forward.Y,forward.X)),
    Roll=math.deg(horizontal<1e-6 and math.atan(forward.Z*right.X,right.Y) or math.atan(-right.Z,up.Z)),
  }}
end
function M.head_frame(rotation,basis)
  local x,y,z=M.axes(rotation)
  if basis=='head_x_up_y_forward' then return M.frame(y,x) end
  assert(basis==nil or basis=='facial','unsupported-native-head-basis')
  return M.frame(z,mul(y,-1))
end
function M.solve(bones,face_rotation,head_basis)
  local up=unit(sub(bones.neck_01,bones.pelvis),v(0,0,1))
  local right=sub(bones.upperarm_r,bones.upperarm_l)
  local torso=M.frame(cross(right,up),up)
  local neck=bones.neck_01
  local hips=add(neck,mul(torso.up,-12*scale))
  local head=M.head_frame(face_rotation,head_basis)
  local pose={body={position=neck,rotation=torso.rotation},head={position=neck,rotation=head.rotation}}
  for _,side in ipairs({'right','left'}) do
    local suffix=side=='right' and 'r' or 'l'
    local sign=side=='right' and 1 or -1
    local arm=M.frame(torso.forward,sub(bones['upperarm_'..suffix],bones['hand_'..suffix]))
    local leg=M.frame(torso.forward,sub(bones['thigh_'..suffix],bones['foot_'..suffix]))
    pose[side..'_arm']={position=add(add(neck,mul(torso.right,sign*5*scale)),mul(torso.up,-2*scale)),rotation=arm.rotation}
    pose[side..'_leg']={position=add(hips,mul(torso.right,sign*1.9*scale)),rotation=leg.rotation}
  end
  pose.hat=pose.head;pose.jacket=pose.body
  pose.right_sleeve=pose.right_arm;pose.left_sleeve=pose.left_arm
  pose.right_pants=pose.right_leg;pose.left_pants=pose.left_leg
  return pose
end
M.scale=scale
return M
