-- Minecraft GustSeedParticle and GustParticle. Each seed emits three stationary
-- animated billboards per wave. Store their birth ticks up front in one batch.
local quads=require('presentation.particle_quads')
local block=require('rules.build_grid').size
local M={interval=1/20}

function M.emit(effect,now,frames,random)
  random=random or math.random
  local out={}
  local ground=effect.ground
  if ground then
    for _=1,math.min(48,20+math.floor(effect.fall*4)) do
      local angle=random()*2*math.pi
      local reach=90*math.sqrt(random())
      local speed=90+random()*140
      out[#out+1]={x=ground.X+reach*math.cos(angle),y=ground.Y+reach*math.sin(angle),z=ground.Z+4,
        vx=math.cos(angle)*speed,vy=math.sin(angle)*speed,vz=100+random()*240,
        size=3+random()*6,tile_x=math.floor(random()*4),tile_y=math.floor(random()*4),
        start=now,life=.25+random()*.25}
    end
  end
  local center=effect.wind
  if center then
    local radius=block*(effect.small and 1 or 3)
    local last_tick=effect.small and 3 or 7
    local spacing=effect.small and 3 or 1
    for tick=0,last_tick,spacing do
      for _=1,3 do
        local life_ticks=12+math.floor(random()*4)
        out[#out+1]={x=center.X+(random()-random())*radius,y=center.Y+(random()-random())*radius,
          -- The final atlas frame is shown at age == lifetime. The next
          -- Minecraft tick removes the sprite.
          z=center.Z+(random()-random())*radius,start=now+tick/20,life=(life_ticks+1)/20,life_ticks=life_ticks}
      end
    end
  end
  return out
end

function M.mesh(particles,now,right,up,origin,frames,b)
  b=b or quads.new(#particles)
  local used=0
  for _,p in ipairs(particles) do
    local age=now-p.start
    if age>=0 and age<p.life then
      used=used+1
      local x,y,z=p.x-origin.X,p.y-origin.Y,p.z-origin.Z
      if p.life_ticks then
        local tick=math.min(p.life_ticks,math.floor(age*20+1e-6))
        local tile=1+(tick*(frames-2))//p.life_ticks
        quads.write(b,used,x,y,z,right,up,block,tile/frames,0,(tile+1)/frames,1)
      else
        x=x+p.vx*age;y=y+p.vy*age;z=z+p.vz*age-460*age*age
        quads.write(b,used,x,y,z,right,up,p.size,p.tile_x/(4*frames),p.tile_y/4,
          (p.tile_x+1)/(4*frames),(p.tile_y+1)/4)
      end
    end
  end
  return quads.finish(b,used)
end
return M
