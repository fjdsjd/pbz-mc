-- Original 1.21.1 ElytraEntityModel.setAngles + ElytraFeatureRenderer offset.
-- Angles remain the original MC radians. The .1 client render easing is made
-- frame-rate independent at a 60 Hz reference; it does not advance gameplay.
local native=require('presentation.native_steve_pose')
local rigid=require('presentation.rigid_transform')
local M={}
local zero={X=0,Y=0,Z=0}
local function finite(n)
  assert(type(n)=='number' and n==n and math.abs(n)<math.huge,'invalid-elytra-pose-number');return n
end
local function rotation(x,y,z)
  -- ModelPart applies rotationZYX, which is not the same as assigning all
  -- three UE Euler fields at once after the reflected MC-to-UE axis mapping.
  local rz={position=zero,rotation={Pitch=0,Yaw=0,Roll=-math.deg(z)}}
  local ry={position=zero,rotation={Pitch=0,Yaw=math.deg(y),Roll=0}}
  local rx={position=zero,rotation={Pitch=-math.deg(x),Yaw=0,Roll=0}}
  return rigid.compose(rigid.compose(rz,ry),rx).rotation
end
function M.relative(parent,child)
  local f,r,u=native.axes(parent.rotation)
  local function inverse(v)
    return {X=f.X*v.X+f.Y*v.Y+f.Z*v.Z,Y=r.X*v.X+r.Y*v.Y+r.Z*v.Z,Z=u.X*v.X+u.Y*v.Y+u.Z*v.Z}
  end
  local cf,_,cu=native.axes(child.rotation)
  return {position=inverse({X=child.position.X-parent.position.X,Y=child.position.Y-parent.position.Y,Z=child.position.Z-parent.position.Z}),
    rotation=native.frame(inverse(cf),inverse(cu)).rotation}
end
function M.target(state)
  state=state or {}
  local x,y,z,pivot_y=math.pi/12,0,-math.pi/12,0
  if state.gliding then
    local v=state.velocity or zero
    local vx,vy,vz=finite(v.X),finite(v.Y),finite(v.Z)
    local blend=1
    if vz<0 then
      local length=math.sqrt(vx*vx+vy*vy+vz*vz)
      blend=1-(-vz/length)^1.5
    end
    x=blend*math.pi/9+(1-blend)*x;z=blend*(-math.pi/2)+(1-blend)*z
  elseif state.crouching then x=math.pi*2/9;y=.08726646;z=-math.pi/4;pivot_y=3 end
  return {pitch=x,yaw=y,roll=z,pivot_y=pivot_y}
end
function M.advance(clock,state)
  local target=M.target(state)
  if not clock.pitch then
    -- Initial equip/preview renders the valid pose immediately, without the
    -- original player's otherwise unrelated zero-initialized client fields.
    clock.pitch=target.pitch;clock.yaw=target.yaw;clock.roll=target.roll
  else
    local dt=finite(state and state.dt or 1/60);assert(dt>=0,'invalid-elytra-pose-delta')
    local blend=1-.9^(math.min(dt,.1)*60)
    for _,key in ipairs({'pitch','yaw','roll'})do
      local delta=target[key]-clock[key]
      clock[key]=math.abs(delta)<1e-6 and target[key] or clock[key]+delta*blend
    end
  end
  clock.pivot_y=target.pivot_y
  return clock
end
function M.solve(clock,state,wings)
  state=state or {};local angles=M.advance(clock,state);local result={}
  local body=state.body_local
  if not body and state.mc_pose and state.crouching and not state.gliding then
    body={position={X=0,Y=0,Z=-3.2*native.scale},rotation={Pitch=-math.deg(.5),Yaw=0,Roll=0}}
  end
  for _,name in ipairs({'left_wing','right_wing'})do
    local pivot=assert(wings[name]).pivot_cm
    local sign=name=='left_wing' and 1 or -1
    local target={position={X=pivot[1],Y=pivot[2],Z=pivot[3]-angles.pivot_y*native.scale},
      rotation=rotation(angles.pitch,sign*angles.yaw,sign*angles.roll)}
    result[name]=body and M.relative(body,target) or target
  end
  return result
end
M.rotation=rotation
return M
