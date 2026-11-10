-- Holding pattern, strafing and a straight charge. PBZ summons orbit their
-- owner/command home in place of the End fight's podium and crystal waypoints.
local M={}
local function wrap(a)return (a+180)%360-180 end
local function clamp(x,a,b)return math.max(a,math.min(b,x))end
local function holding(m,now,leave_target)
 m.dragon_phase='holding';m.dragon_until=now+2;m.charge_point=nil
 m.dragon_exit=nil
 if leave_target then
  local yaw=math.rad(m.yaw or 0);local p=m.position
  m.dragon_exit={X=p.X+2000*math.cos(yaw),Y=p.Y+2000*math.sin(yaw),Z=p.Z+200}
 end
end
function M.finish_pass(m,now)
 holding(m,now,true);m.dragon_strikes=(m.dragon_strikes or 0)+1
end
local facing_threshold=math.cos(math.rad(10))
function M.breath_ready(m,now,visible,enemy)
 -- StrafePlayerPhase charges while the target is visible, then checks the
 -- horizontal angle. A steep shot at a target below still faces that target.
 local elapsed=clamp(now-(m.dragon_sighted or now-.05),0,.25)
 m.dragon_sighted=now
 m.breath_charge=clamp((m.breath_charge or 0)+(visible and elapsed or -elapsed),0,.25)
 if not visible or m.breath_charge<.25-1e-8 then return false end
 local dx,dy=enemy.X-m.position.X,enemy.Y-m.position.Y
 local yaw=math.rad(m.yaw or 0)
 return dx*math.cos(yaw)+dy*math.sin(yaw)>math.sqrt(dx*dx+dy*dy)*facing_threshold
end
function M.goal(m,now,home,enemy,id)
 if not enemy then
  if m.dragon_phase~='holding' or m.dragon_target then holding(m,now) end
  m.dragon_target=nil
 elseif m.dragon_target~=id or m.dragon_phase=='holding' and now>=m.dragon_until then
  m.dragon_target=id;m.dragon_phase='strafe';m.dragon_until=now+5
  m.breath_charge=0;m.dragon_sighted=now;m.dragon_shot=m.last_attack;m.dragon_exit=nil
 end
 if m.dragon_phase=='strafe' and ((m.last_attack or -1)>(m.dragon_shot or -1) or now>=m.dragon_until) then
  m.dragon_shot=m.last_attack;m.dragon_phase='charge';m.dragon_until=now+4
  m.charge_point={X=enemy.X,Y=enemy.Y,Z=enemy.Z}
 end
 local p=m.position
 if m.dragon_phase=='charge' then
  local goal=m.charge_point
  if now<m.dragon_until and (goal.X-p.X)^2+(goal.Y-p.Y)^2+(goal.Z-p.Z)^2>120^2 then return goal end
  holding(m,now,true)
 end
 if m.dragon_phase=='strafe' then return {X=enemy.X,Y=enemy.Y,Z=enemy.Z+180} end
 if m.dragon_exit then return m.dragon_exit end
 -- Always aim ahead on the circle. Waiting at a fixed orbit point used to
 -- leave a summoned dragon hovering for its entire idle period.
 local dx,dy=p.X-home.X,p.Y-home.Y
 local angle=(math.abs(dx)+math.abs(dy)>1 and math.atan(dy,dx) or (m.serial or 1)*2.4)+.85
 return {X=home.X+820*math.cos(angle),Y=home.Y+820*math.sin(angle),Z=home.Z+180}
end
function M.steer(m,goal,now)
 local dx,dy,dz=goal.X-m.position.X,goal.Y-m.position.Y,goal.Z-m.position.Z
 local dt=clamp(now-(m.dragon_steered or now-.05),0,.25);m.dragon_steered=now
 local desired=math.deg(math.atan(dy,dx));local yaw=m.yaw or desired
 local delta=clamp(wrap(desired-yaw),-50,50)
 local ticks=dt*20;local damping=.8^ticks
 m.dragon_turn=(m.dragon_turn or 0)*damping+delta*(1-damping)
 yaw=wrap(yaw+m.dragon_turn*.1*ticks)
 local pitch=clamp(dz/math.max(1,math.sqrt(dx*dx+dy*dy)),-.6,.6)
 local norm=1/math.sqrt(1+pitch*pitch)
 return yaw,{X=math.cos(math.rad(yaw))*norm,Y=math.sin(math.rad(yaw))*norm,Z=pitch*norm}
end
return M
