-- MC 1.21.1: 20-tick item cooldown; 1.5 blocks/tick, .99 drag, .03 gravity.
-- PBZ user overrides: no consumption/damage, invisible barriers ignored,
-- contact with any surface may teleport; a supporting floor is not required.
local M={id='pbzmc:ender_pearl',cooldown=20,speed=3000,radius=12.5,lifetime=20,max_projectiles=24}
function M.advance(p,dt,trace)
  local remaining=dt
  while remaining>1e-8 do
    local step=math.min(remaining,.05-p.accumulator,.0125)
    local finish={X=p.position.X+p.velocity.X*step,Y=p.position.Y+p.velocity.Y*step,Z=p.position.Z+p.velocity.Z*step}
    local hit,result=trace(p.position,finish,M.radius)
    if hit then return result end
    p.position=finish;p.accumulator=p.accumulator+step;remaining=remaining-step
    if p.accumulator>=.05-1e-8 then
      p.accumulator=0;p.velocity={X=p.velocity.X*.99,Y=p.velocity.Y*.99,Z=p.velocity.Z*.99-60}
    end
  end
end
function M.landing(hit,radius,half,ground,occupied)
  local point,normal=hit.ImpactPoint,hit.ImpactNormal
  local length=math.sqrt(normal.X^2+normal.Y^2+normal.Z^2)
  if length<1e-6 then return nil,'invalid-contact-normal' end
  local n={X=normal.X/length,Y=normal.Y/length,Z=normal.Z/length}
  -- Upright capsule support against the contact plane, including side walls
  -- and ceilings. No walkable-normal or ground-ray requirement rejects steps.
  local distance=radius+(half-radius)*math.abs(n.Z)+3
  for _,padding in ipairs({0,8,24,48})do
    for _,lift in ipairs({0,8,16,32,48,64,96})do
      local p={X=point.X+n.X*(distance+padding),Y=point.Y+n.Y*(distance+padding),
        Z=point.Z+n.Z*(distance+padding)+(n.Z<-.5 and -lift or lift)}
      if not occupied(p,radius,half)then return p end
    end
  end
  return nil,'occupied-landing'
end
return M
