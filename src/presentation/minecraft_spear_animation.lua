-- Original wind-up/jab easing: MinecraftSpearAnimation.cs, wukong-steve 0.11.0.
-- Held stages and impact keyframes: Mojang/bedrock-samples, 15701fa9.
-- PolyForm Noncommercial 1.0.0; retain third_party/wukong-steve notices.
local M={}
local rigid=require('presentation.rigid_transform')
function M.progress(t,start,finish) return math.max(0,math.min(1,(t-start)/math.max(.00001,finish-start))) end
function M.in_out_sine(x) return -(math.cos(math.pi*x)-1)/2 end
function M.out_back(x) return 1+2.70158*(x-1)^3+1.70158*(x-1)^2 end
function M.in_out_expo(x)
  if x==0 or x==1 then return x end
  return x<.5 and 2^(20*x-10)/2 or (2-2^(-20*x+10))/2
end
function M.in_out_back(x)
  local c=1.70158*1.525
  if x<.5 then return (2*x)^2*((c+1)*2*x-c)/2 end
  return ((2*x-2)^2*((c+1)*(x*2-2)+c)+2)/2
end
function M.hit_feedback(ticks)
  -- Bedrock animation.spear.hit, model pixels converted to blocks.
  local t=math.max(0,ticks or 10)
  if t<1 then return 1.5*t/16 elseif t<2 then return (1.5+6*(t-1))/16
  elseif t<4 then return (7.5-.75*(t-2))/16 elseif t<10 then return (10-t)/16 end
  return 0
end
local braced={raise=1,start=1,middle=1,finish=1,tired=0,lower=0,shake=0,roll=0}
local lowered={raise=1,start=1,middle=1,finish=1,tired=1,lower=1,shake=0,roll=0}
-- A settled aim or lowered weapon has no changing transform. Reuse its holder.
function M.sample_time(spear,t)
  if t>=spear.delay+spear.knockback+.45 then return spear.delay+spear.knockback+.45 end
  if t>=spear.delay and t<=spear.delay+spear.dismount then return spear.delay end
  return t
end
function M.use(state)
  if (state.spear_charge or 0)>0 then return state.spear_charge,1 end
  return state.spear_recover_charge or 0,state.spear_recover_weight or 0
end
function M.solve(spear,seconds)
  local age=seconds-spear.delay
  if age>=spear.knockback+.45-1e-8 then return lowered end
  if age>=0 and age<=spear.dismount then return braced end
  local raise=M.progress(seconds,0,spear.delay)
  local tired=M.in_out_sine(M.progress(age,spear.dismount,spear.dismount+.75))
  local lower=M.in_out_sine(M.progress(age,spear.knockback,spear.knockback+.45))
  local tremble=tired*(1-lower)
  return {raise=raise,start=M.progress(raise,0,.5),middle=M.progress(raise,.5,.8),finish=M.progress(raise,.8,1),
    tired=tired,lower=lower,shake=math.sin(age*6.63)*tremble,roll=math.sin(age*10.47)*tremble}
end

-- MC camera offsets are in blocks. In PBZ, forward is -Z, right is X and up is Y.
local function camera_offset(x,y,z)
  return {X=-z*100,Y=x*100,Z=y*100}
end
local function translate(pose,x,y,z)
  local delta=rigid.rotate(pose.rotation,camera_offset(x,y,z))
  local p=pose.position
  p.X=p.X+delta.X;p.Y=p.Y+delta.Y;p.Z=p.Z+delta.Z
end
local function turn(pose,pitch,yaw,pivot)
  local rotation={Pitch=pitch,Yaw=yaw,Roll=0}
  local moved=rigid.rotate(rotation,pivot)
  return rigid.compose(pose,{position={X=pivot.X-moved.X,Y=pivot.Y-moved.Y,Z=pivot.Z-moved.Z},rotation=rotation})
end
function M.first_person(spear,charge,jab,recoil,side,weight)
  local pose={position={X=90,Y=side,Z=-48},rotation={Pitch=0,Yaw=0,Roll=0}}
  local jab_weight=1
  if charge>0 then
    local p=M.solve(spear,charge);local w=weight or 1
    local up=M.in_out_sine(p.raise)*w
    jab_weight=1-up
    pose.position.Y=side*(1-.40*up)
    pose.position.Z=pose.position.Z+(9*p.finish-7*p.lower)*w
    -- The original in-hand mesh stands at 80 degrees in camera space. Turn
    -- it about the hand, first toward the reticle, then in elevation.
    pose=turn(pose,0,(-19*p.raise+10*p.tired-5*p.lower+p.roll)*w,camera_offset(0,0,0))
    pose=turn(pose,(-77*M.in_out_sine(p.raise)+67*p.tired-91*p.lower+1.8*p.shake)*w,0,camera_offset(0,.1,0))
    pose.position.X=pose.position.X-100*M.hit_feedback(recoil)*w
  end
  if jab>0 then
    local a=M.in_out_sine(M.progress(jab,0,.05))
    local b=M.out_back(M.progress(jab,.05,.2))
    local c=M.in_out_expo(M.progress(jab,.4,1))
    translate(pose,.1*(a-b)*jab_weight,-.075*(a-c)*jab_weight,.65*(a-b)*jab_weight)
    pose=turn(pose,-70*(a-c)*jab_weight,0,camera_offset(0,0,0))
    translate(pose,0,0,-.25*(c-b)*jab_weight)
  end
  return pose
end
return M
