-- All potion forms share the same admitted-entity effect adapter. One fixed
-- update for projectiles/clouds; pooled particle mesh, no per-bottle timers.
local rules=require('rules.potions')
local status_rules=require('rules.status_effects')
local state=require('storage.state')
local identity=require('host.pbz.object_identity')
local valid=require('host.pbz.appearance').valid
local bundle=require('host.pbz.mesh_bundle')
local M={};M.__index=M
local function vec(p)return {X=p.X,Y=p.Y,Z=p.Z}end
local function clock(actor)return StaticFindObject('/Script/Engine.Default__GameplayStatics'):GetTimeSeconds(actor)end
local transform={Rotation={X=0,Y=0,Z=0,W=1},Translation={X=0,Y=0,Z=0},Scale3D={X=1,Y=1,Z=1}}
function M.new(combat)
 return setmetatable({combat=combat,binding=combat.binding,shots={},clouds={},seen={},order={},report={thrown=0,drunk=0,hits=0,clouds=0}},M)
end
function M:entities()
 local service=require('host.pbz.command_service').get(self.binding)
 return assert(service and service.entities,'potion-entity-service-unavailable')
end
function M:check(potion)
 assert(potion and potion.available,'potion-not-supported')
 for _,e in ipairs(potion.effects)do assert(require('host.pbz.entity_effects').supported[e.id],'potion-effect-unsupported:'..e.id)end
