-- WindChargeItem, WindCharge and AbstractWindCharge (Java 26.3). UE uses cm.
local M={id='pbzmc:wind_charge',speed=3000,radius=240,multiplier=1.22,hit_radius=12.5,
  cooldown_ticks=10,deflect_delay=.25,lifetime=10,limit=24}
function M.advance(p,v,t)
  return {X=p.X+v.X*t,Y=p.Y+v.Y*t,Z=p.Z+v.Z*t}
end
function M.launch(dir,inherited,airborne)
  return {X=dir.X*M.speed+inherited.X,Y=dir.Y*M.speed+inherited.Y,
    Z=dir.Z*M.speed+(airborne and inherited.Z or 0)}
end
-- Distance is measured against the feet/capsule, impulse aims at the eyes.
-- MC explosion radius 1.2 has an entity reach of 2.4 blocks.
function M.impulse(origin,feet,radius,half,reach,multiplier,exposure)
  local x,y,z=feet.X-origin.X,feet.Y-origin.Y,feet.Z-origin.Z
  local edge=math.max(0,math.sqrt(x*x+y*y)-radius)
  local distance=math.sqrt(edge*edge+z*z)
  if distance>=reach or exposure<=0 then return nil end
  z=z+half*1.7
  local length=math.sqrt(x*x+y*y+z*z)
  if length<.001 then return nil end
  local strength=(1-distance/reach)*exposure*multiplier*2000/length
  return {X=x*strength,Y=y*strength,Z=z*strength}
end
-- First contact along the finite attack/arrow segment, including its endcaps.
function M.intercept(start,finish,point,radius)
  local dx,dy,dz=finish.X-start.X,finish.Y-start.Y,finish.Z-start.Z
  local x,y,z=point.X-start.X,point.Y-start.Y,point.Z-start.Z
  local length2=dx*dx+dy*dy+dz*dz
  if length2<.0001 then return x*x+y*y+z*z<=radius*radius and 0 or nil end
  local t=(x*dx+y*dy+z*dz)/length2
  local perpendicular=x*x+y*y+z*z-t*t*length2
  local envelope=radius*radius-perpendicular
  if envelope<0 then return nil end
  local span=math.sqrt(envelope/length2)
  if t+span<0 or t-span>1 then return nil end
  return math.max(0,t-span)
end
return M
