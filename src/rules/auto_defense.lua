-- Times are PBZ game seconds. A received handle identifies one strike, including
-- individual hits in a combo. Nothing in this state survives leaving combat.
local M={}

function M.new()
  return {sent={},pass=0}
end

function M.begin(state,now,delta)
  state.guard=nil
  state.dodge=nil
  state.fallback=nil
  state.now=now
  state.pass=state.pass+1
  state.step=math.max(0,math.min(delta,.18))
  -- The predicted contact is the strike centre. A wide sweep or a fast
  -- projectile can reach the front of the capsule before that instant.
  -- Also reserve a game tick for Enhanced Input to evaluate the press.
  state.lead=.105+state.step
end

function M.consider(state,handle,time,dodge,hit,fallback)
  local sent=state.sent[handle]
  if sent and sent.stamp==time then sent.pass=state.pass else sent=nil end
  -- PBZ also publishes on-contact frames. Their HitGameTime is -FLT_MAX
  -- until contact ends. A timed melee sweep can first reach the receiver
  -- just after its predicted centre, while the frame is still live.
  local contact=time < -3e38
  local remaining=contact and 0 or time-state.now
  if hit or remaining < -math.min(.045,state.step) or remaining>state.lead then return end
  if sent then
    -- Enhanced Input can reject a press during an action transition. Allow
    -- one more edge near impact only while the native frame is outstanding.
    if contact or fallback or sent.attempts>=2 or state.now-sent.at<.075
      or remaining>math.max(.022,math.min(.045,state.step)) then return end
  end
  local deadline=state.now+math.max(0,remaining)
  local action=dodge and 'dodge' or 'guard'
  local lane=fallback and 'fallback' or action
  local best=state[lane]
  if not best or deadline<best.time or (deadline==best.time and handle<best.handle)then
    state[lane]={action=action,handle=handle,time=deadline,stamp=time,contact=contact,fallback=fallback}
  end
end

function M.choose(state)
  for handle,entry in pairs(state.sent) do
    if entry.pass~=state.pass and not (entry.fallback and entry.stamp>=state.now-.045)then state.sent[handle]=nil end
  end
  local guard,dodge=state.guard,state.dodge
  -- A guard cannot cover an unblockable impact on the same input tick.
  if dodge and (not guard or dodge.time<=guard.time+math.min(.05,state.step))then return dodge end
  return guard or state.fallback
end

-- Reach the player's capsule before impact. Sender rotation is relative to
-- the attacker. PBZ can publish a zero-width cone on short limb strikes.
function M.in_sweep(dx,dy,dz,yaw,radius,angle,body)
  if radius<=0 or math.abs(dz)>body.half+65 then return false end
  local facing=math.rad(yaw)
  local forward=dx*math.cos(facing)+dy*math.sin(facing)
  local side=math.abs(dy*math.cos(facing)-dx*math.sin(facing))
  return forward>=-body.radius*.25 and dx*dx+dy*dy<=(radius+body.radius)^2
    and side<=body.radius+math.max(0,forward)*math.tan(math.rad(math.min(85,math.max(0,angle))))
end

-- Entry into the horizontal capsule radius and its vertical extent must
-- overlap in time. Velocities and offsets are relative to the moving player.
function M.projectile_eta(x,y,z,vx,vy,vz,body,horizon)
  local speed=vx*vx+vy*vy
  if speed+vz*vz<220^2 then return end
  local enter,leave=0,horizon
  local side=x*x+y*y-(body.radius+8)^2
  if speed>1 then
    local toward=x*vx+y*vy
    if toward>=0 and side>0 then return end
    local det=toward*toward-speed*side
    if det<0 then return end
    local spread=math.sqrt(det)
    enter=math.max(enter,(-toward-spread)/speed)
    leave=math.min(leave,(-toward+spread)/speed)
  elseif side>0 then return end
  local height=body.half+8
  if math.abs(vz)>1 then
    local a,b=(-height-z)/vz,(height-z)/vz
    enter=math.max(enter,math.min(a,b));leave=math.min(leave,math.max(a,b))
  elseif math.abs(z)>height then return end
  if enter<=leave then return enter end
end

function M.dispatched(state,hit)
  local old=state.sent[hit.handle]
  local attempts=(old and old.stamp==hit.stamp) and old.attempts or 0
  state.sent[hit.handle]={stamp=hit.stamp,pass=state.pass,at=state.now,attempts=attempts+1,fallback=hit.fallback}
end

return M