end
function M:sound(event,p)
 if not self.audio then
  local f=assert(io.open(self.binding.item_models_root..'/../potions/sounds/manifest.json','rb'))
  self.audio=assert(require('dkjson').decode(f:read('a')));f:close()
 end
 local now=clock(self.binding.actor);self.sound_times=self.sound_times or {}
 if now<(self.sound_times[event]or 0)then return false end
 self.sound_times[event]=now+(event=='drink'and .3 or .08)
 local rows=assert(self.audio.events[event]);local clip=rows[math.random(#rows)]
 local eye=self.combat.pc.PlayerCameraManager.CameraCachePrivate.POV.Location
 local distance=math.sqrt((eye.X-p.X)^2+(eye.Y-p.Y)^2+(eye.Z-p.Z)^2)
 if distance>=1600 then return false end
 local response,why=PBZMC_BlockSound(require('dkjson').encode({clip=clip,gain=math.max(0,1-distance/1600),pitch=1,pan=0,
  sound_event='minecraft:'..self.audio.event_names[event],source='player',owner='potions'}))
 assert(response,why);return true
end
function M:remember(record)
 local key=tostring(record.source)..'/'..record.action_id
 assert(not self.seen[key],'potion-duplicate-use')
 local slot=(self.seen_slot or 0)%128+1;local old=self.order[slot];if old then self.seen[old]=nil end
 self.order[slot]=key;self.seen[key]=true;self.seen_slot=slot
end
function M:consume(record,next,remainder)
 local status=assert(self.binding.mc_status_service,'potion-player-status-unavailable')
 local hands=assert(status:held(),'potion-held-unavailable')
 local chosen=record.hand=='offhand'and hands[2]or hands[1]
 local consume=status.mode=='adventure'and not self.binding.mc_creative
 status:commit(next,chosen.address,record.equipment[record.hand],consume,consume and remainder or nil)
end
function M:drink(record)
 local status=self.binding.mc_status_service
 if not status or not status:current()then return false end
 local item=record.equipment[record.hand];if not item then return false end
 local milk=item.content_id=='pbzmc:milk_bucket';local potion=rules.get(item.content_id)
 if not milk then self:check(potion);assert(potion.form=='potion','potion-not-drinkable')end
 local entities=self:entities();local h=entities:actor_handle(self.binding.actor)
 local candidate=state.clone(status.value);local max=self.binding.actor.AttributeSetBase.Health_Max.CurrentValue
 local instant={}
 if milk then candidate.effects={};candidate.absorption=0
 else
  for _,e in ipairs(potion.effects)do
   if e.id=='instant_health'or e.id=='instant_damage'then instant[#instant+1]=e
   else status_rules.add(candidate,e.id,e.ticks,e.amplifier,max)end
  end
 end
 self:remember(record)
 local s=entities:_effect_state(h);local old=s.state;s.state=candidate;s.values=candidate.effects
 local ok,why=pcall(function()
  entities:_modifiers(s)
  self:consume(record,candidate,{content_id=milk and 'pbzmc:bucket'or 'pbzmc:glass_bottle',count=1,metadata=state.object()})
 end)
 if not ok then s.state=old;s.values=old.effects;pcall(entities._modifiers,entities,s);error(why)end
 for _,e in ipairs(instant)do entities:_effect({handle=h},e.id,1,e.amplifier)end
 self.report.drunk=self.report.drunk+1;self.report.last_drink=item.content_id
 return true
end
function M:particles()
 if not self.fx then self.fx=require('host.pbz.status_particles').acquire(self.binding,self.combat.pc,self)end
 return self.fx
end
function M:apply(potion,row,scale,cloud)
 local accepted=false
 for _,effect in ipairs(potion.effects)do
  local instant=effect.id=='instant_health'or effect.id=='instant_damage'
  local ticks=instant and 1 or rules.scaled(effect,scale)
  if instant or ticks>20 then
   local ok,why=self:entities():effect(row,effect.id,ticks,effect.amplifier,false,instant and (cloud and .5 or scale)or nil)
   if ok then accepted=true
   elseif why~='effect-immune'and why~='creative-immune'then self.combat.log('MC potion target: '..tostring(why))end
  end
 end
 if accepted then self.report.hits=self.report.hits+1 end
 return accepted
end
function M:impact(potion,point,direct,hostile_only)
 self:check(potion)
 self:sound('splash',point)
 local fx=self:particles()
 for _=1,24 do fx:emit_at(potion.color,point,120,60)end
 if potion.form=='lingering_potion'and #potion.effects>0 then
  if #self.clouds>=rules.cloud_limit then table.remove(self.clouds,1)end
  local c=rules.cloud();c.position=vec(point);c.potion=potion;c.hostile_only=hostile_only
  self.clouds[#self.clouds+1]=c;self.report.clouds=self.report.clouds+1;self:start();return true
 end
 for _,row in ipairs(self:entities():nearby(point,400))do
  if not hostile_only or self.combat.damage:eligible(row.handle.actor)and row.handle.kind=='native'then
   local scale=direct and identity.matches(row.handle.actor,direct)and 1 or rules.splash(row.distance)
   self:apply(potion,row,scale)
  end
 end
 self:start();return true
end
function M:destroy(p)
 if identity.matches(p.actor,p.identity)then p.actor:K2_DestroyActor()end
end
function M:_throw(record)
 assert(not self.closed and self.binding:is_current(),'potion-owner-stale')
 if #self.shots>=rules.limit then return false,'fail'end
 local potion=rules.get(record.equipment[record.hand].content_id);self:check(potion)
 assert(potion.form~='potion','potion-not-throwable')
 self.models=self.models or require('host.pbz.item_models').new(self.binding.item_models_root)
 local model=assert(self.models:resolve(record.equipment[record.hand],'ground',{},6.25))
 local point,dir=self.combat:aim();point=vec(point)
 local actor=self.binding.actor:GetWorld():SpawnActor(StaticFindObject('/Script/Engine.Actor'),point,{Pitch=0,Yaw=0,Roll=0})
 assert(valid(actor),'potion-projectile-create')
 local p={actor=actor,identity=identity.capture(actor),potion=potion,position=point,age=0}
 local ok,why=pcall(function()
  p.mesh=actor:AddComponentByClass(StaticFindObject('/Script/ProceduralMeshComponent.ProceduralMeshComponent'),true,transform,false)
  assert(valid(p.mesh),'potion-projectile-mesh');p.mesh:SetCollisionEnabled(0);p.mesh:SetCastShadow(false)
  p.mesh:SetMaterial(0,self.binding.material);bundle.apply(p.mesh,model.part);p.mesh:SetWorldScale3D({X=.5,Y=.5,Z=.5})
  local pitch=math.atan(dir.Z,math.sqrt(dir.X^2+dir.Y^2))+math.rad(20);local yaw=math.atan(dir.Y,dir.X)
  local velocity=self.binding.actor:GetVelocity()
  p.velocity={X=math.cos(pitch)*math.cos(yaw)*1000+velocity.X,Y=math.cos(pitch)*math.sin(yaw)*1000+velocity.Y,
   Z=math.sin(pitch)*1000+(self.binding.actor.CharacterMovement.MovementMode==3 and velocity.Z or 0)}
  self:remember(record);self:consume(record,state.clone(self.binding.mc_status_service.value))
 end)
 if not ok then self:destroy(p);error(why)end
 self.shots[#self.shots+1]=p;self.report.thrown=self.report.thrown+1
 self:sound(potion.form=='lingering_potion'and 'linger'or 'throw',point);self:start();return true,'success'
end
function M:throw(record)
 local ok,result,outcome=pcall(self._throw,self,record)
 if not ok then self.report.error=tostring(result);self.combat.log('MC potion throw: '..tostring(result));return false,'fail'end
 return result,outcome
end
function M:start()
 if self.timer then return end
 self.last=clock(self.binding.actor);self.accumulator=0
 self.timer=LoopInGameThreadAfterFrames(1,function()
  local ok,why=pcall(self.tick,self)
  if not ok then self.combat.log('MC potion update: '..tostring(why));self.report.error=tostring(why);self:close()end
 end)
end
function M:step()
 for i=#self.shots,1,-1 do
  local p=self.shots[i];p.age=p.age+1
  local next={X=p.position.X+p.velocity.X*.05,Y=p.position.Y+p.velocity.Y*.05,Z=p.position.Z+p.velocity.Z*.05}
  local hit,result,actor=self.combat:trace(p.position,next,5,nil,{self.binding.actor,p.actor})
  if hit or p.age>=200 then
   table.remove(self.shots,i);self:destroy(p)
   if hit then self:impact(p.potion,vec(result.ImpactPoint),valid(actor)and identity.capture(actor))end
  else
   p.position=next;p.velocity.X=p.velocity.X*.99;p.velocity.Y=p.velocity.Y*.99;p.velocity.Z=p.velocity.Z*.99-100
   local r=self.combat.pc.PlayerCameraManager.CameraCachePrivate.POV.Rotation
   p.mesh:K2_SetWorldLocationAndRotation(next,{Pitch=-r.Pitch,Yaw=r.Yaw+180,Roll=0},false,{},true)
  end
 end
 for i=#self.clouds,1,-1 do
  local c=self.clouds[i];local alive,query=rules.cloud_tick(c)
  if not alive then table.remove(self.clouds,i)
  else
   if query then
    for _,row in ipairs(self:entities():nearby(c.position,c.radius))do
     local half=self:entities():_dimensions(row.handle)
     local p=row.position;local horizontal=(p.X-c.position.X)^2+(p.Y-c.position.Y)^2
     if horizontal<=c.radius^2 and math.abs(p.Z-half-c.position.Z)<=50
      and (not c.hostile_only or row.handle.kind=='native'and self.combat.damage:eligible(row.handle.actor))
      and (not c.victims[row.handle.id]or c.age>=c.victims[row.handle.id])then
      if self:apply(c.potion,row,.25,true)then rules.cloud_hit(c,row.handle.id)end
      if c.radius<50 then break end
     end
    end
   end
   if c.age>=c.wait and c.age%2==0 then
    local a=math.random()*math.pi*2;local r=math.sqrt(math.random())*c.radius
    self:particles():emit_at(c.potion.color,{X=c.position.X+math.cos(a)*r,Y=c.position.Y+math.sin(a)*r,Z=c.position.Z+10},8,10)
   end
  end
 end
end
function M:tick()
 if self.closed or not self.binding:is_current()then self:close();return end
 local now=clock(self.binding.actor);self.accumulator=self.accumulator+math.max(0,math.min(.25,now-self.last));self.last=now
 local steps=math.floor(self.accumulator*20+1e-6);self.accumulator=self.accumulator-steps*.05
 for _=1,steps do self:step()end
 if self.fx then self.fx:step(now)end
 if #self.shots==0 and #self.clouds==0 and (not self.fx or #self.fx.particles==0)then CancelDelayedAction(self.timer);self.timer=nil end
end
function M:close()
 if self.closed then return end;self.closed=true
 if self.timer then CancelDelayedAction(self.timer);self.timer=nil end
 for _,p in ipairs(self.shots)do self:destroy(p)end
 self.shots={};self.clouds={};if self.fx then self.fx:release(self)end
 pcall(PBZMC_BlockSound,require('dkjson').encode({op='stop',owner='potions'}))
end
return M
