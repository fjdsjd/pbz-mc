-- wukong-steve 0.11.0, MinecraftWorld.cs Prime / Explosion / Update.
-- UE centimetres; fixed 20 Hz physics. The host owns actors, sweeps, line of
-- sight, damage, building transactions and removal. No native values live here.
local M={id='pbzmc:tnt',tick_seconds=.05,fuse_seconds=4,sweep_radius=48,
  blast_radius=800,fire_seconds=8,fire_interval=.5,fire_radius=110,fire_coefficient=.18}
local blocks=require('content.blocks')
local flow=require('rules.fluid_flow')
local half_height=49 -- PrimedTnt is .98 blocks tall; positions here are mesh centres.
local EPS=1e-9
local function finite(n)return type(n)=='number' and n==n and math.abs(n)<math.huge end
local function position(p)
  assert(type(p)=='table','invalid-tnt-position')
  for _,axis in ipairs({'x','y','z'})do
    assert(finite(p[axis]) and math.abs(p[axis])<=1e9,'invalid-tnt-position:'..axis)
  end
end
local function random_unit(value)
  assert(finite(value) and value>=0 and value<1,'invalid-tnt-random')
  return value
end
local function distance_valid(distance)
  assert(finite(distance) and distance>=0,'invalid-tnt-distance')
end
function M.new(record)
  position(record)
  return {x=record.x,y=record.y,z=record.z,vx=0,vy=0,vz=0,age=0,ticks=0,
    primed=false,exploded=false}
end
function M.prime(state,fuse,random01)
  fuse=fuse==nil and M.fuse_seconds or fuse
  assert(finite(fuse) and fuse>=0 and fuse<=M.fuse_seconds,'invalid-tnt-fuse')
  local angle=random_unit(random01==nil and 0 or random01)*math.pi*2
  position(state)
  if state.exploded then return false,'tnt-exploded' end
  if state.primed then return false,'already-primed' end
  -- Upstream horizontal impulse is four cm/s, while vertical is 400 cm/s.
  state.vx=-math.sin(angle)*4;state.vy=-math.cos(angle)*4;state.vz=400
  state.age=0;state.ticks=0;state.fuse=fuse;state.primed=true
  return true
end
function M.chain_fuse(random01)return .5+random_unit(random01)*1.5 end
function M.visual(left)
  assert(finite(left),'invalid-tnt-time')
  local pulse=math.max(0,math.min(1,1-(left+.05)/.5))
  local flash=math.floor(math.ceil(math.max(0,left)*20)/5)%2
  return {scale=1+pulse^4*.3,flash=flash,white=flash==0}
