-- Bounded MC-fluid contact adapter. No health/property writes, actor scans,
-- timers, save commits or movement lease: the mechanism owner calls tick(now).
-- Original rules: Entity lava=4 / ignite=15s; onFire=1 each20 ticks;
-- LivingEntity equal-damage cooldown admits lava each10 ticks (local26.3).
local fluids=require('rules.fluid_network')
local flow=require('rules.fluid_flow')
local blocks=require('content.blocks')
local identity=require('host.pbz.object_identity')
local valid=require('host.pbz.appearance').valid
local tnt=require('host.pbz.tnt_service')
local M={PLAYER_INTERVAL=.1,ENEMY_INTERVAL=.5,FLOW_INTERVAL=.05,MAX_ENEMY_CHECKS=32,MAX_TRACKED=256}
local Contact={};Contact.__index=Contact
local serial=0
local offsets={{0,0},{1,0},{-1,0},{0,1},{0,-1}}
local function finite(n)return type(n)=='number' and n==n and math.abs(n)<1e9 end
local function key(id)return tostring(id.address)..'/'..id.name end
local function point(p)
 assert(p and finite(p.X) and finite(p.Y) and finite(p.Z),'fluid-contact-position')
 return {X=p.X,Y=p.Y,Z=p.Z}
end
local function attribute(actor,name)
 local ok,n=pcall(function()return actor.AttributeSetBase[name].CurrentValue end)
 return ok and finite(n) and n or nil
end
function M.new(service)
 assert(type(service)=='table' and service.binding and type(service.read_world)=='function','fluid-contact-service-required')
 local binding=service.binding
 assert(binding:is_current() and valid(binding.actor),'fluid-contact-player-required')
 serial=serial+1
 local self=setmetatable({service=service,binding=binding,pawn_id=identity.capture(binding.actor),
  world_id=identity.capture(binding.actor:GetWorld()),clock=StaticFindObject('/Script/Engine.Default__GameplayStatics'),
  states={},order={},next_slot=1,enemy_cursor=1,next_player=0,next_enemies=0,next_flow=0,sequence=0,
  flowing={},flow_slots={},flow_cursor=1,
  action_prefix='fluid/'..serial..'/',report={samples=0,enemy_checks=0,attempts=0,dispatched=0,
   clamped=0,evicted=0,errors=0,flow_reads=0,flow_pushes=0,flow_checked=0},snapshot={kind=nil,submerged=false,depth=0,burning=false}},Contact)
 self.player={actor=binding.actor,id=self.pawn_id,player=true}
 self.world_name=type(service.world)=='string' and service.world
  or type(service.world)=='table' and service.world.world_id or nil
 binding.mc_fluid_contact=self.snapshot
 binding.mc_fluid_sampler=self
 return self
end
function Contact:_error(reason)
 reason=tostring(reason);self.report.errors=self.report.errors+1;self.report.error=reason
 if self.last_error~=reason then
  self.last_error=reason;pcall(self.service.log or function()end,'MC fluid contact '..reason)
 end
end
function Contact:_current()
 if self.closed or self.service.closed or not self.binding:is_current() then return false end
 local actor=self.binding.actor
 return identity.matches(actor,self.pawn_id) and identity.matches(actor:GetWorld(),self.world_id)
end
function Contact:_state(row,now)
 if row.player then
  self.player_state=self.player_state or {row=row,next_hit=0,burn_until=0}
  self.player_state.seen=now;return self.player_state
 end
 local k=key(row.id);local s=self.states[k]
 if s then s.row=row;s.seen=now;return s end
 if #self.order>=M.MAX_TRACKED then
  local old=self.order[self.next_slot]
  if old then self.states[old]=nil;self.report.evicted=self.report.evicted+1 end
 else self.next_slot=#self.order+1 end
 s={row=row,seen=now,next_hit=0,burn_until=0};self.states[k]=s
 self.order[self.next_slot]=k;self.next_slot=self.next_slot%M.MAX_TRACKED+1
 return s
end
function Contact:_dimensions(s,now)
 if s.dimensions and now<(s.dimensions_at or 0) then return s.dimensions end
 local capsule=s.row.actor.CapsuleComponent
 assert(valid(capsule),'fluid-contact-capsule-unavailable')
 local half,radius=capsule:GetScaledCapsuleHalfHeight(),capsule:GetScaledCapsuleRadius()
 assert(finite(half) and finite(radius) and half>0 and half<1000 and radius>0 and radius<1000,'fluid-contact-capsule-range')
 s.dimensions={half=half,radius=radius};s.dimensions_at=now+1
 return s.dimensions
