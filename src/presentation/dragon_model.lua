-- The dragon's client meshes are templates. EnderDragonModel places their
-- joints from flight history; the wing on the opposite side is mirrored.
local M={};M.__index=M
local rad,deg=math.rad,math.deg
local function wrap(a)return (a+180)%360-180 end
local function clamp(x,lo,hi)return math.max(lo,math.min(x,hi))end
local neck,tail={},{}
for i=1,5 do neck[i]='neck'..i end
for i=1,12 do tail[i]='tail'..i end

function M.prepare_mesh(parts,units)
 for _,part in ipairs(parts)do
  if part.name=='wing1' or part.name=='wingtip1' then
   -- Reflect the local mesh across model X (UE Y), preserving its skin UVs.
   for i,v in ipairs(part.positions)do v.Y=-v.Y;part.normals[i].Y=-part.normals[i].Y end
   local indices=part.triangles
   for i=1,#indices,3 do indices[i+1],indices[i+2]=indices[i+2],indices[i+1] end
  elseif part.name=='body' then
   -- The Bedrock body template's pivot is 16 pixels above its native joint.
   for _,v in ipairs(part.positions)do v.Z=v.Z+16*units end
  end
 end
end

-- The renderer subtracts the parent's bind pivot. Supply local joint offsets
-- in that basis, also for caches produced before the dragon adapter existed.
local function joint(v,name,x,y,z)
 local p=v.poses[name].position;local origin=v.origins[name]
 p[1],p[2],p[3]=origin[1]+x,origin[2]+y,origin[3]+z
end
local function rotate(v,name,x,y,z)
 local r=v.poses[name].rotation;r[1],r[2],r[3]=x,y,z
end
function M.new(rig)
 local v=setmetatable({rig=rig,poses={},origins={},playing={},frame=0,phase=0,
   heights={},headings={},cursor=0},M)
 for name,bone in pairs(rig)do
  v.origins[name]=rig[bone.parent] and rig[bone.parent].pivot or {0,0,0}
  v.poses[name]={position={0,0,0},rotation={0,0,0},scale={1,1,1},visible=true}
 end
 joint(v,'jaw',0,-4,-8);joint(v,'body',0,-20,8)
 for i,suffix in ipairs({'','1'})do
  local side=i==1 and -1 or 1
  joint(v,'wing'..suffix,side*12,15,-6);joint(v,'wingtip'..suffix,side*56,0,0)
  joint(v,'frontleg'..suffix,side*12,0,-6);joint(v,'frontlegtip'..suffix,0,-20,-1)
  joint(v,'frontfoot'..suffix,0,-23,0)
  joint(v,'rearleg'..suffix,side*16,4,34);joint(v,'rearlegtip'..suffix,0,-32,-4)
  joint(v,'rearfoot'..suffix,0,-31,4)
 end
 return v
end

-- Sample at 20 Hz even when a distant model only gets ten poses per second.
-- Keep shortest-arc headings and reset the trail across teleports/long gaps.
local function history(v,m,now)
 local p=m.position;local yaw=m.yaw or 0;local y=p.Z/100
 local dt=v.at and now-v.at or 0
 local reset=not v.at or dt<0 or dt>.5 or v.teleports~=m.teleports
 if not reset then reset=(p.X-v.x)^2+(p.Y-v.y)^2+(p.Z-v.z)^2>400^2 end
 if reset then
  for i=0,63 do v.heights[i]=y;v.headings[i]=yaw end
  v.next_tick=now+.05;v.alpha=0
 else
  local dz=y-v.z/100;local turn=wrap(yaw-v.yaw)
  while v.next_tick<=now+1e-8 do
   local f=clamp((v.next_tick-v.at)/math.max(dt,1e-8),0,1)
   v.cursor=(v.cursor+1)%64;v.heights[v.cursor]=v.z/100+dz*f
   v.headings[v.cursor]=v.yaw+turn*f;v.next_tick=v.next_tick+.05
  end
  v.alpha=clamp(1-(v.next_tick-now)*20,0,1)
  if dt>0 then
   local horizontal=math.sqrt((p.X-v.x)^2+(p.Y-v.y)^2)/(dt*2000)
   v.phase=(v.phase+dt*4*2^clamp(dz/(dt*20),-4,4)/(1+10*horizontal))%1
  end
 end
 if m.no_ai then v.phase=.5 end
 v.at,v.x,v.y,v.z,v.yaw,v.teleports=now,p.X,p.Y,p.Z,yaw,m.teleports