end
function M.advance(state,dt,sweep,water_current)
  assert(finite(dt) and dt>=0,'invalid-tnt-delta')
  assert(sweep==nil or type(sweep)=='function','invalid-tnt-sweep')
  local output={exploded=false,steps=0,smoke={}}
  if not state.primed or state.exploded then return output end
  position(state)
  assert(finite(state.age) and state.age>=0 and finite(state.fuse) and state.fuse>=0
    and state.fuse<=M.fuse_seconds,'invalid-tnt-clock')
  assert(type(state.ticks)=='number' and state.ticks>=0 and state.ticks%1==0,'invalid-tnt-ticks')
  for _,axis in ipairs({'vx','vy','vz'})do assert(finite(state[axis]),'invalid-tnt-velocity')end
  -- Clip a long frame at the actual explosion, rather than simulating the
  -- projectile after its fuse has expired. Integer ticks avoid FPS drift.
  local age=math.min(state.fuse,state.age+dt)
  local ticks=math.floor((age+EPS)/M.tick_seconds)
  local x,y,z,vx,vy,vz=state.x,state.y,state.z,state.vx,state.vy,state.vz
  for tick=state.ticks+1,ticks do
    vz=vz-80
    local destination={x=x+vx*M.tick_seconds,y=y+vy*M.tick_seconds,z=z+vz*M.tick_seconds}
    local hit=sweep and sweep({x=x,y=y,z=z},destination,M.sweep_radius) or nil
    if hit then
      position(hit)
      assert(finite(hit.nx) and finite(hit.ny) and finite(hit.nz),'invalid-tnt-normal')
      local norm=math.sqrt(hit.nx^2+hit.ny^2+hit.nz^2)
      assert(norm>EPS,'invalid-tnt-normal')
      local nx,ny,nz=hit.nx/norm,hit.ny/norm,hit.nz/norm
      local intended=destination
      destination={x=hit.x,y=hit.y,z=hit.z}
      if nz>.5 then
        -- A downward sweep from resting TNT can hit the floor at time zero.
        -- Consume the remaining horizontal travel, still sweeping for walls.
        if math.abs(intended.x-hit.x)+math.abs(intended.y-hit.y)>.01 then
          local slide={x=intended.x,y=intended.y,z=hit.z}
          local wall=sweep(destination,slide,M.sweep_radius)
          if wall then position(wall);slide={x=wall.x,y=wall.y,z=wall.z}end
          destination=slide
        end
        vx=vx*.7;vy=vy*.7;vz=vz*-.5
      else
        local dot=vx*nx+vy*ny+vz*nz
        vx=vx-2*dot*nx;vy=vy-2*dot*ny;vz=vz-2*dot*nz
      end
    end
    x,y,z=destination.x,destination.y,destination.z
    vx,vy,vz=vx*.98,vy*.98,vz*.98
    if water_current and tick*M.tick_seconds<state.fuse-EPS then
      local current=water_current(x,y,z,half_height)
      if current then
        local push=flow.impulse(current,'water',{X=vx,Y=vy,Z=vz},false)
        vx,vy,vz=vx+push.X,vy+push.Y,vz+push.Z
      end
    end
    output.smoke[#output.smoke+1]={x=x,y=y,z=z+50}
  end
  -- Commit only after every sweep result has validated. Invalid adapter data
  -- cannot leave half of a physics update in the pure state.
  output.steps=ticks-state.ticks
  state.x,state.y,state.z,state.vx,state.vy,state.vz=x,y,z,vx,vy,vz
  state.age=age;state.ticks=ticks
  output.left=math.max(0,state.fuse-age)
  if output.left<EPS then
    state.age=state.fuse;output.left=0;state.exploded=true;output.exploded=true
  end
  local visual=M.visual(output.left)
  output.scale,output.flash,output.white=visual.scale,visual.flash,visual.white
  return output
end
function M.explosion_origin(state)
  return {x=state.x,y=state.y,z=state.z-half_height+2*half_height*.0625}
end
-- Explosion.collectBlocksAndDamageEntities uses a TNT target's feet for both
-- the direction and the distance. The existing trajectory and fuse survive.
function M.push_primed(state,origin,exposure)
  if state.exploded or not state.primed or exposure<=0 then return false end
  local x,y,z=state.x-origin.x,state.y-origin.y,state.z-half_height-origin.z
  local distance=math.sqrt(x*x+y*y+z*z)
  if distance<EPS or distance>=M.blast_radius then return false end
  local scale=(1-distance/M.blast_radius)*exposure*flow.velocity_scale/distance
  state.vx,state.vy,state.vz=state.vx+x*scale,state.vy+y*scale,state.vz+z*scale
  return true
end
function M.blast(distance,clear)
  distance_valid(distance)
  assert(clear==nil or type(clear)=='boolean','invalid-tnt-visibility')
  if clear==false or distance>M.blast_radius then return nil end
  local exposure=1-distance/M.blast_radius
  -- Native upstream includes the exact radius: minimum coefficient .2 and
  -- zero knockback there. Original terrain is never a destruction target.
  return {exposure=exposure,coefficient=math.max(.2,5*exposure^2),impulse=exposure*2000}
end
function M.knockback(offset,impulse)
  position(offset);assert(finite(impulse) and impulse>=0,'invalid-tnt-impulse')
  local x,y,z=offset.x,offset.y,offset.z+70
  local size=math.sqrt(x*x+y*y+z*z)
  if size<EPS then return {x=0,y=0,z=0} end
  return {x=x/size*impulse,y=y/size*impulse,z=z/size*impulse}
end
function M.block_effect(content_id,distance,already_primed)
  distance_valid(distance)
  local definition=blocks.get(content_id)
  local effect=definition and definition.explosion
  if not effect or distance>=effect.radius then return nil end
  if effect.reaction=='chain' and already_primed then return nil end
  return effect.reaction
end
function M.new_fire(record,lifetime)
  position(record)
  return {x=record.x,y=record.y,z=record.z,age=0,lifetime=lifetime or M.fire_seconds,damage_emitted=0,smoke_emitted=0,expired=false}
end
function M.advance_fire(state,dt)
  assert(finite(dt) and dt>=0,'invalid-fire-delta')
  local output={expired=false,damage_ticks=0,smoke_ticks=0,frame=math.floor(state.age*20)%32}
  if state.expired or dt==0 then return output end
  local lifetime=state.lifetime or M.fire_seconds
  assert(finite(lifetime)and lifetime>0 and lifetime<=60,'invalid-fire-lifetime')
  assert(finite(state.age) and state.age>=0 and state.age<=lifetime,'invalid-fire-age')
  local age=math.min(lifetime,state.age+dt)
  -- Upstream NextDamage starts at zero. Keep its immediate first hit followed
  -- by half-second ticks, without render-frame-dependent drift or an end hit.
  local damage=math.min(math.ceil(lifetime/M.fire_interval),math.floor((age+EPS)/M.fire_interval)+1)
  local smoke=math.min(math.ceil(lifetime/.2)-1,math.floor((age+EPS)/.2))
  -- Lifetime follows actual unpaused game time. A hitch never creates a
  -- catch-up burst of smoke or stacks seconds of damage in one callback.
  output.damage_ticks=math.min(1,damage-state.damage_emitted)
  output.smoke_ticks=math.min(1,smoke-state.smoke_emitted)
  output.frame=math.floor((age+EPS)*20)%32
  state.age=age;state.damage_emitted=damage;state.smoke_emitted=smoke
  if lifetime-age<EPS then state.age=lifetime;state.expired=true;output.expired=true;output.damage_ticks=0;output.smoke_ticks=0 end
  return output
end
function M.fire_damage(distance)
  distance_valid(distance)
  if distance<M.fire_radius then return M.fire_coefficient end
end
return M
