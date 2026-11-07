-- One original-atlas batch per binding for potion, entity and player effects.
-- Cosmetic budgets never change the separately scheduled gameplay effects.
local valid=require('host.pbz.appearance').valid
local identity=require('host.pbz.object_identity')
local bundle=require('host.pbz.mesh_bundle')
local quads=require('presentation.particle_quads')
local axes=require('presentation.native_steve_pose').axes
local rules=require('rules.status_effects')
local M={};M.__index=M
local ambient_limit,total_limit=128,384
local empty,zero={}, {Pitch=0,Yaw=0,Roll=0}
local empty_status=rules.empty()
local transform={Rotation={X=0,Y=0,Z=0,W=1},Translation={X=0,Y=0,Z=0},Scale3D={X=1,Y=1,Z=1}}
local function linear(v)return v<=.04045 and v/12.92 or ((v+.055)/1.055)^2.4 end
function M.new(binding,pc)
 return setmetatable({binding=binding,pc=pc,particles={},free={},users={},accumulator=0,emitter=0,
  spawned=0,peak=0,ambient=0,buffers={},visible_particles={},generation=0,
  report={sections=0,updates=0,culled=0,dropped=0,renders=0,render_ms=0,peak_ms=0,update_ms=0,update_peak_ms=0}},M)
end
function M.acquire(binding,pc,owner,player)
 local batch=binding.mc_status_particles
 if not batch or batch.closed then batch=M.new(binding,pc);binding.mc_status_particles=batch end
 batch.users[owner]=true
 if player then batch.player_owner=owner end
 return batch
end
function M:release(owner)
 self.users[owner]=nil
 if self.player_owner==owner then self.player_owner=nil end
 if not next(self.users)then self:close()end
end
function M:prepare()
 if self.mesh then return end
 local root=self.binding.item_models_root..'/../effects/'
 local f=assert(io.open(root..'status_particles.json','rb'));local spec=assert(require('dkjson').decode(f:read('a')));f:close()
 f=assert(io.open(root..'status_particles.png','rb'));local raw=f:read('a');f:close()
 assert(require('storage.sha256')(raw)==spec.sha256,'status-particle-digest')
 self.actor=self.binding.actor:GetWorld():SpawnActor(StaticFindObject('/Script/Engine.Actor'),{X=0,Y=0,Z=0},zero)
 self.actor_id=identity.capture(self.actor)
 self.mesh=self.actor:AddComponentByClass(StaticFindObject('/Script/ProceduralMeshComponent.ProceduralMeshComponent'),true,transform,false)
 self.mesh:SetCollisionEnabled(0);self.mesh:SetCastShadow(false)
 self.texture=StaticFindObject('/Script/Engine.KismetRenderingLibrary:ImportFileAsTexture2D')(
  StaticFindObject('/Script/Engine.Default__KismetRenderingLibrary'),self.actor,root..'status_particles.png')
 assert(valid(self.texture),'status-particle-texture');require('host.pbz.pixel_texture').configure(self.texture)
 self.material=StaticFindObject('/Script/Engine.Default__KismetMaterialLibrary'):CreateDynamicMaterialInstance(
  self.actor,StaticFindObject('/Paper2D/MaskedUnlitSpriteMaterial.MaskedUnlitSpriteMaterial'),FName('PBZMC_StatusParticles'),1)
 self.material:SetTextureParameterValue(FName('SpriteTexture'),self.texture);self.mesh:SetMaterial(0,self.material)
 self.mesh:SetHiddenInGame(true,false)
end
function M:activate(t)
 self.emitter=30
 -- The activation item remains centered in the HUD, separate from this batch.
