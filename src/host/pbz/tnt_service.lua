-- Playable TNT ownership. One memory transaction on prime/removal; no fuse,
-- velocity, native pointer, fire, particle or damage intent is serialized.
local rules=require('rules.tnt')
local campaign=require('host.pbz.campaign_inventory')
local damage=require('host.pbz.tnt_damage')
local M={};local Service={};Service.__index=Service;local active
local function count(t)local n=0;for _ in pairs(t)do n=n+1 end;return n end
local function dist(a,b)return math.sqrt((a.x-b.x)^2+(a.y-b.y)^2+(a.z-b.z)^2)end
local function xyz(p)return {x=p.X,y=p.Y,z=p.Z}end
local function vector(p)return {X=p.x,Y=p.y,Z=p.z}end
function Service:current()
 return not self.closed and self.binding:is_current() and campaign.current(self.binding) and self.build.store:current()
end
function Service:report(event,detail)
 self.last_event=event;self.last_detail=detail;pcall(self.log,'MC TNT '..event..' '..tostring(detail or ''))
end
function Service:visual(method,...)
 local ok,why=pcall(method,...)
 if not ok then self.visual_error=tostring(why)end
 return ok
end
function Service:sound(kind,p)
 local ok,why=pcall(self.audio.play,self.audio,kind,p)
 if not ok then self.audio.error=tostring(why)end
end
function Service:wake()
 if self.idle then
  self.last_time=self.clock:GetTimeSeconds(self.binding.actor);self.idle=nil
 end
end
function Service:prime(id,fuse)
 if not self:current()then return false,'stale-tnt-scene'end
 if self.primed[id]then return false,'already-primed'end
 if count(self.primed)>=128 then return false,'active-tnt-budget'end
 local session=self.build.session;session:poll_cleanup()
 if session.quarantined or session.busy then return false,'building-cleanup-pending'end
 local record=session.data.buildings[id]
 if not record or record.world~=session.world or record.content_id~='pbzmc:tnt'then return false,'not-unprimed-tnt'end
 local state=rules.new(record);rules.prime(state,fuse,math.random())
 -- Prepare the complete transient mesh first. A failed world transaction
 -- destroys it and retains the colliding persistent TNT cube.
 local prepared,handle=pcall(self.world.spawn,self.world,'tnt',state)
 if not prepared then return false,tostring(handle)end
 local ok,why=self.build.store:environmental(function()
  return require('rules.remove_buildings')(session,{id},self.build.world,self.build.store,true)
 end)
 if not ok then self:visual(self.world.destroy,self.world,handle);return false,why end
 if self.build.mining==id then self.build.mining=nil;self.build.progress=0 end
 self:wake()
 self.serial=self.serial+1
 self.primed[id]={state=state,handle=handle,action_id='tnt/'..self.serial..'/'..id}
 self.primes=self.primes+1;self:sound('fuse',state);self:report('primed',id..' fuse='..state.fuse)
 return true
end
function Service:ignite(aim)
 if not self:current()then return false,'fail'end
 local hit,handle=self.build:target(aim)
 if handle then
  local r=self.build.session.data.buildings[handle.id]
  if r and r.content_id=='pbzmc:tnt'then
   local ok,why=self:prime(handle.id,4)
   if ok then self:sound('flint',r)else self:report('prime-rejected',why)end
   return ok,ok and 'success'or 'fail'
  end
 end
 -- Baseline flint assists nearby aimed TNT, but never lights through a wall.
 local start,direction=aim();local nearest,range
 self.build.session:visit_nearby(xyz(start),550,function(r)
  if r.content_id=='pbzmc:tnt'then
   local d=dist(xyz(start),r)
   if d>1 and d<550 and (not range or d<range)
      and ((r.x-start.X)*direction.X+(r.y-start.Y)*direction.Y+(r.z-start.Z)*direction.Z)/d>.7 then
    local yes,result=self.build.world:line_trace(start,{X=r.x,Y=r.y,Z=r.z})
    local visible=yes and self.build.world:hit_handle(result)
    if visible and visible.id==r.id then nearest=r.id;range=d end
   end
  end
 end)
 if nearest then
  local r=self.build.session.data.buildings[nearest];local ok,why=self:prime(nearest,4)
  if ok then self:sound('flint',r)else self:report('prime-rejected',why)end
  return ok,ok and 'success'or 'fail'
 end
 if not hit or hit.ImpactNormal.Z<=.55 then return false,'pass'end
 local owner=self.build.world:hit_actor(hit)
 if owner and owner:IsValid() and owner:IsA(StaticFindObject('/Script/Engine.Pawn'))then return false,'pass'end
 local p=xyz(hit.ImpactPoint);p.z=p.z+45
 for _,fire in pairs(self.fires)do if dist(p,fire.state)<90 then return true,'consume'end end
 if count(self.fires)>=32 then return false,'fail'end
 local state=rules.new_fire(p);local h=self.world:spawn('fire',state);self.serial=self.serial+1
 self:wake();local id='fire/'..self.serial;self.fires[id]={state=state,handle=h,ticks=0}
 self:sound('flint',state);self:report('fire-created',id);return true,'success'
