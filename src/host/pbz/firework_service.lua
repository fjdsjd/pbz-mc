-- Standard flight-1 rockets, no firework stars. Finite entities and visuals;
-- inventory consumption uses the existing savepoint-only memory transaction.
local rules=require('rules.firework_rocket')
local valid=require('host.pbz.appearance').valid
local identity=require('host.pbz.object_identity')
local M={};M.__index=M
local function clock(p)return StaticFindObject('/Script/Engine.Default__GameplayStatics'):GetTimeSeconds(p)end
local function vec(v)return {X=v.X,Y=v.Y,Z=v.Z}end
function M.new(binding,pc,log)
 assert(not binding.mc_fireworks or binding.mc_fireworks.closed,'firework-single-owner')
 local self=setmetatable({binding=binding,pc=pc,log=log,rockets={},seen={},serial=0,
  report={launched=0,attached=0,boosts=0,expired=0,peak=0},last=clock(binding.actor),accumulator=0},M)
 binding.mc_fireworks=self
 self.timer=LoopInGameThreadAfterFrames(1,function()
  local ok,why=pcall(self.tick,self)
  if not ok then self.report.error=tostring(why);self.log('MC firework failed: '..tostring(why));self:close()end
 end)
 return self
end
function M:sound(event,position)
 local build=require('host.pbz.building_service').get(self.binding)
 if build and build.audio then
  local ok,why=pcall(build.audio.combat,build.audio,event,position,self.pc)
  if not ok then self.report.audio_error=tostring(why)end
 end
end
function M:trace(start,finish)
 local hit={};local color={R=0,G=0,B=0,A=0};local ignore={self.binding.actor}
 local yes=require('UEHelpers').GetKismetSystemLibrary():SphereTraceSingle(self.binding.actor,start,finish,1,0,false,ignore,0,hit,true,color,color,0)
 local target
 if yes then
  local ok,value=pcall(function()return hit.HitObjectHandle.ReferenceObject:Get()end)
  if ok and valid(value)then target=value:IsA(StaticFindObject('/Script/Engine.Actor'))and value or value:GetOwner()end
 end
 return yes,hit,target
