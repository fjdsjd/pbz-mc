-- Minecraft spawner timing in seconds and distances in centimetres (one block = 100).
local M={initial=1,activation=1600,attempts=4,nearby_limit=6}
function M.delay(random) return random(200,799)/20 end
function M.distance(block,player)
  return (block.x-player.X)^2+(block.y-player.Y)^2+(block.z-player.Z)^2
end
function M.sample(block,random)
  return {X=block.x+(random()-random())*400,Y=block.y+(random()-random())*400,
    Z=block.z-50+random(-1,1)*100}
end
function M.nearby(block,def,mobs)
  local count=0
  for _,mob in ipairs(mobs) do
    if mob.def==def then
      local p=mob.position
      if math.abs(p.X-block.x)<450+def.radius and math.abs(p.Y-block.y)<450+def.radius
          and math.abs(p.Z-block.z)<450+def.height/2 then count=count+1 end
    end
  end
  return count
end
return M
