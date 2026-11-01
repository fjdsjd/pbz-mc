-- Vanilla MC 1.21.1 LivingEntity.travel / PlayerEntity.checkFallFlying.
-- Host-independent: UE centimetres, seconds, XY horizontal, Z up, yaw +X,
-- pitch positive upwards. Exactly one call to step per 1/20 s game tick.
-- No durability, native pointers, input injection, position commits or HP writes.
local M={tick_seconds=.05,centimetres_per_block=100,velocity_scale=2000,
  default_gravity_cm_tick2=8}

local function finite(v)return type(v)=='number' and v==v and math.abs(v)<math.huge end
local function f32(v)return (string.unpack('<f',string.pack('<f',v)))end
local function vector(v,label)
  assert(type(v)=='table','invalid-'..label)
  local x,y,z=v.X or v.x,v.Y or v.y,v.Z or v.z
  assert(finite(x) and finite(y) and finite(z),'invalid-'..label)
  return x,y,z
end
local function velocity(state)
  assert(type(state)=='table' and finite(state.vx) and finite(state.vy) and finite(state.vz),'invalid-elytra-state')
  return state.vx,state.vy,state.vz
end
local function vec(x,y,z)return {X=x,Y=y,Z=z}end
local radians=f32(math.pi/180)
local sine_index_scale=f32(10430.378)
local sin_cache={}
local function table_sine(index)
  index=index & 65535
  local result=sin_cache[index]
  if result==nil then result=f32(math.sin(index*math.pi*2/65536));sin_cache[index]=result end
  return result
end
local function java_int(v)return v<0 and math.ceil(v) or math.floor(v)end
-- Match MathHelper's float multiplication, truncation and 65536-entry table.
local function mc_sin(v)return table_sine(java_int(f32(v*sine_index_scale)))end
local function mc_cos(v)return table_sine(java_int(f32(f32(v*sine_index_scale)+16384)))end

function M.look_from_angles(yaw,pitch)
  assert(finite(yaw) and finite(pitch),'invalid-elytra-angles')
  local f=f32(f32(-pitch)*radians)
  local g=f32(-f32(yaw-90)*radians)
  return vec(f32(mc_sin(g)*mc_cos(f)),f32(mc_cos(g)*mc_cos(f)),-mc_sin(f))
end

function M.new(initial)
  initial=initial or {}
  local s={vx=initial.vx or 0,vy=initial.vy or 0,vz=initial.vz or 0,ticks=0}
  velocity(s)
  return s
end

function M.can_start(env)
  env=env or {}
  if env.jump_pressed~=true then return false,'new-jump-required' end
  if env.equipped~=true then return false,'elytra-not-equipped' end
  if env.alive==false then return false,'not-alive' end
  for _,key in ipairs({'on_ground','gliding','touching_water','levitating','passenger','climbing','native_flying'})do
    if env[key] then return false,key end
  end
  -- Vanilla has no downward-velocity requirement; a second press while rising
  -- can start gliding. Holding the first jump does not manufacture that press.
  return true
end

function M.can_continue(env)
  env=env or {}
  if env.equipped~=true then return false,'elytra-not-equipped' end
  if env.alive==false then return false,'not-alive' end
  for _,key in ipairs({'on_ground','passenger','levitating'})do
    if env[key] then return false,key end
  end
  -- In 1.21.1 fluid travel wins over the glide branch without itself clearing
  -- flag 7. The host must hand movement to fluid rules while touching fluid.
  return true
end

function M.limit_fall_distance(distance_cm,vz_cm_s)
  assert(finite(distance_cm) and distance_cm>=0 and finite(vz_cm_s),'invalid-fall-distance')
  if vz_cm_s>-1000 and distance_cm>100 then return 100 end
  return distance_cm
end

function M.step(state,input,env)
  assert(type(input)=='table' and finite(input.pitch),'invalid-elytra-input')
  env=env or {}
  local vx,vy,vz=velocity(state)
  local lx,ly,lz=vector(input.look,'elytra-look')
  local gravity=env.gravity_cm_tick2
  if gravity==nil then gravity=M.default_gravity_cm_tick2 end
  assert(finite(gravity),'invalid-elytra-gravity')
  local x,y,z=vx/2000,vy/2000,vz/2000
  local before=math.sqrt(x*x+y*y)
  local horizontal=math.sqrt(lx*lx+ly*ly)
  local length=math.sqrt(lx*lx+ly*ly+lz*lz)
  local pitch=f32(f32(-input.pitch)*radians)
  local lift=math.cos(pitch)
  lift=lift*lift*math.min(1,length/.4)
  gravity=gravity/100
  if z<=0 and env.slow_falling then gravity=math.min(gravity,.01) end
  z=z+gravity*(-1+lift*.75)
  if z<0 and horizontal>0 then
    local convert=z*-.1*lift
    x,y,z=x+lx*convert/horizontal,y+ly*convert/horizontal,z+convert
  end
  if pitch<0 and horizontal>0 then
    local convert=before*-mc_sin(pitch)*.04
    x,y,z=x-lx*convert/horizontal,y-ly*convert/horizontal,z+convert*3.2
  end
  if horizontal>0 then
    x=x+(lx/horizontal*before-x)*.1
    y=y+(ly/horizontal*before-y)*.1
  end
  x,y,z=x*f32(.99),y*f32(.99),z*f32(.98)
  assert(finite(x) and finite(y) and finite(z),'elytra-velocity-overflow')
  state.vx,state.vy,state.vz=x*2000,y*2000,z*2000
  state.ticks=state.ticks+1
  return {delta=vec(x*100,y*100,z*100),velocity=vec(state.vx,state.vy,state.vz),
    before_horizontal_speed=before*2000,tick=state.ticks}
end

function M.collide(state,frame,contact)
  velocity(state)
  assert(type(frame)=='table' and finite(frame.before_horizontal_speed),'invalid-elytra-frame')
  contact=contact or {}
  local x,y,z=vector(contact.velocity,'elytra-collision-velocity')
  local damage=0
  if contact.horizontal_collision then
    local speed=math.sqrt(x*x+y*y)
    damage=math.max(0,f32((frame.before_horizontal_speed-speed)/2000*10-3))
  end
  state.vx,state.vy,state.vz=x,y,z
  return {wall_damage=damage,landed=contact.on_ground==true}
end

return M
