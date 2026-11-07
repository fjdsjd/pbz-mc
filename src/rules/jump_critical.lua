-- MC 1.21.1 PlayerEntity.attack; host reports movement/status observations.
local M={}
function M.allowed(s)
  return s.strength>.9 and s.fall_distance>0 and not s.grounded and not s.climbing
    and not s.water and not s.blind and not s.riding and not s.sprinting and s.living==true
end
function M.fall(previous,z,falling,vertical_speed,elapsed)
  local distance=0
  if falling and vertical_speed<0 and previous and previous.falling then
    local delta=previous.z-z
    -- A discontinuous developer teleport/scene replacement is not a falling hit.
    local limit=250
    if elapsed then
      local speed=math.max(math.abs(previous.vz or 0),math.abs(vertical_speed))
      limit=math.max(limit,speed*math.min(1,math.max(0,elapsed))+30)
    end
    if delta>=0 and delta<limit then distance=(previous.distance or 0)+delta end
  end
  return {z=z,falling=falling,distance=distance,vz=vertical_speed}
end
return M
