-- MC 1.21.1 EmitterParticle/DamageParticle, converted to UE centimetres/seconds.
local M={}
local function linear(v) return v<=.04045 and v/12.92 or ((v+.055)/1.055)^2.4 end
function M.emit(center,width,height,random)
  local out={};random=random or math.random
  for _=1,16 do
    local x,y,z=random()*2-1,random()*2-1,random()*2-1
    if x*x+y*y+z*z<=1 then
      local a,b,c=random()*2-1,random()*2-1,random()*2-1
      local length=math.sqrt(a*a+b*b+c*c);local jitter=12*(random()+random()+1)/math.max(length,1e-6)
      local shade=random()*.3+.6
      local p={x=center.X+x*width/4,y=center.Y+y*width/4,z=center.Z+z*height/4,
        vx=x*800+a*jitter,vy=y*800+b*jitter,vz=(z+.2)*800+c*jitter+20,
        half_size=15*(random()*.5+.5),ticks=0,max_ticks=math.max(1,math.floor(6/(random()*.8+.6))),
        r=shade,g=shade,b=shade}
      M.tick(p);out[#out+1]=p
    end
  end
  return out
end
function M.tick(p)
  p.ticks=p.ticks+1;p.vz=p.vz-40
  p.x=p.x+p.vx*.05;p.y=p.y+p.vy*.05;p.z=p.z+p.vz*.05
  p.vx=p.vx*.7;p.vy=p.vy*.7;p.vz=p.vz*.7;p.g=p.g*.96;p.b=p.b*.9
end
function M.mesh(particles,right,up,origin)
  local p={positions={},normals={},uv={},colors={},triangles={}}
  for _,particle in ipairs(particles) do
    local size=particle.half_size
    local color={R=linear(particle.r),G=linear(particle.g),B=linear(particle.b),A=1}
    local base=#p.positions
    -- One masked billboard samples the exact original 8x8 sprite.
    for _,corner in ipairs({{-1,-1,0,1},{1,-1,1,1},{1,1,1,0},{-1,1,0,0}}) do
      p.positions[#p.positions+1]={X=particle.x-origin.X+right.X*corner[1]*size+up.X*corner[2]*size,
        Y=particle.y-origin.Y+right.Y*corner[1]*size+up.Y*corner[2]*size,
        Z=particle.z-origin.Z+right.Z*corner[1]*size+up.Z*corner[2]*size}
      p.normals[#p.normals+1]={X=0,Y=0,Z=1};p.uv[#p.uv+1]={X=corner[3],Y=corner[4]};p.colors[#p.colors+1]=color
    end
    for _,i in ipairs({0,1,2,0,2,3,2,1,0,3,2,0}) do p.triangles[#p.triangles+1]=base+i end
  end
  return p
end
return M