end
function Contact:_point(x,y,z,heights)
 local record=self.service.read_world(x,y,z);local kind=fluids.kind(record)
 if not kind or self.world_name and record.world and record.world~=self.world_name then return end
 assert(finite(record.x) and finite(record.y) and finite(record.z),'fluid-contact-record-position')
 -- The host grid record stores its 100cm cell centre. A shallow level is
 -- only wet below its real surface, never the complete cube's bounding box.
 if math.abs(x-record.x)>50.001 or math.abs(y-record.y)>50.001 or z<record.z-50 then return end
 local cache_key=record.id or (record.x..':'..record.y..':'..record.z)
 local surface=heights[cache_key]
 if not surface then
  local above=self.service.read_world(record.x,record.y,record.z+100)
  surface=record.z-50+100*fluids.height(record,above);heights[cache_key]=surface
 end
 if z>=surface-1e-5 then return end
 return kind==fluids.water and 'water' or 'lava',surface,record
end
function Contact:_flow(record)
 local cache={};local read=self.service.read_flow_world or self.service.read_world
 local function neighbour(dx,dy,dz)
  local k=dx..':'..dy..':'..dz;local old=cache[k]
  if old~=nil then return old or nil end
  local r=read(record.x+dx*100,record.y+dy*100,record.z+dz*100)
  cache[k]=r or false;self.report.flow_reads=self.report.flow_reads+1;return r
 end
 return flow.vector(record,neighbour,function(r)
  if not r or fluids.kind(r)then return false end
  if r.native_terrain then return true end -- pending terrain is conservatively closed
  local definition=blocks.get(r.content_id)
  return definition and definition.collision~=false or false
 end)
end
-- Sample the actual water surface at the explosion origin. The TNT hull may
-- already overlap water while the point which emits the blast is still dry.
function Contact:water_at(x,y,z)
 return not self.closed and self:_point(x,y,z,{})=='water'