end
function Service:extinguish(aim)
 if not self:current()then return false end
 local start,d=aim();local target,t
 for id,f in pairs(self.fires)do
  local x,y,z=f.state.x-start.X,f.state.y-start.Y,f.state.z-start.Z
  local along=x*d.X+y*d.Y+z*d.Z
  if along>=0 and along<500 and x*x+y*y+z*z-along*along<65^2 and (not t or along<t)then target=id;t=along end
 end
 if not target then return false end
 local hit=self.build:target(aim)
 if hit and dist(xyz(start),xyz(hit.ImpactPoint))<t-65 then return false end
 local f=self.fires[target];self:sound('extinguish',f.state);self.world:destroy(f.handle);self.fires[target]=nil
 self.extinguished=self.extinguished+1;self:report('fire-extinguished',target);return true
end
function Service:explode(id,entity)
 -- Remove ownership before dispatch: damage/FX failures cannot replay it.
 self.primed[id]=nil;self:visual(self.world.destroy,self.world,entity.handle);self.explosions=self.explosions+1
 local p=rules.explosion_origin(entity.state);local center=vector(p)
 self:sound('explosion',p);self:visual(self.fx.explosion,self.fx,p)
 local sampler=self.binding.mc_fluid_sampler
 local wet=sampler and sampler:water_at(p.x,p.y,p.z) or false
 local pushed=0
 for _,other in pairs(self.primed)do
  local s=other.state
  if not s.exploded and (s.x-p.x)^2+(s.y-p.y)^2+(s.z-49-p.z)^2<rules.blast_radius^2 then
   local exposure=self.damage:tnt_exposure(center,s,other.handle.actor)
   if rules.push_primed(s,p,exposure)then pushed=pushed+1 end
  end
 end
 local boats=require('host.pbz.boat_service').get(self.binding)
 if boats then boats:blast(p,self.damage)end
 if not wet then
  self.build.session:visit_nearby(p,rules.blast_radius,function(r)
   local key=r.id;local effect=rules.block_effect(r.content_id,dist(p,r),self.primed[key]~=nil)
   if effect=='chain' and not self.chain[key]then self.chain[key]=rules.chain_fuse(math.random())
   elseif effect=='remove'then self.demolish[key]=true end
  end)
 end
 -- Destructible MC blocks disappear before the native line-of-sight query,
 -- matching the pinned baseline. A failed transaction stays queued intact.
 if next(self.demolish)then
  local removed,why=pcall(self.drain_demolition,self)
  if not removed then self.error=tostring(why)end
 end
 self.last_damage=self.damage:explode(center,nil,entity.action_id,4,wet)
 self:report('exploded',id..' underwater='..tostring(wet)..' primed-pushed='..pushed..' pending-chain='..count(self.chain))
