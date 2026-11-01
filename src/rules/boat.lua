-- MC 1.21.1 BoatEntity / VehicleEntity rules, adapted to UE centimetres.
-- One step is exactly 1/20 second. Native movement, seats, damage sources,
-- collision, lifecycle release and persistence belong to the host adapter.
-- User overrides: no drops/creative one-hit bypass; a joining player drives
-- from the first free pair of seats even if one mob boarded before them.
local M={id='pbzmc:boat',tick_seconds=.05,max_passengers=2,width=137.5,height=56.25,
  terminal_fall_step=200} -- Host streaming can remove support indefinitely; cm per 20-Hz tick.
local fluid_flow=require('rules.fluid_flow')
local function finite(n)return type(n)=='number' and n==n and math.abs(n)<math.huge end
local function f32(n)return string.unpack('<f',string.pack('<f',n))end
local function key_valid(key)return type(key)=='string' and #key>0 and #key<=4096 and not key:find('\0',1,true)end
local function index_of(state,key)
  for i,rider in ipairs(state.riders)do if rider.key==key then return i end end
end
function M.new(record)
  assert(type(record)=='table' and finite(record.x) and finite(record.y) and finite(record.z)
    and finite(record.yaw),'invalid-boat-record')
  return {x=record.x,y=record.y,z=record.z,yaw=record.yaw,vx=0,vy=0,vz=0,delta_yaw=0,
    damage=0,hurt_ticks=0,hurt_dir=1,riders={},paddles={0,0},paddling={left=false,right=false},ticks=0}
