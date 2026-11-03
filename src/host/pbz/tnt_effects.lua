-- Pinned MinecraftParticles smoke / eight-tick huge-explosion emitter.
-- One atlas, one mesh submission; bounded visual particles, never damage.
local M={};M.__index=M
local function linear(x)return x<=.04045 and x/12.92 or ((x+.055)/1.055)^2.4 end
local corners={{-1,-1,0,1},{1,-1,1,1},{1,1,1,0},{-1,1,0,0}}
local indices={0,1,2,0,2,3,2,1,0,3,2,0}
local normal={X=0,Y=0,Z=1}
function M.new(world)
 return setmetatable({world=world,particles={},emitters={},now=0,draw_at=0},M)
end
function M:add(p)
 local shade=linear(p.shade);p.color={R=shade,G=shade,B=shade,A=1}
 p.start=self.now
 if #self.particles>=384 then
  self.replace=(self.replace or 0)%384+1;self.particles[self.replace]=p
 else self.particles[#self.particles+1]=p end
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
 if #self.emitters==0 and #self.particles==0 and (not self.handle or self.hidden)then return end
 if self.handle and not self.world:valid(self.handle)then self.world:destroy(self.handle);self.handle=nil;self.hidden=nil end
 self.now=self.now+dt
 local sprites=math.max(2,math.min(6,math.floor(24/math.max(1,#self.emitters))))
 for i=#self.emitters,1,-1 do
  local e=self.emitters[i]
  while e.ticks<8 and e.ticks*.05<=self.now-e.start do
   for _=1,sprites do
    self:add({kind='explosion',x=e.x+(math.random()-math.random())*400,y=e.y+(math.random()-math.random())*400,
     z=e.z+(math.random()-math.random())*400,life=(6+math.random(0,3))*.05,size=400*(1-e.ticks/16),shade=.4+math.random()*.6})
   end
   e.ticks=e.ticks+1
  end
  if e.ticks>=8 then table.remove(self.emitters,i)end
 end
 local alive=0
 for i=1,#self.particles do
  local p=self.particles[i];local age=self.now-p.start
  if age<p.life then
   alive=alive+1;self.particles[alive]=p
   if p.kind=='smoke'then
   local ticks=math.floor(age*20)
   for _=p.ticks+1,ticks do
    p.vz=p.vz+8;p.x=p.x+p.vx*.05;p.y=p.y+p.vy*.05;p.z=p.z+p.vz*.05
    p.vx=p.vx*.96;p.vy=p.vy*.96;p.vz=p.vz*.96
   end
   p.ticks=ticks
   end
  end
 end
 for i=#self.particles,alive+1,-1 do self.particles[i]=nil end
 if #self.particles==0 then
  if self.handle and not self.hidden then self.handle.mesh:ClearAllMeshSections();self.hidden=true end
  return
 end
 if self.now+1e-8<self.draw_at then return end;self.draw_at=self.now+.05
 if not self.handle then
  self.handle=self.world:spawn('particles',{x=0,y=0,z=0});self.asset=self.world.assets:particles()
 end
 local origin=self.world.binding.actor:K2_GetActorLocation()
 local pc=require('host.pbz.local_player').controller()
 local _,right,up=require('presentation.native_steve_pose').axes(pc.PlayerCameraManager.CameraCachePrivate.POV.Rotation)
 self.handle.actor:K2_SetActorLocation(origin,false,{},true)
 local part=self.part or {positions={},normals={},uv={},colors={},triangles={}};self.part=part
 for i,p in ipairs(self.particles)do
  local age=self.now-p.start;local f=age/p.life
  local index=p.kind=='explosion' and math.min(15,math.floor(math.floor(age*20)*16/(p.life*20+1))) or math.min(7,math.floor(f*8))
  local sprite=self.asset.sprites[self.asset.animations[p.kind][index+1]];local uv=sprite.atlas_uv
  local size=p.size*(p.kind=='smoke' and math.min(1,f*32)or 1)*.5
  local base=(i-1)*4
  for k,c in ipairs(corners)do
   local j=base+k;local pos=part.positions[j] or {};part.positions[j]=pos
   pos.X=p.x-origin.X+(right.X*c[1]+up.X*c[2])*size
   pos.Y=p.y-origin.Y+(right.Y*c[1]+up.Y*c[2])*size
   pos.Z=p.z-origin.Z+(right.Z*c[1]+up.Z*c[2])*size
   part.normals[j]=normal;part.colors[j]=p.color
   local t=part.uv[j] or {};part.uv[j]=t
   t.X=uv[1]+(uv[3]-uv[1])*c[3];t.Y=uv[2]+(uv[4]-uv[2])*c[4]
  end
  if not part.triangles[i*12]then
   for k,n in ipairs(indices)do part.triangles[(i-1)*12+k]=base+n end
  end
 end
 for j=#part.positions,alive*4+1,-1 do
  part.positions[j]=nil;part.normals[j]=nil;part.uv[j]=nil;part.colors[j]=nil
 end
 for j=#part.triangles,alive*12+1,-1 do part.triangles[j]=nil end
 require('host.pbz.mesh_bundle').apply(self.handle.mesh,part);self.hidden=false
end
return M
