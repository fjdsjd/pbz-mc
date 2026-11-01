-- Original entity_effect/glitter frames; one bounded world particle batch.
local valid=require('host.pbz.appearance').valid
local identity=require('host.pbz.object_identity')
local bundle=require('host.pbz.mesh_bundle')
local rules=require('rules.status_effects')
local M={};M.__index=M
local function transform()return {Rotation={X=0,Y=0,Z=0,W=1},Translation={X=0,Y=0,Z=0},Scale3D={X=1,Y=1,Z=1}}end
local function linear(v)return v<=.04045 and v/12.92 or ((v+.055)/1.055)^2.4 end
function M.new(binding,pc)
 return setmetatable({binding=binding,pc=pc,particles={},accumulator=0,emitter=0,spawned=0,peak=0},M)
end
function M:prepare()
 if identity.matches(self.actor,self.actor_id) then return end
 local root=self.binding.item_models_root..'/../effects/'
 local f=assert(io.open(root..'status_particles.json','rb'));local spec=assert(require('dkjson').decode(f:read('a')));f:close()
 f=assert(io.open(root..'status_particles.png','rb'));local raw=f:read('a');f:close()
 assert(require('storage.sha256')(raw)==spec.sha256,'status-particle-digest')
 self.actor=self.binding.actor:GetWorld():SpawnActor(StaticFindObject('/Script/Engine.Actor'),{X=0,Y=0,Z=0},{Pitch=0,Yaw=0,Roll=0})
 self.actor_id=identity.capture(self.actor)
 self.mesh=self.actor:AddComponentByClass(StaticFindObject('/Script/ProceduralMeshComponent.ProceduralMeshComponent'),true,transform(),false)
 self.mesh:SetCollisionEnabled(0);self.mesh:SetCastShadow(false)
 self.texture=StaticFindObject('/Script/Engine.KismetRenderingLibrary:ImportFileAsTexture2D')(
  StaticFindObject('/Script/Engine.Default__KismetRenderingLibrary'),self.actor,root..'status_particles.png')
 assert(valid(self.texture),'status-particle-texture');self.texture.Filter=0
 self.material=StaticFindObject('/Script/Engine.Default__KismetMaterialLibrary'):CreateDynamicMaterialInstance(
  self.actor,StaticFindObject('/Paper2D/MaskedUnlitSpriteMaterial.MaskedUnlitSpriteMaterial'),FName('PBZMC_StatusParticles'),1)
 self.material:SetTextureParameterValue(FName('SpriteTexture'),self.texture);self.mesh:SetMaterial(0,self.material)
end
function M:activate(t)
 self:prepare();self.emitter=30
 -- Activation is rendered by the HUD, centered in screen coordinates. World
 -- particles remain here; camera depth, FOV and the hand pose cannot offset it.