end
function M:reserve(kind)
 if #self.particles>=total_limit or kind==0 and self.ambient>=ambient_limit then
  self.report.dropped=self.report.dropped+1;return nil
 end
 local p=table.remove(self.free)or {color={R=0,G=0,B=0,A=1}}
 p.kind=kind;p.age=0
 p.render_slot=nil;p.render_frame=nil;self.colors_dirty=true
 self.particles[#self.particles+1]=p
 if kind==0 then self.ambient=self.ambient+1 end
 self.spawned=self.spawned+1;self.peak=math.max(self.peak,#self.particles)
 self.generation=self.generation+1
 return p
end
local function color(p,r,g,b)
 p.color.R=linear(r);p.color.G=linear(g);p.color.B=linear(b)
end
function M:emit(kind,tint,origin,width,height)
 local x,y,z=math.random()*2-1,math.random()*2-1,math.random()*2-1
 if kind==1 and x*x+y*y+z*z>1 then return end
 local p=self:reserve(kind);if not p then return end
 p.x=origin.X+x*width/4;p.y=origin.Y+y*width/4;p.z=origin.Z+z*height/2
 p.vx=kind==1 and x*800 or (math.random()-.5)*20
 p.vy=kind==1 and y*800 or (math.random()-.5)*20;p.vz=kind==1 and (z+.2)*800 or 4
 p.max=kind==1 and 60+math.random(0,11)or math.floor(8/(math.random()*.8+.2))
 p.half_size=11.25*(math.random()*.5+.5)
 if kind==1 then
  if math.random(4)==1 then color(p,.6+math.random()*.2,.6+math.random()*.3,math.random()*.2)
  else color(p,.1+math.random()*.2,.4+math.random()*.3,math.random()*.2)end
 else color(p,((tint>>16)&255)/255,((tint>>8)&255)/255,(tint&255)/255)end
end
function M:emit_at(tint,point,width,height)
 if not self.eye or self.eye_at~=self.last then
  local p=self.pc.PlayerCameraManager.CameraCachePrivate.POV.Location
  self.eye=self.eye or {};self.eye.X,self.eye.Y,self.eye.Z=p.X,p.Y,p.Z;self.eye_at=self.last
 end
 local eye=self.eye
 if eye and (point.X-eye.X)^2+(point.Y-eye.Y)^2+(point.Z-eye.Z)^2>3000^2 then
  self.report.culled=self.report.culled+1;return false
 end
 local p=self:reserve(0);if not p then return false end
 p.x=point.X+(math.random()-.5)*width;p.y=point.Y+(math.random()-.5)*width;p.z=point.Z+(math.random()-.5)*height
 p.vx=0;p.vy=0;p.vz=4;p.max=20+math.random(20);p.half_size=6
 color(p,((tint>>16)&255)/255,((tint>>8)&255)/255,(tint&255)/255)
 return true
end
function M:physics(value,emit)
 self.generation=self.generation+1
 -- In-place compaction, without shifting the array on every expiry.
 local count=0;local list=self.particles
 for i=1,#list do
  local p=list[i];p.age=p.age+1
  if p.age>=p.max then
   self.colors_dirty=true
   if p.kind==0 then self.ambient=self.ambient-1 end
   self.free[#self.free+1]=p
  else
   p.vz=p.vz+(p.kind==1 and -5 or 8)
   p.x=p.x+p.vx*.05;p.y=p.y+p.vy*.05;p.z=p.z+p.vz*.05
   local friction=p.kind==1 and .6 or .96;p.vx=p.vx*friction;p.vy=p.vy*friction;p.vz=p.vz*friction
   count=count+1;list[count]=p
  end
 end
 for i=#list,count+1,-1 do list[i]=nil end
 -- Age particles after a stall without emitting five old frames at once.
 if not emit then return end
 local effect
 if math.random(4)==1 then effect=rules.particle_color(value)end
 if self.emitter>0 or effect then
  local origin=self.binding.actor:K2_GetActorLocation();local capsule=self.binding.actor.CapsuleComponent
  local width,height=capsule:GetScaledCapsuleRadius()*2,capsule:GetScaledCapsuleHalfHeight()*2
  if self.emitter>0 then for _=1,16 do self:emit(1,nil,origin,width,height)end;self.emitter=self.emitter-1 end
  if effect then self:emit(0,effect,origin,width,height)end
 end
end
function M:render(pov,t)
 local began=os.clock()
 local forward,right,up=axes(pov.Rotation)
 -- Allocate/upload for visible sprites, not the largest past burst. Reuse a
 -- small set of size classes; shrink only after sustained low occupancy.
 local count=0;local visible_particles=self.visible_particles
 for _,p in ipairs(self.particles)do
  local dx,dy,dz=p.x-pov.Location.X,p.y-pov.Location.Y,p.z-pov.Location.Z
  if dx*dx+dy*dy+dz*dz<=3000^2 and dx*forward.X+dy*forward.Y+dz*forward.Z>=-100 then
   count=count+1;visible_particles[count]=p
  end
 end
 for i=#visible_particles,count+1,-1 do visible_particles[i]=nil end
 self.report.visible=count
 if count==0 then
  if self.visible then self.mesh:SetHiddenInGame(true,false);self.visible=false end
  return
 end
 self:prepare()
 local capacity=self.buffer and self.buffer.capacity or 16
 while capacity<count do capacity=math.min(total_limit,capacity*2)end
 if count<=capacity/4 and capacity>16 then
  self.low_since=self.low_since or t
  if t-self.low_since>=.25 then capacity=16;while capacity<count do capacity=capacity*2 end;self.low_since=nil end
 else self.low_since=nil end
 local resize=not self.buffer or self.buffer.capacity~=capacity
 if resize then
  self.buffer=self.buffers[capacity]or quads.new(capacity);self.buffers[capacity]=self.buffer
  self.buffer.owners=self.buffer.owners or {}
 end
 local origin=self.origin
 if not origin or (pov.Location.X-origin.X)^2+(pov.Location.Y-origin.Y)^2+(pov.Location.Z-origin.Z)^2>2000^2 then
  origin={X=pov.Location.X,Y=pov.Location.Y,Z=pov.Location.Z};self.origin=origin
  self.mesh:K2_SetWorldLocationAndRotation(origin,zero,false,{},true)
 end
 local uv_dirty=resize;local colors_dirty=resize or self.colors_dirty
 for i=1,count do
  local p=visible_particles[i];local frame=math.min(7,math.floor(p.age*8/(p.max+1)))
  if self.buffer.owners[i]~=p or p.render_slot~=i then colors_dirty=true;uv_dirty=true elseif p.render_frame~=frame then uv_dirty=true end
  self.buffer.owners[i]=p
  p.render_slot=i;p.render_frame=frame
  quads.write(self.buffer,i,p.x-origin.X,p.y-origin.Y,p.z-origin.Z,right,up,p.half_size,frame/8,p.kind/2,(frame+1)/8,(p.kind+1)/2,p.color)
 end
 local part=quads.finish(self.buffer,count)
 if resize then bundle.apply(self.mesh,part);self.report.sections=self.report.sections+1
 else
  -- The unlit billboard normal never changes. Empty optional channels leave
  -- the section's normals/tangents untouched and avoid Lua/native conversion.
  self.mesh:UpdateMeshSection_LinearColor(0,part.positions,empty,uv_dirty and part.uv or empty,empty,empty,empty,colors_dirty and part.colors or empty,empty,false)
  self.report.updates=self.report.updates+1
 end
 local visible=count>0
 if self.visible~=visible then self.mesh:SetHiddenInGame(not visible,false);self.visible=visible end
 local elapsed=(os.clock()-began)*1000
 self.report.renders=self.report.renders+1;self.report.render_ms=self.report.render_ms+elapsed
 self.report.peak_ms=math.max(self.report.peak_ms,elapsed);self.report.capacity=part.capacity
 if not resize then
  self.report.update_ms=self.report.update_ms+elapsed;self.report.update_peak_ms=math.max(self.report.update_peak_ms,elapsed)
 end
 self.render_generation=self.generation
 self.colors_dirty=false
 self.render_view=self.render_view or {};local v=self.render_view
 v.x,v.y,v.z=pov.Location.X,pov.Location.Y,pov.Location.Z;v.pitch,v.yaw=pov.Rotation.Pitch,pov.Rotation.Yaw
end
function M:step(t,value)
 if self.closed or self.last==t then return end
 local dt=self.last and math.max(0,math.min(.25,t-self.last))or 0;self.last=t
 -- NPC/cloud callers cannot replace the player's authoritative status list.
 local status=self.binding.mc_status_service
 value=self.player_owner and status and status.value or value or empty_status
 if #self.particles==0 and self.emitter==0 and not rules.has_particles(value)then
  if self.visible then self.mesh:SetHiddenInGame(true,false);self.visible=false end
  self.report.visible=0;self.accumulator=0;return
 end
 self.accumulator=self.accumulator+dt
 local steps=math.floor(self.accumulator*20+1e-6);self.accumulator=self.accumulator-steps*.05
 for i=1,steps do self:physics(value,i==steps)end
 if (#self.particles>0 or self.visible)and (not self.next_render or t>=self.next_render)then
  local pov=self.pc.PlayerCameraManager.CameraCachePrivate.POV
  self.eye=self.eye or {};self.eye.X=pov.Location.X;self.eye.Y=pov.Location.Y;self.eye.Z=pov.Location.Z
  self.eye_at=self.last
  local v=self.render_view
  if self.render_generation~=self.generation or not v or math.abs(pov.Rotation.Pitch-v.pitch)>.05 or math.abs(pov.Rotation.Yaw-v.yaw)>.05
   or (pov.Location.X-v.x)^2+(pov.Location.Y-v.y)^2+(pov.Location.Z-v.z)^2>.01 then self:render(pov,t)end
  self.next_render=t+1/30
 end
end
function M:close()
 if self.closed then return end;self.closed=true
 if identity.matches(self.actor,self.actor_id)then self.actor:K2_DestroyActor()end
 if self.binding.mc_status_particles==self then self.binding.mc_status_particles=nil end
 self.actor=nil;self.mesh=nil;self.particles={};self.free={};self.buffer=nil;self.buffers={};self.visible_particles={};self.users={}
end
return M
