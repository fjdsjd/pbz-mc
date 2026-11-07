-- Forward speed, gravity, impact radius and range use PBZ centimetres.
local M={}
local contact={melee=82,pounce=140,ram=165,sting=65,puff=105,tongue=270,heat=65}
local ranged={
  arrow={speed=2200,gravity=300},trident={speed=2000,gravity=300},skull={speed=850},
  flame={speed=1350},fireball={speed=850,splash=270},dragon_breath={speed=900,splash=300},
  gust={speed=1250,splash=235,impulse=650},spit={speed=1400,gravity=320},
  bullet={speed=620,homing=true},snowball={speed=1500,gravity=440},
  potion={speed=900,gravity=590,splash=275},
  fang={delay=.38,radius=130},beam={delay=.8},sonic={delay=.48}
}
function M.contact(kind) return contact[kind]~=nil end
function M.projectile(kind) return ranged[kind] end
-- Solve the low arc. Using horizontal distance / speed alone undershoots a
-- potion at the far end of its range, even against a stationary target.
local function travel(dx,dy,dz,speed,gravity)
  local r2=dx*dx+dy*dy+dz*dz
  local term=speed*speed-gravity*dz
  local discr=term*term-gravity*gravity*r2
  if term<=0 or discr<0 then return nil end
  return math.sqrt(2*r2/(term+math.sqrt(discr)))
end
function M.launch(a,b,motion,speed,gravity)
  local x,y,z=b.X-a.X,b.Y-a.Y,b.Z-a.Z
  local dx,dy,dz=x,y,z
  local time=travel(x,y,z,speed,gravity)
  if not time or time<.001 then return nil end
  if motion.X~=0 or motion.Y~=0 or motion.Z~=0 then
    for _=1,2 do
      dx,dy,dz=x+motion.X*time,y+motion.Y*time,z+motion.Z*time
      time=travel(dx,dy,dz,speed,gravity)
      if not time or time<.001 then return nil end
    end
  end
  return {X=dx/time,Y=dy/time,Z=dz/time+.5*gravity*time}
end
function M.reach(kind,own_radius,target_radius)
  if kind=='creeper' then return 250 end
  if contact[kind] then return own_radius+target_radius+contact[kind] end
  return kind=='sonic' and 1500 or 1150
end
-- Start at 2.5 blocks, continue up to six blocks while visible. A manually
-- lit creeper keeps its fuse even when its target leaves.
function M.fuse(progress,dt,range,visible,lit)
  local growing=lit or visible and range and range<=(progress>0 and 600 or 250)
  return math.max(0,math.min(1.5,progress+(growing and dt or -dt)))
end
return M