end
function M:emit(kind,color)
 if #self.particles>=384 then return end
 local p=self.binding.actor:K2_GetActorLocation();local capsule=self.binding.actor.CapsuleComponent
 local width=capsule:GetScaledCapsuleRadius()*2;local height=capsule:GetScaledCapsuleHalfHeight()*2
 local x,y,z=math.random()*2-1,math.random()*2-1,math.random()*2-1
 if kind==1 and x*x+y*y+z*z>1 then return end
 local r,g,b
 if kind==1 then
  if math.random(4)==1 then r=.6+math.random()*.2;g=.6+math.random()*.3;b=math.random()*.2
  else r=.1+math.random()*.2;g=.4+math.random()*.3;b=math.random()*.2 end
 else r=((color>>16)&255)/255;g=((color>>8)&255)/255;b=(color&255)/255 end
 self.particles[#self.particles+1]={x=p.X+x*width/4,y=p.Y+y*width/4,z=p.Z+z*height/2,
  vx=kind==1 and x*800 or (math.random()-.5)*20,vy=kind==1 and y*800 or (math.random()-.5)*20,
  vz=kind==1 and (z+.2)*800 or 4,age=0,max=kind==1 and 60+math.random(0,11) or math.floor(8/(math.random()*.8+.2)),
  kind=kind,r=r,g=g,b=b,half_size=11.25*(math.random()*.5+.5)}
 self.spawned=self.spawned+1;self.peak=math.max(self.peak,#self.particles)
end
function M:physics(value)
 for i=#self.particles,1,-1 do
  local p=self.particles[i];p.age=p.age+1
  if p.age>=p.max then table.remove(self.particles,i) else
   p.vz=p.vz+(p.kind==1 and -5 or 8)
   p.x=p.x+p.vx*.05;p.y=p.y+p.vy*.05;p.z=p.z+p.vz*.05
   local friction=p.kind==1 and .6 or .96;p.vx=p.vx*friction;p.vy=p.vy*friction;p.vz=p.vz*friction
  end
 end
 if self.emitter>0 then for _=1,16 do self:emit(1) end;self.emitter=self.emitter-1 end
 local effects=rules.list(value)
 if #effects>0 and math.random(4)==1 then self:emit(0,effects[math.random(#effects)].color) end
end
function M:render()
 local pov=self.pc.PlayerCameraManager.CameraCachePrivate.POV
 local _,right,up=require('presentation.native_steve_pose').axes(pov.Rotation)
 local origin=self.binding.actor:K2_GetActorLocation();local part={positions={},normals={},uv={},colors={},triangles={}}
 for i=1,384 do
  local p=self.particles[i];local frame=p and math.min(7,math.floor(p.age*8/(p.max+1))) or 0
  local size=p and p.half_size or 0;local color=p and {R=linear(p.r),G=linear(p.g),B=linear(p.b),A=1} or {R=0,G=0,B=0,A=0}
  for _,c in ipairs({{-1,-1,0,1},{1,-1,1,1},{1,1,1,0},{-1,1,0,0}}) do
   part.positions[#part.positions+1]={X=(p and p.x-origin.X or 0)+right.X*c[1]*size+up.X*c[2]*size,
    Y=(p and p.y-origin.Y or 0)+right.Y*c[1]*size+up.Y*c[2]*size,Z=(p and p.z-origin.Z or 0)+right.Z*c[1]*size+up.Z*c[2]*size}
   part.normals[#part.normals+1]={X=0,Y=0,Z=1};part.uv[#part.uv+1]={X=(frame+c[3])/8,Y=((p and p.kind or 0)+c[4])/2};part.colors[#part.colors+1]=color
  end
  for _,index in ipairs({0,1,2,0,2,3,2,1,0,3,2,0}) do part.triangles[#part.triangles+1]=(i-1)*4+index end
 end
 self.mesh:K2_SetWorldLocationAndRotation({X=origin.X,Y=origin.Y,Z=origin.Z},{Pitch=0,Yaw=0,Roll=0},false,{},true)
 if self.uploaded then self.mesh:UpdateMeshSection_LinearColor(0,part.positions,part.normals,part.uv,{},{},{},part.colors,{},false)
 else bundle.apply(self.mesh,part);self.uploaded=true end
 self.mesh:SetHiddenInGame(#self.particles==0,false)
end
function M:step(t,value)
 self:prepare();local dt=self.last and math.max(0,math.min(.25,t-self.last)) or 0;self.last=t;self.accumulator=self.accumulator+dt
 while self.accumulator>=.05 do self.accumulator=self.accumulator-.05;self:physics(value) end
 if #self.particles>0 or self.was_visible then
  if not self.next_render or t>=self.next_render then self:render();self.next_render=t+1/30 end
  self.was_visible=#self.particles>0
 end
end
function M:close()
 if identity.matches(self.actor,self.actor_id) then self.actor:K2_DestroyActor() end
 self.actor=nil;self.particles={}
end
return M
