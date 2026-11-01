-- Vanilla MC 1.21.1 FireworkRocketEntity, flight duration 1, no firework stars.
-- UE cm/s and XY horizontal/Z up. Host owns item debit, actors, collision,
-- particles, sound, attachment identity and 20-Hz scheduling.
local M={tick_seconds=.05,default_flight_duration=1,use_interval_ticks=4,
  item_cost=1,explosion_damage=0,launch_offset_cm=15}
local function finite(v)return type(v)=='number' and v==v and math.abs(v)<math.huge end
local function integer(v,lo,hi)return finite(v) and v%1==0 and v>=lo and v<=hi end
local function vector(v,label)
  assert(type(v)=='table','invalid-'..label)
  local x,y,z=v.X or v.x,v.Y or v.y,v.Z or v.z
  assert(finite(x) and finite(y) and finite(z),'invalid-'..label)
  return x,y,z
end
local function vec(x,y,z)return {X=x,Y=y,Z=z}end

function M.lifetime(duration,roll6,roll7)
  duration=duration==nil and M.default_flight_duration or duration
  assert(integer(duration,0,255),'invalid-firework-duration')
  assert(integer(roll6,0,5) and integer(roll7,0,6),'invalid-firework-random-rolls')
  return 10*(1+duration)+roll6+roll7
end

local function new(kind,duration,roll6,roll7)
  return {kind=kind,life=0,lifetime=M.lifetime(duration,roll6,roll7),removed=false}
end

function M.new_attached(duration,roll6,roll7)return new('attached',duration,roll6,roll7)end

function M.new_world(duration,roll6,roll7,triangular_x,triangular_y)
  triangular_x=triangular_x or 0;triangular_y=triangular_y or 0
  assert(finite(triangular_x) and math.abs(triangular_x)<=1 and finite(triangular_y)
    and math.abs(triangular_y)<=1,'invalid-firework-triangular-random')
  local state=new('world',duration,roll6,roll7)
  -- Each triangular input is independent uniform[0,1)-uniform[0,1).
  state.vx,state.vy,state.vz=triangular_x*.002297*2000,triangular_y*.002297*2000,100
  return state
end

function M.boost(velocity,look)
  local x,y,z=vector(velocity,'firework-velocity')
  local lx,ly,lz=vector(look,'firework-look')
  -- Keep the order of vanilla's double expression. 1 block/tick = 2000 cm/s.
  x,y,z=x/2000,y/2000,z/2000
  x=x+(lx*.1+(lx*1.5-x)*.5)
  y=y+(ly*.1+(ly*1.5-y)*.5)
  z=z+(lz*.1+(lz*1.5-z)*.5)
  assert(finite(x) and finite(y) and finite(z),'firework-velocity-overflow')
  return vec(x*2000,y*2000,z*2000)
end

local function tick(state,kind)
  assert(type(state)=='table' and state.kind==kind and integer(state.life,0,math.maxinteger)
    and integer(state.lifetime,10,2571),'invalid-firework-state')
  if state.removed then return nil,'firework-removed' end
  local event={launch=state.life==0,expired=false,boosted=false}
  state.life=state.life+1
  -- The source boosts/moves first, then increments, then tests strict >.
  if state.life>state.lifetime then state.removed=true;event.expired=true end
  return event
end

function M.step_attached(state,velocity,look,gliding)
  local x,y,z=vector(velocity,'firework-velocity')
  if gliding then vector(look,'firework-look') end
  local event,err=tick(state,'attached')
  if not event then return nil,err end
  local result=vec(x,y,z)
  if gliding then result=M.boost(result,look);event.boosted=true end
  return result,event
end

function M.step_world(state,horizontal_collision)
  assert(type(state)=='table' and finite(state.vx) and finite(state.vy) and finite(state.vz),'invalid-firework-world-state')
  local event,err=tick(state,'world')
  if not event then return nil,err end
  local factor=horizontal_collision and 1 or 1.15
  state.vx,state.vy,state.vz=state.vx*factor,state.vy*factor,state.vz+80
  local v=vec(state.vx,state.vy,state.vz)
  return {delta=vec(state.vx*.05,state.vy*.05,state.vz*.05),velocity=v},event
end

function M.entity_hit(state)
  assert(type(state)=='table','invalid-firework-state')
  if state.removed then return false end
  state.removed=true
  return true -- No star means zero damage, but entity contact still removes it.
end

return M