end
function Service:drain_demolition()
 local ids={};local session=self.build.session;session:poll_cleanup()
 if session.quarantined or session.busy then return end
 for id in pairs(self.demolish)do
  if not session.data.buildings[id]then self.demolish[id]=nil else ids[#ids+1]=id end
 end
 if #ids==0 then return end;table.sort(ids)
 local ok,why=self.build.store:environmental(function()
  return require('rules.remove_buildings')(session,ids,self.build.world,self.build.store,true)
 end)
 if ok then
  for _,id in ipairs(ids)do self.demolish[id]=nil end
  self.removed=self.removed+#ids
  if self.build.mining and not session.data.buildings[self.build.mining]then self.build.mining=nil;self.build.progress=0 end
 else self.error=tostring(why)end
end
function Service:tick()
 if not next(self.primed) and not next(self.fires) and not next(self.chain) and not next(self.demolish)
     and #self.fx.particles==0 and not next(self.fx.emitters or {}) and (not self.fx.handle or self.fx.hidden)then
  self.tnt_time=0;self.idle=(self.idle or 0)+1
  if self.idle%30~=1 then return end
  if not self:current()then M.close()end
  return
 end
 if not self:current()then M.close();return end
 local game=self.clock
 local now=game:GetTimeSeconds(self.binding.actor)
 if game:IsGamePaused(self.binding.actor)then self.last_time=now;return end
 local dt=math.max(0,now-(self.last_time or now));self.last_time=now
 -- After long stalls, resume the simulation with bounded work. Never apply
 -- seconds of accumulated environmental damage in one render callback.
 dt=math.min(dt,.1)
 if next(self.demolish)then
  local removed,why=pcall(self.drain_demolition,self)
  if not removed then self.error=tostring(why)end
 end
 local attempts=0
 for id,fuse in pairs(self.chain)do
  if attempts>=4 then break end;attempts=attempts+1
  if not self.build.session.data.buildings[id]then self.chain[id]=nil
  else
   local tried,ok=pcall(self.prime,self,id,fuse)
   if tried and ok then self.chain[id]=nil elseif not tried then self.error=tostring(ok)end
  end
 end
 if next(self.primed)then self:tick_primed(dt)else self.tnt_time=0 end
 for id,f in pairs(self.fires)do
  local output=rules.advance_fire(f.state,dt)
  for _=1,output.damage_ticks do f.ticks=f.ticks+1;self.last_fire_damage=self.damage:burn(vector(f.state),id..'/tick/'..f.ticks)end
  for _=1,output.smoke_ticks do self:visual(self.fx.smoke,self.fx,f.state);if math.random(5)==1 then self:sound('fire',f.state)end end
  if output.expired or f.state.expired then self.fires[id]=nil;self:visual(self.world.destroy,self.world,f.handle)
  else self:visual(self.world.render,self.world,f.handle,f.state,output)end
 end
 self:visual(self.fx.tick,self.fx,dt)
end
function Service:tick_primed(dt)
 local sampler=self.binding.mc_fluid_sampler
 local fluid=self.build.mechanisms and self.build.mechanisms.fluid
 local current=sampler and (not fluid or fluid.cell_count>0) and function(x,y,z,h)return sampler:tnt_current(x,y,z,h)end
 local sweep=function(a,b,r)return self.world:trace(a,b,r)end
 self.tnt_time=(self.tnt_time or 0)+dt
 local budget=8
 while self.tnt_time+1e-8>=rules.tick_seconds and budget>0 do
  self.tnt_time=math.max(0,self.tnt_time-rules.tick_seconds)
  local due={}
  -- All TNT reaches the same simulation boundary before any blast adds
  -- velocity. Lua hash iteration and render frame size cannot move a shot early.
  for id,e in pairs(self.primed)do
   local output=rules.advance(e.state,rules.tick_seconds,sweep,current)
   for _,p in ipairs(output.smoke)do self:visual(self.fx.smoke,self.fx,p)end
   if e.state.exploded then due[#due+1]=id
   else self:visual(self.world.render,self.world,e.handle,e.state,output)end
  end
  table.sort(due)
  for i=1,math.min(#due,budget)do self:explode(due[i],self.primed[due[i]])end
  budget=budget-math.min(#due,budget)
 end
end
function Service:state()
 local primed={};for id,e in pairs(self.primed)do primed[#primed+1]={id=id,x=e.state.x,y=e.state.y,z=e.state.z,left=e.state.fuse-e.state.age}end
 return {ready=true,primed=primed,fires=count(self.fires),chain=count(self.chain),pending_remove=count(self.demolish),
  primes=self.primes,explosions=self.explosions,removed=self.removed,extinguished=self.extinguished,
  last_event=self.last_event,last_detail=self.last_detail,last_damage=self.last_damage,last_fire_damage=self.last_fire_damage,
  particles=#self.fx.particles,audio=self.audio.state and self.audio:state() or
   {played=self.audio.played,counts=self.audio.counts,error=self.audio.error},error=self.error,visual_error=self.visual_error}
end
function M.get(binding)return active and active.binding==binding and active or nil end
function M.close()
 if not active then return true end;local self=active
 if self.loop then CancelDelayedAction(self.loop);self.loop=nil end
 if self.audio.close then self.audio:close()end
 self.damage:close();self.world:close();self.closed=true;active=nil;return true
end
function M.ensure(binding,directory,log)
 if active and (active.binding~=binding or not active:current())then M.close()end
 if active then return active end
 local ready,why=damage.ready();if not ready then return nil,why end
 local self=setmetatable({binding=binding,build=assert(require('host.pbz.building_service').get(binding)),
  world=require('host.pbz.tnt_world').new(binding,directory),damage=damage.new(binding,log),log=log,
  clock=StaticFindObject('/Script/Engine.Default__GameplayStatics'),
  primed={},fires={},chain={},demolish={},serial=0,primes=0,explosions=0,removed=0,extinguished=0},Service)
 self.fx=require('host.pbz.tnt_effects').new(self.world)
 self.world.build_world=self.build.world;self.damage.build_world=self.build.world
 self.audio=require('host.pbz.tnt_sounds').new(directory..'/pbzmc-assets/tnt')
 active=self
 self.loop=LoopInGameThreadAfterFrames(1,function()
  local ok,err=pcall(self.tick,self)
  if not ok then self.error=tostring(err);self:report('service-error',self.error);M.close()end
 end)
 self:report('bound','4s fuse; transient entities; native damage');return self
end
return M