end
local function sample(v,delay)
 local i=(v.cursor-delay)%64;local j=(i-1)%64
 return v.heights[j]+(v.heights[i]-v.heights[j])*v.alpha,
   v.headings[j]+wrap(v.headings[i]-v.headings[j])*v.alpha
end
local function advance(x,y,z,pitch,yaw)
 local horizontal=10*math.cos(rad(pitch))
 return x-horizontal*math.sin(rad(yaw)),y-10*math.sin(rad(pitch)),z-horizontal*math.cos(rad(yaw))
end
local limbs={'frontleg','frontlegtip','frontfoot','rearleg','rearlegtip','rearfoot'}
local rest={1.3,-.5,.75,1,.5,.75}
function M:update(m,now)
 self.frame=self.frame+1
 history(self,m,now)
 local flap=self.phase*2*math.pi
 local lift=math.sin(flap-1)+1;local bounce=(lift*lift+2*lift)*.05
 local h5,a5=sample(self,5);local h10,a10=sample(self,10)
 local turn=wrap(a5-a10);local centre=a5+turn*.5
 local base_h,base_a=sample(self,6)
 joint(self,'root',0,24+(2-bounce)*16,-32)
 rotate(self,'root',bounce*2-(h5-h10)*10,wrap(a5-self.yaw),0)
 rotate(self,'body',0,0,-turn*1.5)
 rotate(self,'jaw',deg((math.sin(flap)+1)*.2),0,0)
 local wing_x=deg(.125-math.cos(flap)*.2)
 local wing_z=deg((math.sin(flap)+.125)*.8);local tip_z=deg((math.sin(flap+2)+.5)*.75)
 rotate(self,'wing',wing_x,deg(.25),wing_z);rotate(self,'wing1',wing_x,-deg(.25),-wing_z)
 rotate(self,'wingtip',0,0,-tip_z);rotate(self,'wingtip1',0,0,tip_z)
 for i,name in ipairs(limbs)do
  local pitch=deg(rest[i]+(i==2 and -1 or 1)*bounce*.1)
  self.poses[name].rotation[1]=pitch;self.poses[name..'1'].rotation[1]=pitch
 end
 local x,y,z=0,-20,-12
 for i,name in ipairs(neck)do
  local h,a=sample(self,6-i)
  local pitch=deg(math.cos((i-1)*.45+flap)*.15)+(h-base_h)*7.5
  local yaw=wrap(a-base_a)*1.5
  joint(self,name,x,y,z);rotate(self,name,pitch,yaw,-wrap(a-centre)*1.5)
  x,y,z=advance(x,y,z,pitch,yaw)
 end
 local _,head_a=sample(self,0)
 joint(self,'head',x,y,z);rotate(self,'head',0,wrap(head_a-base_a),-wrap(head_a-centre))
 x,y,z=0,-10,60;base_h,base_a=sample(self,11)
 local wave=0
 for i,name in ipairs(tail)do
  local h,a=sample(self,11+i);wave=wave+deg(math.sin((i-1)*.45+flap)*.05)
  local pitch=wave+(h-base_h)*7.5;local yaw=180+wrap(a-base_a)*1.5
  joint(self,name,x,y,z);rotate(self,name,pitch,yaw,wrap(a-centre)*1.5)
  x,y,z=advance(x,y,z,pitch,yaw)
 end
 return self.poses
end
return M