end
function M.board(state,key,kind)
  assert(key_valid(key) and (kind=='player' or kind=='mob'),'invalid-boat-rider')
  if state.destroyed then return nil,'boat-destroyed' end
  local existing=index_of(state,key)
  if existing then
    if state.riders[existing].kind~=kind then return nil,'rider-kind-changed' end
    return existing,'already-aboard'
  end
  if #state.riders>=M.max_passengers then return nil,'boat-full' end
  if kind=='player' then
    for _,rider in ipairs(state.riders)do if rider.kind=='player' then return nil,'driver-already-aboard' end end
    table.insert(state.riders,1,{key=key,kind=kind});return 1
  end
  state.riders[#state.riders+1]={key=key,kind=kind};return #state.riders
end
function M.unboard(state,key)
  local index=index_of(state,key)
  if not index then return false end
  table.remove(state.riders,index);return true,index
end
function M.offset(state,index)
  assert(type(index)=='number' and index%1==0 and index>=1 and index<=#state.riders,'invalid-boat-seat')
  -- Oak BoatEntity's own height / 3, not the rider's capsule height. The host
  -- adds each rider's seating/root offset when anchoring its native actor.
  return {x=#state.riders>1 and (index==1 and 20 or -60) or 0,y=0,z=M.height/3}
end
function M.hit(state,amount)
  assert(finite(amount) and amount>=0,'invalid-boat-damage')
  if state.destroyed then return true end
  local damage=f32(state.damage+f32(f32(amount)*10))
  assert(finite(damage),'boat-damage-overflow')
  state.hurt_dir=-state.hurt_dir;state.hurt_ticks=10;state.damage=damage
  if state.damage>40 then state.destroyed=true end
  -- Riders intentionally remain owned until the host completes release and
  -- object removal. A damage event is never allowed to silently drop a lease.
  return state.destroyed==true
end
function M.step(state,input,surface)
  input=input or {};surface=surface or {kind='land'}
  assert(surface.kind=='land' or surface.kind=='water' or surface.kind=='air','invalid-boat-surface')
  local friction=surface.friction
  if friction==nil then friction=surface.kind=='land' and .6 or .9 end
  assert(finite(friction) and friction>=0 and friction<=1,'invalid-boat-friction')
  assert(surface.ground_z==nil or finite(surface.ground_z),'invalid-boat-ground')
  assert(surface.water_level==nil or finite(surface.water_level),'invalid-boat-water-level')
  for _,key in ipairs({'forward','back','left','right'})do
    assert(input[key]==nil or type(input[key])=='boolean','invalid-boat-input')
  end
  if state.destroyed then return nil,'boat-destroyed' end
  for _,key in ipairs({'x','y','z','yaw','vx','vy','vz','delta_yaw','damage'})do assert(finite(state[key]),'invalid-boat-state:'..key)end
  state.ticks=state.ticks+1
  if state.hurt_ticks>0 then state.hurt_ticks=state.hurt_ticks-1 end
  -- Vanilla subtracts one from a positive float, even if it crosses just below
  -- zero. Do not replace this transient wobble value with an invented HP bar.
  if state.damage>0 then state.damage=f32(state.damage-1) end
  if surface.kind=='water' and surface.flow then
    local push=fluid_flow.impulse(surface.flow,'water',{X=state.vx*20,Y=state.vy*20,Z=state.vz*20},false)
    state.vx=state.vx+push.X/20;state.vy=state.vy+push.Y/20;state.vz=state.vz+push.Z/20
  end
  local enter_water=state.last_surface=='air'and surface.kind=='water'and surface.water_level~=nil
  state.vx=state.vx*friction;state.vy=state.vy*friction;state.delta_yaw=state.delta_yaw*friction
  local gravity=surface.kind=='water'and surface.underwater and surface.falling and .07 or 4
  state.vz=math.max(-M.terminal_fall_step,state.vz-gravity)
  local submerged=0
  if surface.kind=='water' and surface.water_level then
    if surface.underwater and not surface.falling then submerged=.01
    elseif not surface.underwater then submerged=math.max(0,(surface.water_level-state.z)/M.height)end
    if submerged>0 then state.vz=(state.vz+submerged*(4/.65))*.75 end
  end
  local driven=state.riders[1] and state.riders[1].kind=='player'
  local left=driven and input.left==true or false;local right=driven and input.right==true or false
  local forward=driven and input.forward==true or false;local back=driven and input.back==true or false
  if left then state.delta_yaw=state.delta_yaw-1 end
  if right then state.delta_yaw=state.delta_yaw+1 end
  local yaw=state.yaw+(#state.riders>0 and state.delta_yaw or 0)
  local acceleration=0
  if left~=right and not forward and not back then acceleration=acceleration+.5 end
  if forward then acceleration=acceleration+4 end
  if back then acceleration=acceleration-.5 end
  local angle=math.rad(yaw)
  state.vx=state.vx+math.cos(angle)*acceleration;state.vy=state.vy+math.sin(angle)*acceleration
  local z=state.z+state.vz
  -- Predict the vanilla air-to-water snap. The host still sweeps the full hull
  -- before accepting this pose; no liquid is permitted to bypass terrain.
  if enter_water then z=surface.water_level-M.height+10.1;state.vz=0 end
  state.last_surface=surface.kind
  if surface.ground_z and z<=surface.ground_z then z=surface.ground_z;state.vz=0 end
  state.paddling={left=right and not left or forward,right=left and not right or forward}
  for i,moving in ipairs({state.paddling.left,state.paddling.right})do
    state.paddles[i]=moving and (state.paddles[i]+math.pi/8) or 0
  end
  return {x=state.x+state.vx,y=state.y+state.vy,z=z,yaw=yaw,
    paddling={left=state.paddling.left,right=state.paddling.right},paddles={state.paddles[1],state.paddles[2]},
    destroyed=false}
end
function M.wobble(state,partial)
  partial=partial or 0;assert(finite(partial) and partial>=0 and partial<=1,'invalid-boat-partial-tick')
  local ticks=state.hurt_ticks-partial
  if ticks<=0 then return 0 end
  return math.sin(ticks)*ticks*math.max(0,state.damage-partial)/10*state.hurt_dir
end
function M.paddle_angles(state,index,partial)
  assert(index==1 or index==2,'invalid-boat-paddle')
  partial=partial or 1;assert(finite(partial) and partial>=0 and partial<=1,'invalid-boat-partial-tick')
  local moving=index==1 and state.paddling.left or index==2 and state.paddling.right
  local phase=moving and (state.paddles[index]-math.pi/8+math.pi/8*partial) or 0
  local pitch=-math.pi/3+(math.pi/4)*((math.sin(-phase)+1)/2)
  local yaw=-math.pi/4+(math.pi/2)*((math.sin(-phase+1)+1)/2)
  if index==2 then yaw=math.pi-yaw end
  return {pitch=pitch,yaw=yaw,roll=math.pi/16,phase=phase}
end
return M
