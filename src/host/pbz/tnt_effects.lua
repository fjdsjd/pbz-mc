-- Pinned MinecraftParticles smoke / eight-tick huge-explosion emitter.
-- One atlas, one mesh submission; bounded visual particles, never damage.
local M={};M.__index=M
local function linear(x)return x<=.04045 and x/12.92 or ((x+.055)/1.055)^2.4 end
function M.new(world)
 return setmetatable({world=world,particles={},emitters={},now=0,draw_at=0},M)
end
function M:add(p)
 if #self.particles>=384 then table.remove(self.particles,1)end
 p.start=self.now;self.particles[#self.particles+1]=p
end
function M:smoke(point)
 local x,y,z=math.random()*2-1,math.random()*2-1,math.random()*2-1
 local speed=12*(math.random()+math.random()+1)/math.max(1e-5,math.sqrt(x*x+y*y+z*z))
 self:add({kind='smoke',x=point.x,y=point.y,z=point.z,vx=x*speed,vy=y*speed,vz=z*speed+20,
  shade=math.random()*.3,life=math.floor(8/(math.random()*.8+.2))*.05,size=30*(math.random()*.5+.5),ticks=0})
end
function M:explosion(point)
 if #self.emitters>=16 then table.remove(self.emitters,1)end
 self.emitters[#self.emitters+1]={x=point.x,y=point.y,z=point.z,start=self.now,ticks=0}
end
function M:tick(dt)
 if self.handle and not self.world:valid(self.handle)then self.world:destroy(self.handle);self.handle=nil;self.hidden=nil end
 self.now=self.now+dt
 for i=#self.emitters,1,-1 do
  local e=self.emitters[i]
  while e.ticks<8 and e.ticks*.05<=self.now-e.start do
   for _=1,6 do
    self:add({kind='explosion',x=e.x+(math.random()-math.random())*400,y=e.y+(math.random()-math.random())*400,
     z=e.z+(math.random()-math.random())*400,life=(6+math.random(0,3))*.05,size=400*(1-e.ticks/16),shade=.4+math.random()*.6})
   end
   e.ticks=e.ticks+1
  end
  if e.ticks>=8 then table.remove(self.emitters,i)end
 end
 for i=#self.particles,1,-1 do
  local p=self.particles[i];local age=self.now-p.start
  if age>=p.life then table.remove(self.particles,i)
  elseif p.kind=='smoke'then
   local ticks=math.floor(age*20)
   for _=p.ticks+1,ticks do
    p.vz=p.vz+8;p.x=p.x+p.vx*.05;p.y=p.y+p.vy*.05;p.z=p.z+p.vz*.05
    p.vx=p.vx*.96;p.vy=p.vy*.96;p.vz=p.vz*.96
   end
   p.ticks=ticks
  end
 end
 if #self.particles==0 then
  if self.handle and not self.hidden then self.handle.mesh:ClearAllMeshSections();self.hidden=true end
  return
 end
 if self.now<self.draw_at then return end;self.draw_at=self.now+1/30
 if not self.handle then
  self.handle=self.world:spawn('particles',{x=0,y=0,z=0});self.asset=self.world.assets:particles()
 end
 local origin=self.world.binding.actor:K2_GetActorLocation()
 local pc=require('UEHelpers').GetPlayerController()
 local _,right,up=require('presentation.native_steve_pose').axes(pc.PlayerCameraManager.CameraCachePrivate.POV.Rotation)
 self.handle.actor:K2_SetActorLocation(origin,false,{},true)
 local part={positions={},normals={},uv={},colors={},triangles={}}
 for _,p in ipairs(self.particles)do
  local age=self.now-p.start;local f=age/p.life
  local index=p.kind=='explosion' and math.min(15,math.floor(math.floor(age*20)*16/(p.life*20+1))) or math.min(7,math.floor(f*8))
  local sprite=self.asset.sprites[self.asset.animations[p.kind][index+1]];local uv=sprite.atlas_uv
  local size=p.size*(p.kind=='smoke' and math.min(1,f*32)or 1)*.5
  local color={R=linear(p.shade),G=linear(p.shade),B=linear(p.shade),A=1};local base=#part.positions
  for _,c in ipairs({{-1,-1,0,1},{1,-1,1,1},{1,1,1,0},{-1,1,0,0}})do
   part.positions[#part.positions+1]={X=p.x-origin.X+(right.X*c[1]+up.X*c[2])*size,
    Y=p.y-origin.Y+(right.Y*c[1]+up.Y*c[2])*size,Z=p.z-origin.Z+(right.Z*c[1]+up.Z*c[2])*size}
   part.normals[#part.normals+1]={X=0,Y=0,Z=1};part.colors[#part.colors+1]=color
   part.uv[#part.uv+1]={X=uv[1]+(uv[3]-uv[1])*c[3],Y=uv[2]+(uv[4]-uv[2])*c[4]}
  end
  for _,n in ipairs({0,1,2,0,2,3,2,1,0,3,2,0})do part.triangles[#part.triangles+1]=base+n end
 end
 require('host.pbz.mesh_bundle').apply(self.handle.mesh,part);self.hidden=false
end
return M