end
function Contact:tnt_current(x,y,z,half)
 if self.closed then return end
 -- The .98-block hull can touch at most 2x2x2 cells. Only the lower edge
 -- and crossed upper layer matter; count each wet cell once, even at a seam.
 local bottom=z-half+.1;local heights,seen,rows={},{},{}
 for _,px in ipairs({x-half+.1,x+half-.1})do
  for _,py in ipairs({y-half+.1,y+half-.1})do
   for _,pz in ipairs({bottom,z+half-.1})do
    local r=self.service.read_world(px,py,pz)
    if fluids.kind(r)==fluids.water and not seen[r.id or r]then
     seen[r.id or r]=true
     local kind,top=self:_point(px,py,math.max(bottom,r.z-50+.001),heights)
     if kind=='water'then rows[#rows+1]={flow=self:_flow(r),depth=(top-bottom)/100}end
    end
   end
  end
 end
 if #rows>0 then return flow.average(rows)end
end
function Contact:_sample(s,now)
 local location=point(s.row.actor:K2_GetActorLocation());local size=self:_dimensions(s,now)
 local feet=location.Z-size.half+.1;local eye=location.Z+size.half*.74
 local radius=size.radius*.85;local kind,surface,water,lava
 local heights={};local touched={};local currents={water={},lava={}}
 local function touch(found,top,record)
  if not record then return end
  local k=record.id or record.x..':'..record.y..':'..record.z
  if not touched[k]then
   touched[k]=true;currents[found][#currents[found]+1]={flow=self:_flow(record),depth=math.max(0,(top-feet)/100)}
  end
 end
 -- Fixed eleven points, independent of world size. Feet+body edge checks
 -- catch stepping into a side cell; eye contact controls submerged rendering.
 for _,z in ipairs({feet,location.Z}) do
  for _,offset in ipairs(offsets) do
   local found,top,record=self:_point(location.X+offset[1]*radius,location.Y+offset[2]*radius,z,heights)
   if found then
    touch(found,top,record)
    if found=='lava' then lava=true else water=true end
    if not kind or found=='lava' and kind~='lava' then kind=found;surface=top
    elseif kind==found then surface=math.max(surface,top) end
   end
  end
 end
 local eye_kind,eye_surface,eye_record=self:_point(location.X,location.Y,eye,heights)
 if eye_kind then
  touch(eye_kind,eye_surface,eye_record)
  if eye_kind=='lava' then lava=true else water=true end
  if not kind or eye_kind=='lava' then kind=eye_kind;surface=math.max(surface or eye_surface,eye_surface) end
 end
 self.report.samples=self.report.samples+1
 return {kind=kind,submerged=kind~=nil and eye_kind==kind,depth=surface and math.max(0,math.min(1,(surface-feet)/(size.half*2))) or 0,
  surface_z=surface,water_contact=water==true,lava_contact=lava==true,location=location,
  flow=kind and flow.average(currents[kind])or nil}
end
function Contact:_snapshot(sample,s,now,active)
 local out=self.snapshot;local params=sample.kind and fluids.contact[sample.kind] or nil
 out.kind=sample.kind;out.submerged=sample.submerged;out.depth=sample.depth
 out.surface_z=sample.surface_z;out.water_contact=sample.water_contact;out.lava_contact=sample.lava_contact
 out.flow=sample.flow
 out.at=now;out.valid_until=now+M.PLAYER_INTERVAL*2.5;out.active=active
 out.burning=s and s.burn_until>now or false;out.burn_until=s and s.burn_until or 0
 out.horizontal_drag=params and params.horizontal_drag or nil;out.sprint_drag=params and params.sprint_drag or nil
 out.vertical_drag=params and (sample.kind=='lava' and
  (sample.depth<=.4 and params.shallow_vertical_drag or params.deep_vertical_drag) or params.vertical_drag) or nil
 out.input_acceleration=params and params.input_acceleration or nil;out.jump_impulse=params and params.jump_impulse or nil
end
function Contact:_status_ready()
 local status=self.binding.mc_status_service
 if not status or status.binding~=self.binding or not status:current() then return false end
 local session=status.session
 return session and not session.restart_frozen and session.session and not session.session.busy
  and not session.session.quarantined or false
end
function Contact:_hit(damage,s,sample,now,fraction,interval)
 if now+1e-7<s.next_hit then return end
 -- Claim the interval BEFORE native dispatch. Exceptions after native damage
 -- are never retried as the same hit, and a long stall never catches up bursts.
 s.next_hit=now+interval;self.sequence=self.sequence+1
 local ok,why=pcall(function()
  if not damage or not damage:is_current() or not self:_status_ready() or not damage:eligible(s.row) then return end
  local maximum=attribute(s.row.actor,'Health_Max');local attack=attribute(self.binding.actor,'Attack')
  assert(maximum and maximum>0 and attack and attack>0,'fluid-contact-attributes-unavailable')
  local desired=maximum*fraction;local amount=math.min(desired,10000,attack*1000)
  assert(finite(amount) and amount>0,'fluid-contact-damage-range')
  local action=self.action_prefix..self.sequence..'/'..key(s.row.id)
  self.report.attempts=self.report.attempts+1
  if amount<desired then self.report.clamped=self.report.clamped+1 end
  local receipt=damage:hit(s.row,amount,action,'fire',sample.location,{X=0,Y=0,Z=1})
  self.report.last_hit={action_id=action,target=s.row.id.name,player=s.row.player==true,
   requested=amount,unclamped=desired,clamped=amount<desired,kind=sample.kind or 'afterburn',receipt=receipt}
  if receipt and receipt.dispatched then self.report.dispatched=self.report.dispatched+1 end
 end)
 if not ok then self:_error(why) end
end
function Contact:_process(row,damage,now)
 local s=self:_state(row,now);local sample=self:_sample(s,now)
 s.sample=sample;s.flow_until=now+(row.player and M.PLAYER_INTERVAL*2.5 or M.ENEMY_INTERVAL*1.3)
 if not row.player and sample.flow and sample.flow.x^2+sample.flow.y^2+sample.flow.z^2>1e-10 then
  local k=key(row.id)
  if not self.flow_slots[k]then
   local slot=#self.flowing<M.MAX_ENEMY_CHECKS and #self.flowing+1 or self.flow_cursor
   local old=self.flowing[slot];if old then self.flow_slots[key(old.row.id)]=nil end
   self.flowing[slot]=s;self.flow_slots[k]=slot;self.flow_cursor=slot%M.MAX_ENEMY_CHECKS+1
  else self.flowing[self.flow_slots[k]]=s end
 end
 if sample.kind=='water' then
  s.burn_until=0;s.next_hit=now;s.last_kind='water'
 elseif sample.kind=='lava' then
  s.burn_until=now+fluids.contact.lava.ignite_ticks/20
  self:_hit(damage,s,sample,now,fluids.contact.lava.damage_health_units*fluids.contact.lava.health_unit_fraction,.5)
  s.last_kind='lava'
 elseif s.burn_until>now then
  if s.last_kind=='lava' then s.next_hit=math.max(s.next_hit,now+1) end
  s.last_kind=nil;self:_hit(damage,s,sample,now,1/20,1)
 else s.burn_until=0;s.last_kind=nil end
 if row.player then self:_snapshot(sample,s,now,true) end
 return sample
end
function Contact:fluid_actor(actor)
 if not self:_current()or not valid(actor)then return end
 local world=self.service.world
 local handle=type(world)=='table'and world.by_actor and world.by_actor[actor:GetFullName()]
 if handle and handle.identity and identity.matches(actor,handle.identity)and fluids.kind(handle.record)then return handle.record end
end
function Contact:_push(s,now)
 if not s or not s.sample or now>(s.flow_until or 0)then return end
 local sample=s.sample;local current=sample.flow
 if not sample.kind or not current or current.x^2+current.y^2+current.z^2<1e-10 then return end
 local row=s.row;local actor=row.actor
 if not valid(actor)or not identity.matches(actor,row.id)or (attribute(actor,'Health')or 0)<=0 then return end
 -- A passenger is moved only through its boat; otherwise two native owners
 -- would fight the seat pin. The MC player integrates current with its drag.
 if row.player then
  if self.binding.mc_boat_riding or self.binding.mc_creative_flight then return end
  local owner=self.binding.mc_movement_owner
  if owner and not owner.closed and owner.focused then return end
 end
 local boats=package.loaded['host.pbz.boat_service']
 local boat=boats and boats.get(self.binding)
 if boat and boat.passengers[tostring(row.id.address)..':'..row.id.name]then return end
 self.report.flow_checked=self.report.flow_checked+1
 local velocity=actor:GetVelocity();local impulse=flow.impulse(current,sample.kind,velocity,row.player)
 -- Native PBZ air movement has no MC liquid drag. Keep its vertical combat /
 -- gravity velocity, while bounding horizontal current at the MC equilibrium.
 local drag=sample.kind=='water'and .8 or .5
 impulse.X=(velocity.X+impulse.X)*drag-velocity.X
 impulse.Y=(velocity.Y+impulse.Y)*drag-velocity.Y
 actor:LaunchCharacter(impulse,false,false)
 self.report.flow_pushes=self.report.flow_pushes+1
end
-- Fixed five footprint samples. Return only MC water; native terrain support
-- remains owned by boat_world. No physics object or world-table scan occurs.
function Contact:boat_surface(p)
 if not self:_current()then return end
 local heights={};local rows={};local seen={};local level;local underwater=true;local falling=false
 for _,d in ipairs(offsets)do
  local x,y=p.x+d[1]*60,p.y+d[2]*60
  local kind,top,record=self:_point(x,y,p.z+.1,heights)
  if kind=='water'then
   level=math.max(level or top,top);falling=falling or fluids.falling(record)
   if top<p.z+56.25 then underwater=false end
   local k=record.id or record.x..':'..record.y..':'..record.z
   if not seen[k]then seen[k]=true;rows[#rows+1]={flow=self:_flow(record),depth=(top-p.z)/100}end
  else underwater=false end
 end
 if not level then return end
 return {kind='water',water_level=level,friction=underwater and not falling and .45 or .9,
  underwater=underwater,falling=falling,flow=flow.average(rows)}
end
function Contact:water_target(start,finish)
 if not self:_current()or finish.Z>=start.Z then return end
 local seen={};local best
 -- Boat reach is 500cm. This is at most21 pure indexed reads, not ray traces
 -- or a fluid/boat world scan; exact top-plane intersection follows discovery.
 for i=0,20 do
  local t=i/20
  local r=self.service.read_world(start.X+(finish.X-start.X)*t,start.Y+(finish.Y-start.Y)*t,
    start.Z+(finish.Z-start.Z)*t)
  if fluids.kind(r)==fluids.water and not seen[r.id or r]then
   seen[r.id or r]=true
   local above=self.service.read_world(r.x,r.y,r.z+100)
   local top=r.z-50+fluids.height(r,above)*100
   local hit=(top-start.Z)/(finish.Z-start.Z)
   local x,y=start.X+(finish.X-start.X)*hit,start.Y+(finish.Y-start.Y)*hit
   if hit>=0 and hit<=1 and math.abs(x-r.x)<=50 and math.abs(y-r.y)<=50 and (not best or hit<best.t)then
    best={X=x,Y=y,Z=top,t=hit}
   end
  end
 end
 return best
end
function Contact:tick(now)
 if self.closed then return self.report end
 assert(finite(now) and now>=0,'fluid-contact-clock')
 local ok,current=pcall(self._current,self)
 if not ok or not current then self:close();return self.report end
 -- Game-time rewind is a scene/load boundary, not permission to replay hits.
 if self.last_time and now<self.last_time then self:close();return self.report end
 self.last_time=now
 if now+1e-7<self.next_player and now+1e-7<self.next_enemies and now+1e-7<self.next_flow then return self.report end
 local paused_ok,paused=pcall(self.clock.IsGamePaused,self.clock,self.binding.actor)
 if not paused_ok or paused then
  -- Pause changes eligibility only; it must not extinguish a live burn or
  -- reset the already claimed hit interval when the same scene resumes.
  self.snapshot.active=false;self.snapshot.at=now;self.snapshot.valid_until=now+M.PLAYER_INTERVAL*2.5
  self.next_player=now+M.PLAYER_INTERVAL;self.next_enemies=now+M.ENEMY_INTERVAL
  self.next_flow=now+M.FLOW_INTERVAL
  return self.report
 end
 if (attribute(self.binding.actor,'Health') or 0)<=0 then
  self.states={};self.order={};self.next_slot=1;self.flowing={};self.flow_slots={}
  self.player_state=nil
  self:_snapshot({kind=nil,submerged=false,depth=0},nil,now,false)
  self.next_player=now+M.PLAYER_INTERVAL;self.next_enemies=now+M.ENEMY_INTERVAL
  self.next_flow=now+M.FLOW_INTERVAL
  return self.report
 end
 local service=tnt.get(self.binding);local damage=service and not service.closed and service.damage or nil
 self.report.damage_ready=damage~=nil
 if now+1e-7>=self.next_enemies then
  self.next_enemies=now+M.ENEMY_INTERVAL
  if damage and self:_status_ready() then
   local found,rows=pcall(damage.candidates,damage,'fire')
   if found and type(rows)=='table' and #rows>0 then
    local inspected=0
    while inspected<math.min(M.MAX_ENEMY_CHECKS,#rows) do
     if self.enemy_cursor>#rows then self.enemy_cursor=1 end
     local row=rows[self.enemy_cursor];self.enemy_cursor=self.enemy_cursor+1;inspected=inspected+1
     if row and not row.player and row.id and not identity.matches(row.actor,self.pawn_id) then
      local eligible,yes=pcall(damage.eligible,damage,row)
      if eligible and yes then
       self.report.enemy_checks=self.report.enemy_checks+1
       local sampled,why=pcall(self._process,self,row,damage,now)
       if not sampled then self:_error(why) end
      elseif row.id then
       local stale=self.states[key(row.id)]
       if stale then stale.burn_until=0;stale.last_kind=nil end
      end
     end
    end
    self.report.candidate_count=#rows;self.report.candidates_checked=inspected
   elseif not found then self:_error(rows) end
  end
 end
 -- As in the shared TNT adapter, dispatch player self-damage last. A fatal
 -- self-hit must not invalidate the source before this pass's hostile hits.
 if now+1e-7>=self.next_player then
  self.next_player=now+M.PLAYER_INTERVAL
  local sampled,why=pcall(self._process,self,self.player,damage,now)
  if not sampled then self:_error(why);self:_snapshot({kind=nil,submerged=false,depth=0},nil,now,false) end
 end
 if now+1e-7>=self.next_flow then
  self.next_flow=now+M.FLOW_INTERVAL -- no catch-up burst after a stall
  for _,s in ipairs(self.flowing)do
   local pushed,why=pcall(self._push,self,s,now);if not pushed then self:_error(why)end
  end
  local pushed,why=pcall(self._push,self,self.player_state,now);if not pushed then self:_error(why)end
 end
 return self.report
end
function Contact:close()
 if self.closed then return end
 if self.binding.mc_fluid_contact==self.snapshot then self.binding.mc_fluid_contact=nil end
 if self.binding.mc_fluid_sampler==self then self.binding.mc_fluid_sampler=nil end
 self.closed=true;self.states={};self.order={};self.flowing={};self.flow_slots={};self.player=nil;self.player_state=nil
end
return M