end
function M:use(record,aim)
 if self.closed or not self.binding:is_current()or #self.rockets>=32 then return false,'fail'end
 local status=self.binding.mc_status_service
 if not status or not status:current()or self.seen[record.action_id]then return false,'fail'end
 local slots=require('rules.container_slots');local data=require('host.pbz.campaign_inventory').view(self.binding)
 local address=record.hand=='offhand'and 'player/offhand'or 'player/hotbar/'..data.player.selected
 local stack=slots.get(data,address)
 if not stack or stack.content_id~='pbzmc:firework_rocket'or not record.equipment[record.hand]
  or require('storage.canonical_json')(stack)~=require('storage.canonical_json')(record.equipment[record.hand])then return false,'fail'end
 local flying=self.binding.mc_gliding and self.binding.mc_gliding.active
 local position
 if flying then position=vec(self.binding.actor:K2_GetActorLocation())
 else
  local start,direction=aim();local yes,hit,target=self:trace(start,{X=start.X+direction.X*500,Y=start.Y+direction.Y*500,Z=start.Z+direction.Z*500})
  if not yes then return false,'pass'end
  if target and target:IsA(StaticFindObject('/Script/ProjectPBZ.PBZCharacter'))then return false,'pass'end
  local n=hit.ImpactNormal;local p=hit.ImpactPoint
  position={X=p.X+n.X*15,Y=p.Y+n.Y*15,Z=p.Z+n.Z*15}
 end
 local state=flying and rules.new_attached(1,math.random(0,5),math.random(0,6))
  or rules.new_world(1,math.random(0,5),math.random(0,6),math.random()-math.random(),math.random()-math.random())
 if not self.visual then self.visual=require('host.pbz.firework_visuals').new(self.binding,self.pc)end
 local visual=self.visual:launch(position,{attached=flying==true})
 if not visual then return false,'fail'end
 local ok,why=pcall(status.commit,status,status.value,address,stack,status.mode=='adventure')
 if not ok then self.visual:remove(visual);self.report.rejected=tostring(why);return false,'fail'end
 self.serial=self.serial+1;self.seen[record.action_id]=true
 if self.serial>512 then self.seen={[record.action_id]=true};self.serial=1 end
 self.rockets[#self.rockets+1]={state=state,visual=visual,position=position,
  velocity={X=state.vx or 0,Y=state.vy or 0,Z=state.vz or 100},remaining=0,action_id=record.action_id}
 self.report.launched=self.report.launched+1;self.report.attached=self.report.attached+(flying and 1 or 0)
 self.report.peak=math.max(self.report.peak,#self.rockets)
 self.report.last_use={hand=record.hand,attached=flying==true,consumed=status.mode=='adventure',action_id=record.action_id}
 self:sound('firework_launch',position)
 return true,'success'
end
function M:retire(index)
 local rocket=self.rockets[index];self.visual:remove(rocket.visual);table.remove(self.rockets,index)
 self.report.expired=self.report.expired+1
end
function M:boost_tick(velocity,look)
 for i=#self.rockets,1,-1 do
  local r=self.rockets[i]
  if r.state.kind=='attached'then
   local next,event=rules.step_attached(r.state,velocity,look,true);velocity=next
   self.report.boosts=self.report.boosts+1
   if event.expired then self:retire(i)end
  end
 end
 return velocity
end
function M:tick()
 if self.closed then return end
 if not self.binding:is_current()or self.binding.actor.AttributeSetBase.Health.CurrentValue<=0 then self:close();return end
 local now=clock(self.binding.actor);self.pending=(self.pending or 0)+math.max(0,now-self.last);self.last=now
 if self.pending>2 then self:close();return end
 local dt=math.min(.2,self.pending);self.pending=self.pending-dt
 local flight=self.binding.mc_gliding;local gliding=flight and flight.active
 for i=#self.rockets,1,-1 do
  local r=self.rockets[i];local remaining=dt;local expired=false
  if r.state.kind=='attached'then
   r.position=vec(self.binding.actor:K2_GetActorLocation());r.velocity=gliding and flight.velocity or vec(self.binding.actor:GetVelocity())
   if not gliding then
    r.inactive_time=(r.inactive_time or 0)+dt
    while r.inactive_time>=.05 and not expired do
     r.inactive_time=r.inactive_time-.05
     local _,event=rules.step_attached(r.state,r.velocity,nil,false);expired=event.expired
    end
   else r.inactive_time=0 end
  else
   while remaining>1e-7 and not expired do
    if r.remaining<=1e-7 then
     local frame,event=rules.step_world(r.state,r.horizontal_collision)
     r.velocity=frame.velocity;r.expire_after_move=event.expired;r.remaining=.05
    end
    local step=math.min(remaining,r.remaining);local v=r.velocity
    local finish={X=r.position.X+v.X*step,Y=r.position.Y+v.Y*step,Z=r.position.Z+v.Z*step}
    local yes,hit,target=self:trace(r.position,finish)
    if yes then
     r.horizontal_collision=math.abs(hit.ImpactNormal.Z)<.65;r.position=vec(hit.Location)
     if target and target:IsA(StaticFindObject('/Script/ProjectPBZ.PBZCharacter'))then rules.entity_hit(r.state);expired=true end
    else r.position=finish;r.horizontal_collision=false end
    r.remaining=r.remaining-step;remaining=remaining-step
    if r.remaining<=1e-7 and r.expire_after_move then expired=true end
   end
  end
  if expired then self:retire(i)else self.visual:update(r.visual,r.position,r.velocity)end
 end
 if self.visual then self.visual:tick(dt)end
end
function M:close()
 if self.closed then return end;self.closed=true
 if self.timer then CancelDelayedAction(self.timer);self.timer=nil end
 if self.visual then self.visual:close()end
 self.rockets={};if self.binding.mc_fireworks==self then self.binding.mc_fireworks=nil end
end
return M
