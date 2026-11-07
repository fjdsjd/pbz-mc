local quads=require('presentation.particle_quads')
local M={}
local function linear(x)return x<=.04045 and x/12.92 or ((x+.055)/1.055)^2.4 end
function M.emit(center,now,frames,random)
  random=random or math.random
  local out={}
  local function gaussian()
    return math.sqrt(-2*math.log(math.max(1e-9,random())))*math.cos(2*math.pi*random())
  end
  for _=1,32 do
    local shade=random()*.6+.4
    out[#out+1]={x=center.X,y=center.Y,z=center.Z+random()*200,vx=gaussian()*100,vy=gaussian()*100,
      start=now,life=(40+math.floor(random()*10))/20,size=10*(random()*.2+.5),
      color={R=linear(shade*.9),G=linear(shade*.3),B=linear(shade),A=1},
      frame=math.min(frames-1,math.floor(random()*frames))}
  end
  return out
end
function M.mesh(particles,now,right,up,origin,frames,part)
  part=part or quads.new(#particles)
  for i,p in ipairs(particles) do
    local f=math.max(0,math.min(1,(now-p.start)/p.life));local trajectory=1+f-2*f*f
    local size=p.size*(1-(1-f)^2);local x,y,z=p.x+p.vx*trajectory,p.y+p.vy*trajectory,p.z+100*(1-f)
    quads.write(part,i,x-origin.X,y-origin.Y,z-origin.Z,right,up,size,p.frame/frames,0,(p.frame+1)/frames,1,p.color)
  end
  return quads.finish(part,#particles)
end
return M
