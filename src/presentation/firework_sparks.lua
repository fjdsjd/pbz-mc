-- MC 1.21.1 FireworkRocketEntity trail + FireworksSparkParticle.Explosion,
-- AnimatedParticle and SpriteBillboardParticle. Positions: UE centimetres;
-- velocities here: cm per 20 Hz tick. Visual particles never trace or damage.
local M={max_particles=128,tick_seconds=.05}
local function gaussian(random)
  return math.sqrt(-2*math.log(math.max(1e-12,random())))*math.cos(2*math.pi*random())
end
function M.emit(position,velocity,random)
  random=random or math.random
  return {x=position.X,y=position.Y,z=position.Z,vx=gaussian(random)*5,vy=gaussian(random)*5,
    vz=-(velocity and velocity.Z or 0)*.025,age=0,max_age=48+math.min(11,math.floor(random()*12)),
    size=15+random()*15,alpha=.99}
end
function M.tick(p)
  local expired=p.age>=p.max_age
  p.age=p.age+1
  if expired then return false end
  p.vz=p.vz-.4;p.x=p.x+p.vx;p.y=p.y+p.vy;p.z=p.z+p.vz
  p.vx=p.vx*.91;p.vy=p.vy*.91;p.vz=p.vz*.91
  if p.age>math.floor(p.max_age/2)then p.alpha=1-(p.age-math.floor(p.max_age/2))/p.max_age end
  return true
end
function M.mesh(particles,right,up,origin,atlas)
  local part={positions={},normals={},uv={},colors={},triangles={}}
  local color={R=1,G=1,B=1,A=1}
  local normal={X=right.Y*up.Z-right.Z*up.Y,Y=right.Z*up.X-right.X*up.Z,Z=right.X*up.Y-right.Y*up.X}
  for i=1,M.max_particles do
    local p=particles[i]
    -- ParticleManager.SimpleSpriteProvider: age * (frameCount - 1) / maxAge.
    local frame=p and math.min(7,math.floor(p.age*7/p.max_age))or 0
    local row=p and math.max(0,math.min(atlas.opacity_rows-1,math.floor((1-p.alpha/.99)*(atlas.opacity_rows-1)+.5)))or atlas.opacity_rows-1
    local half=p and p.size*.5 or 0
    local x,y,z=p and p.x-origin.X or 0,p and p.y-origin.Y or 0,p and p.z-origin.Z or 0
    for _,corner in ipairs({{-1,-1,0,1},{1,-1,1,1},{1,1,1,0},{-1,1,0,0}})do
      part.positions[#part.positions+1]={X=x+(right.X*corner[1]+up.X*corner[2])*half,
        Y=y+(right.Y*corner[1]+up.Y*corner[2])*half,Z=z+(right.Z*corner[1]+up.Z*corner[2])*half}
      part.normals[#part.normals+1]=normal;part.colors[#part.colors+1]=color
      -- Sample only between the first/last texel centres of this original
      -- 8x8 cell; never hit the neighbouring frame or opacity row boundary.
      part.uv[#part.uv+1]={X=(frame+(corner[3]*7+.5)/8)/atlas.columns,
        Y=(row+(corner[4]*7+.5)/8)/atlas.opacity_rows}
    end
    for _,index in ipairs({0,1,2,0,2,3,2,1,0,3,2,0})do part.triangles[#part.triangles+1]=(i-1)*4+index end
  end
  return part
end
return M
