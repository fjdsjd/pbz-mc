-- Ground boats share the campaign checkpoint. Seats are runtime-only leases;
-- no native pointers, frozen enemies or live velocity enter a save file.
local rules=require('rules.boat')
local identity=require('host.pbz.object_identity')
local state=require('storage.state')
local campaign=require('host.pbz.campaign_inventory')
local M={};local Service={};Service.__index=Service
local active,handoff
local WAKE_DISTANCE,SLEEP_DISTANCE=6000,8000
local function valid(o)return o and o:IsValid() end
local function finite(n)return type(n)=='number'and n==n and math.abs(n)<math.huge end
local function equal(a,b)
  for id,r in pairs(a or {})do
    local s=b and b[id];if not s then return false end
    for k,v in pairs(r)do if s[k]~=v then return false end end
    for k,v in pairs(s)do if r[k]~=v then return false end end
  end
  for id in pairs(b or {})do if not a or not a[id]then return false end end
  return true
end
local function alive(actor)
  if not valid(actor)then return false end
  local ok,hp=pcall(function()return actor.AttributeSetBase.Health.CurrentValue end)
  return ok and type(hp)=='number' and hp>0
end
local function key(actor)local id=identity.capture(actor);return tostring(id.address)..':'..id.name end
local function time(binding)return StaticFindObject('/Script/Engine.Default__GameplayStatics'):GetTimeSeconds(binding.actor)end
function M.get(binding)return active and not active.closed and active.binding==binding and active or nil end
function Service:current()
  return not self.closed and self.binding:is_current() and campaign.current(self.binding)
    and not self.session.restart_frozen
end
function Service:report(event,detail)
  self.last_event=event;self.last_detail=detail;self.log('boat '..event..(detail and ' '..tostring(detail)or ''))
end
function Service:observer_position()
  local ok,p=pcall(self.binding.actor.K2_GetActorLocation,self.binding.actor)
  self.observer=ok and p and finite(p.X)and finite(p.Y)and finite(p.Z)
    and {x=p.X,y=p.Y,z=p.Z}or nil
end
function Service:near(p,radius)
  local q=self.observer
  if not q or not p then return false end
  local x,y,z=p.x-q.x,p.y-q.y,p.z-q.z
  return finite(x)and finite(y)and finite(z)and x*x+y*y+z*z<=radius*radius
end
function Service:sleep(boat,reason,why)
  local first=boat.dormant_reason~=reason or boat.simulation_error~=why
  if not first then return end
  boat.dormant_reason=reason;boat.simulation_error=why
  local s=boat.state;s.vx=0;s.vy=0;s.vz=0;s.delta_yaw=0
  s.paddling={left=false,right=false};boat.animated=false;boat.surface=nil
  if why and first then self:report('boat-isolated',boat.handle.id..' '..tostring(why))end
end
function Service:awake(boat)
  if boat.simulation_error then return false end
  if self.driver~=boat and not self:near(boat.state,boat.dormant_reason and WAKE_DISTANCE or SLEEP_DISTANCE)then
    self:sleep(boat,self.observer and 'distance' or 'observer-unavailable');return false
  end
  if boat.dormant_reason then
    boat.dormant_reason=nil;boat.resting=false;boat.next_sim_at=0;boat.support_at=0;boat.rendered=false
  end
  return true
end
function Service:restore_nearby(now)
  if now>=(self.deferred_at or 0)then
    self.deferred_at=now+1
    for id,entry in pairs(self.deferred)do
      local record=self.records[id]
      if record and now>=(entry.retry_at or 0)and self:near(record,WAKE_DISTANCE)then
        self.pending[#self.pending+1]=id;self.deferred[id]=nil
      end
    end
  end
  -- A distant or malformed spawn must not block every following saved boat.
  for _=1,math.min(2,#self.pending)do
    local id=table.remove(self.pending,1);local record=self.records[id]
    if record then
      if not self:near(record,WAKE_DISTANCE)then
        self.deferred[id]={reason=self.observer and 'distance' or 'observer-unavailable'}
      else
        local ok,handle,why=pcall(self.world.spawn,self.world,record)
        if ok and handle then self.boats[id]={handle=handle,state=rules.new(record),leases={}}
        else
          local reason=tostring(ok and why or handle);self.restore_error=reason
          self.deferred[id]={reason='spawn-unavailable',detail=reason,retry_at=now+2}
        end
      end
    end
  end
end
function Service:isolate(boat,why)
  self:sleep(boat,'simulation-error',tostring(why))
  if self.driver==boat then self.input={}end
end
function Service:maintain_dormant(boat,now)
  if now<(boat.lease_check_at or 0)then return end;boat.lease_check_at=now+1
  local release={}
  for rider,lease in pairs(boat.leases)do
    if boat.simulation_error or not lease:is_current()or not alive(lease.actor)then release[#release+1]=rider end
  end
  for _,rider in ipairs(release)do self:release(boat,rider,'dormant-cleanup',false)end
end
function Service:commit(records)
  if not self:current() then return false,'boat-campaign-unavailable' end
  local s=self.session
  if s.session.busy then return false,'boat-inventory-busy' end
  if not equal(s.store.core.vehicles,self.baseline)then return false,'boat-records-changed' end
  local ticket=s.store:checkout({});local candidate=state.object()
  for k,v in pairs(ticket.data)do candidate[k]=v end
  candidate.vehicles=state.clone(records)
  local ok,why=s.session:commit(ticket,candidate)
  if ok then self.baseline=state.clone(records);self.records=records;self.dirty=false;self.commits=self.commits+1 end
  return ok,why
end
function Service:flush_memory()
  if not self.dirty then return true end
  local ok,why=self:commit(self.records);assert(ok,why);return true
end
function Service:aim()
  local pc=self.binding.actor.Controller
  assert(valid(pc) and valid(pc.PlayerCameraManager),'boat-controller-unavailable')
  local view=pc.PlayerCameraManager.CameraCachePrivate.POV
  local origin={X=view.Location.X,Y=view.Location.Y,Z=view.Location.Z}
  local direction=require('presentation.native_steve_pose').axes(view.Rotation)
  -- Reach starts at the character's eyes in PBZ's third-person camera.
  if identity.matches(pc.PlayerCameraManager.ViewTarget.Target,self.binding.actor_id)then
    local p=self.binding.actor:K2_GetActorLocation()
    local eye={X=p.X,Y=p.Y,Z=p.Z+self.binding.actor.CapsuleComponent:GetScaledCapsuleHalfHeight()*.74}
    local ray={X=origin.X+direction.X*10000,Y=origin.Y+direction.Y*10000,Z=origin.Z+direction.Z*10000}
    local hit,color={},{R=0,G=0,B=0,A=0}
    if require('UEHelpers').GetKismetSystemLibrary():LineTraceSingle(self.binding.actor,origin,ray,0,false,
      {self.binding.actor},0,hit,true,color,color,0)then ray=hit.ImpactPoint end
    local x,y,z=ray.X-eye.X,ray.Y-eye.Y,ray.Z-eye.Z;local length=math.sqrt(x*x+y*y+z*z)
    if length>1 and x*direction.X+y*direction.Y+z*direction.Z>0 then direction={X=x/length,Y=y/length,Z=z/length}end
    origin=eye
  end
  return origin,direction
end
function Service:place(aim)
  if not self:current() or self.binding.mc_boat_riding then return false end
  local now=time(self.binding)
  if now<(self.next_place or 0)then return false end
  self.next_place=now+.25
  local count=0;for _ in pairs(self.records)do count=count+1 end
  if count>=128 then self:report('placement-rejected','boat-limit-128');return false end
  local pose,why=self.world:placement(aim)
  if not pose then self:report('placement-rejected',why);return false end
  self.serial=self.serial+1
  local id='boat:'..tostring(self.session.store.generation+1)..':'..tostring(self.serial)
  while self.records[id]do self.serial=self.serial+1;id='boat:'..tostring(self.session.store.generation+1)..':'..self.serial end
  local record={id=id,content_id=rules.id,world=self.world_id,x=pose.x,y=pose.y,z=pose.z,yaw=pose.yaw}
  local handle,err=self.world:spawn(record)
  if not handle then self:report('placement-rejected',err);return false end
  local records=state.clone(self.records);records[id]=record
  local ok,reason=self:commit(records)
  if not ok then self.world:destroy(handle);self:report('placement-rollback',reason);return false end
  self.boats[id]={handle=handle,state=rules.new(record),leases={}}
  self.placed=self.placed+1;self.last_id=id;self:report('placed',id);return true
end
function Service:capture(boat,actor,kind,now)
  if boat.simulation_error or (kind~='player'and boat.dormant_reason)then return false,'boat-dormant' end
  if #boat.state.riders>=2 or self.passengers[key(actor)]then return false,'boat-full-or-already-riding' end
  if kind=='player'and self.binding.mc_creative_flight then self.binding.mc_creative_flight:stop('boarded')end
  local passenger,why,failed=require('host.pbz.boat_passenger').acquire(actor,kind,now)
  if not passenger then
    if failed then self.cleanup[#self.cleanup+1]=failed end
    return false,why
  end
  local rider=key(actor);local index,err=rules.board(boat.state,rider,kind)
  if not index then
    local ok=passenger:release(alive(actor));if not ok then self.cleanup[#self.cleanup+1]=passenger end
    return false,err
  end
  boat.leases[rider]=passenger;self.passengers[rider]=boat
  boat.pin_at=0;boat.resting=false
  if kind=='player'then
    self.driver=boat;self.binding.mc_boat_riding={id=boat.handle.id,yaw=boat.state.yaw}
    self.input={};self.previous_keys=0
    if self.binding.mc_status then self.binding.mc_status.riding=true end
  end
  self.captured=self.captured+1;self:report('boarded',kind..' '..boat.handle.id..' seat='..index)
  return true
end
function Service:release(boat,rider,reason,exit)
  local lease=boat.leases[rider];if not lease then return true end
  -- A partially restored lease deliberately reports is_current=false. That
  -- does not mean the actor died; retain live AI restoration on a later retry.
  local living=identity.matches(lease.actor,lease.id) and alive(lease.actor)
  if exit and living and self.world:valid(boat.handle)then
    local position,why=self.world:exit_position(boat.handle,lease.actor,lease.capsuleHalfHeight)
    if not position then return false,why or 'boat-no-safe-exit' end
    local ok,err=pcall(lease.pin,lease,position,boat.state.yaw,time(self.binding))
    if not ok or err==false then return false,'boat-exit-position-failed' end
  end
  local ok,why=lease:release(living)
  if not ok then return false,why end
  rules.unboard(boat.state,rider);boat.leases[rider]=nil;self.passengers[rider]=nil
  boat.pin_at=0;boat.resting=false
  self.released[rider]=(self.now or 0)+2
  if self.driver==boat and identity.matches(lease.actor,self.binding.actor_id)then
    self.driver=nil;self.binding.mc_boat_riding=nil;self.input={}
    if self.binding.mc_status then self.binding.mc_status.riding=false end
  end
  self:report('released',reason..' '..boat.handle.id);return true
end
function Service:interact(aim)
  if not next(self.boats) or not self:current() then return false end
  local handle=self.world:target(aim,500);if not handle then return false end
  if self.driver then return false end
  local boat=self.boats[handle.id];if not boat then return false end
  if #boat.state.riders>=2 then self:report('board-rejected','two-seats-occupied');return true end
  local ok,why=self:capture(boat,self.binding.actor,'player',time(self.binding))
  if not ok then self:report('board-rejected',why)end
  return true
end
function Service:dismount()
  if not self.driver then return false end
  local ok,why=self:release(self.driver,key(self.binding.actor),'dismount',true)
  if ok then self:flush_memory()else self:report('dismount-rejected',why)end
  return ok,why
end
function Service:leave_for_teleport()
  if not self.driver then return true end
  -- Called only after the pearl's destination and native move both passed.
  -- Releasing a seat must not reposition the player back onto the old shore.
  return self:release(self.driver,key(self.binding.actor),'ender-pearl',false)
end
function Service:remove(boat,reason)
  -- Release leases before discarding the world object. A failed restore keeps
  -- the boat present, quarantined, and retryable instead of losing ownership.
  local keys={};for rider in pairs(boat.leases)do keys[#keys+1]=rider end
  for _,rider in ipairs(keys)do
    local ok,why=self:release(boat,rider,reason,false)
    if not ok then boat.remove_error=why;return false,why end
  end
  local records=state.clone(self.records);records[boat.handle.id]=nil
  local ok,why=self:commit(records)
  if not ok then boat.remove_error=why;return false,why end
  local destroyed,err=self.world:destroy(boat.handle)
  if destroyed==false then
    -- Retain the handle for cleanup; its record is already removed. Never
    -- recreate/reward the item after a committed removal.
    boat.retired=true;boat.remove_error=err;return false,err
  end
  self.boats[boat.handle.id]=nil;self.removed=self.removed+1;self:report('removed',boat.handle.id)
  return true
end
function Service:attack(record,aim)
  if not next(self.boats) or not self:current() then return false,false end
  local handle=self.world:target(aim,500);local boat=handle and self.boats[handle.id]
  if not boat then return false,false end
  if self.driver==boat then return true,false end -- A rider cannot hit its vehicle.
  local now=record.now or time(self.binding)
  if now<(boat.next_hit or 0)then return true,false end
  boat.next_hit=now+.2
  local main=record.equipment and record.equipment.main
  local native=require('rules.native_slot_reference').is(main)
  local profile=require('content.combat_profiles').get(not native and main and main.content_id or nil)
  local strength=math.max(0,math.min(1,record.strength or 1))
  local amount=profile.free_melee_damage*(.2+.8*strength*strength)
  local destroyed=rules.hit(boat.state,amount)
  boat.resting=false
  self.hits=self.hits+1;self:report('hit',handle.id..' amount='..amount..' damage='..boat.state.damage)
  if destroyed then self:remove(boat,'broken')end
  return true,true
end
function Service:input_batch(batch,allowed,group,data)
  local p=batch.latest;local usable=allowed and p and p.focused and not batch.overflow
  if not usable then self.input={};self.pointer_stamp=nil;self.previous_keys=0;self.previous_buttons=0;return end
  local stamp=tostring(p.epoch)..':'..tostring(batch.context)
  local baseline=self.pointer_stamp~=stamp;self.pointer_stamp=stamp
  local keys=(p.keys or 0)&~(batch.blocked_keys or 0)
  local buttons=p.buttons or 0
  self.input={forward=(keys&(1<<14))~=0,left=(keys&(1<<15))~=0,back=(keys&(1<<16))~=0,right=(keys&(1<<17))~=0}
  if self.driver and not baseline and (keys&(1<<19))~=0 and (self.previous_keys&(1<<19))==0 then self:dismount()end
  -- Native equipment keeps native attacks on foot. Only the entity under the
  -- reticle participates in boat hit/use; no second enemy-damage path exists.
  if group=='pbz' and not baseline then
    local aim=function()return self:aim()end
    if (buttons&2)~=0 and (self.previous_buttons&2)==0 then self:interact(aim)end
    if (buttons&1)~=0 then
      local selected=data and require('rules.container_slots').get(data,'player/hotbar/'..data.player.selected)
      self:attack({now=time(self.binding),strength=1,equipment={main=selected}},aim)
    end
  end
  self.previous_keys=keys;self.previous_buttons=buttons
end
local function capture_candidate(self,actor,region,now)
  if not valid(actor) or identity.matches(actor,self.binding.actor_id) or not identity.matches(actor:GetWorld(),self.binding.world_id)then return end
  local p=actor:K2_GetActorLocation()
  if not p or not finite(p.X)or not finite(p.Y)or not finite(p.Z)then return end
  local rider=key(actor)
  if self.passengers[rider] or (self.released[rider]or 0)>now or not alive(actor) or not actor.bCanBeDamaged then return end
  local capsule=actor.CapsuleComponent;if not valid(capsule)then return end
  local half,radius=capsule:GetScaledCapsuleHalfHeight(),capsule:GetScaledCapsuleRadius()
  self.faction=self.faction or StaticFindObject('/Script/SGameCombatSystem.Default__FactionUtils')
  if not valid(self.faction) or self.faction:GetFactionRelation(self.binding.actor,actor)~=2 then return end
  for _,boat in ipairs(region)do
    local s=boat.state;local dx,dy=p.X-s.x,p.Y-s.y
    if self.boats[boat.handle.id]==boat and not boat.dormant_reason and not s.destroyed and not boat.retired
        and #s.riders<2 and dx*dx+dy*dy<=220*220 then
      local angle=math.rad(s.yaw)
      local x=dx*math.cos(angle)+dy*math.sin(angle);local y=-dx*math.sin(angle)+dy*math.cos(angle)
      if math.abs(x)<=95+radius and math.abs(y)<=65+radius
          and p.Z-half<=s.z+56.25 and p.Z+half>=s.z then return boat,rider end
    end
  end
end
function Service:scan(now)
  local regions=self.capture_regions
  if not regions then
    regions={};local by_cell={}
    for _,boat in pairs(self.boats)do
      local s=boat.state
      if not boat.dormant_reason and not s.destroyed and not boat.retired and #s.riders<2 then
        local cell=math.floor(s.x/800)..':'..math.floor(s.y/800)..':'..math.floor(s.z/400)
        local region=by_cell[cell]
        if not region then
          region={x0=s.x,x1=s.x,y0=s.y,y1=s.y,z0=s.z,z1=s.z};by_cell[cell]=region;regions[#regions+1]=region
        end
        region.x0=math.min(region.x0,s.x);region.x1=math.max(region.x1,s.x)
        region.y0=math.min(region.y0,s.y);region.y1=math.max(region.y1,s.y)
        region.z0=math.min(region.z0,s.z);region.z1=math.max(region.z1,s.z)
        region[#region+1]=boat
      end
    end
    self.capture_regions=regions;self.capture_index=1
  end
  -- Spread distant groups across frames. Neighbouring hulls share one native
  -- overlap. Already full, removed or moving hulls are checked at capture time.
  for i=self.capture_index,math.min(self.capture_index+1,#regions)do
    local region=regions[i]
    for _,wrapped in ipairs(self.world:characters_near_boats(region))do
      local actor=wrapped:get()
      local ok,boat,rider=pcall(capture_candidate,self,actor,region,now)
      if ok and boat then
        if self.world:valid(boat.handle)then
          local yes,why=self:capture(boat,actor,'mob',now)
          if not yes then self.released[rider]=now+2;self:report('capture-rejected',why)end
        else boat.state.destroyed=true;boat.resting=false end
      end
    end
    self.capture_index=i+1
  end
  if self.capture_index>#regions then self.capture_regions=nil end
end
function Service:pin(boat,now)
  local remove={}
  for i,rider in ipairs(boat.state.riders)do
    local lease=boat.leases[rider.key]
    if not lease or not lease:is_current() or not alive(lease.actor)then remove[#remove+1]=rider.key
    else
      local offset=rules.offset(boat.state,i);local angle=math.rad(boat.state.yaw)
      local position={X=boat.state.x+offset.x*math.cos(angle),Y=boat.state.y+offset.x*math.sin(angle),
        Z=boat.state.z+offset.z+lease.capsuleHalfHeight}
      local ok,why=lease:pin(position,boat.state.yaw,now)
      if ok==false then boat.pin_error=why;remove[#remove+1]=rider.key end
    end
  end
  for _,rider in ipairs(remove)do self:release(boat,rider,'invalid-or-dead',false)end
  if self.driver==boat then self.binding.mc_boat_riding.yaw=boat.state.yaw end
end
function Service:external_push_owner(actor)
  if not valid(actor)then return end
  local passenger=self.passengers[key(actor)]
  if passenger then return passenger.handle.actor end
  local handle=self.world.by_actor and self.world.by_actor[actor:GetAddress()]
  if handle and self.boats[handle.id]and identity.matches(actor,handle.identity)then return handle.actor end
end
function Service:spear_seat(actor)
  if not next(self.passengers)then return end
  local rider=key(actor)
  local boat=self.passengers[rider]
  if boat and boat.leases[rider] and boat.leases[rider]:is_current() then return boat,rider end
end
-- The seat, including equipment attached to its occupant, is not another
-- piston body. Match a current lease; an empty hull or released mob must
-- continue through the ordinary collision checks.
function Service:piston_rider(actor)
  if not next(self.passengers)then return false end
  for _=1,5 do
    if not valid(actor)then return false end
    local rid=key(actor);local boat=self.passengers[rid]
    local lease=boat and boat.leases[rid]
    if lease and not boat.retired and not boat.state.destroyed and lease:is_current()then return true end
    actor=actor:GetAttachParentActor()
  end
  return false
end
local function hull_intersects(h,box)
  local b=h.bounds
  if b.max.X<=box.min.X or b.min.X>=box.max.X or b.max.Y<=box.min.Y or b.min.Y>=box.max.Y
      or b.max.Z<=box.min.Z or b.min.Z>=box.max.Z then return false end
  local hx,hy=(box.max.X-box.min.X)*.5,(box.max.Y-box.min.Y)*.5
  local dx,dy=box.min.X+hx-h.x,box.min.Y+hy-h.y
  return math.abs(dx*h.c+dy*h.s)<rules.width*.5+hx*math.abs(h.c)+hy*math.abs(h.s)
    and math.abs(dy*h.c-dx*h.s)<rules.width*.5+hy*math.abs(h.c)+hx*math.abs(h.s)
end
function Service:external_push_candidates(box)
  local out={};if not self:current()then return out end
  assert(box and box.min and box.max,'boat-external-bounds-required')
  for _,boat in pairs(self.boats)do
    if not boat.retired and not boat.dormant_reason and not boat.state.destroyed then
      local p=boat.state;local angle=math.rad(p.yaw)
      local c,s=math.cos(angle),math.sin(angle)
      local radius=rules.width*.5
      local half=radius*(math.abs(c)+math.abs(s))
      local bounds={min={X=p.x-half,Y=p.y-half,Z=p.z},max={X=p.x+half,Y=p.y+half,Z=p.z+rules.height}}
      local h={actor=boat.handle.actor,bounds=bounds,x=p.x,y=p.y,c=c,s=s,intersects=hull_intersects}
      if h:intersects(box) and self.world:valid(boat.handle)then out[#out+1]=h end
    end
  end
  return out
end
function Service:wind_burst(origin,radius,visible)
  local wind=require('rules.wind_charge')
  local pushed=0
  for _,boat in pairs(self.boats) do
    local s=boat.state
    if not boat.retired and not boat.dormant_reason and not s.destroyed then
      local impulse=wind.impulse(origin,{X=s.x,Y=s.y,Z=s.z},rules.width*.5,rules.height*.5,radius,wind.multiplier,1)
      if impulse and self.world:valid(boat.handle) and visible(origin,{X=s.x,Y=s.y,Z=s.z+rules.height*.5},boat.handle.actor) then
        -- Boat velocities use cm/tick. Its own solver moves the seated group.
        s.vx=s.vx+impulse.X/20;s.vy=s.vy+impulse.Y/20;s.vz=s.vz+impulse.Z/20
        boat.resting=false;pushed=pushed+1
      end
    end
  end
  return pushed
end
function Service:blast(origin,damage)
  local tnt=require('rules.tnt')
  local center={X=origin.x,Y=origin.y,Z=origin.z}
  for _,boat in pairs(self.boats)do
    local s=boat.state
    if not boat.retired and not boat.dormant_reason and not s.destroyed then
      local offset={x=s.x-origin.x,y=s.y-origin.y,z=s.z+rules.height*.5-origin.z}
      local blast=tnt.blast(math.sqrt(offset.x^2+offset.y^2+offset.z^2))
      if blast and blast.impulse>0 and self.world:valid(boat.handle) and damage:clear_line(center,
          {X=s.x,Y=s.y,Z=s.z+rules.height*.5},boat.handle.actor)then
        local impulse=tnt.knockback(offset,blast.impulse)
        -- Boat motion is cm per game tick. Its usual swept move carries its seats.
        s.vx=s.vx+impulse.x/20;s.vy=s.vy+impulse.y/20;s.vz=s.vz+impulse.z/20
        boat.resting=false
      end
    end
  end
end
function Service:external_push_prepare(actor,delta,now,ignore_actors)
  local boat_service=self
  local ok,ticket,reason=pcall(function()
    assert(self:current(),'boat-external-owner-stale')
    local owner=self:external_push_owner(actor);if not owner then return nil,'boat-external-not-owned'end
    local handle=self.world.by_actor[owner:GetAddress()];local boat=self.boats[handle.id]
    assert(not boat.retired and not boat.dormant_reason and not boat.state.destroyed,'boat-external-unavailable')
    assert(finite(now)and now>=0,'boat-external-clock')
    local target,before=self.world:external_push_target(handle,delta,ignore_actors)
    if not target then return nil,before end
    local old_state=state.clone(boat.state);local old_record=state.clone(assert(self.records[handle.id]))
    local fields={'resting','surface','ground_surface','next_sim_at','support_at','pin_at'};local old={}
    for _,name in ipairs(fields)do old[name]=boat[name]end
    local passengers={}
    for _,rider in ipairs(boat.state.riders)do
      local lease=assert(boat.leases[rider.key]);assert(lease:is_current(),'boat-external-passenger-stale')
      local p=lease.actor:K2_GetActorLocation();local r=lease.actor:K2_GetActorRotation()
      local radius=lease.actor.CapsuleComponent:GetScaledCapsuleRadius()
      local blocked=self.world:capsule_trace(p,{X=p.X+delta.X,Y=p.Y+delta.Y,Z=p.Z+delta.Z},
        radius,lease.capsuleHalfHeight,handle,lease.actor,ignore_actors)
      assert(not blocked,'boat-external-passenger-sweep-blocked')
      passengers[#passengers+1]={lease=lease,position={X=p.X,Y=p.Y,Z=p.Z},yaw=r.Yaw}
    end
    local transaction={owner=owner,before=before,after=target,applied=false,started=false,finished=false}
    local function move_passenger(row,position,yaw)
      local actor=row.lease.actor
      assert(identity.matches(actor,row.lease.id),'boat-external-passenger-identity')
      -- The ordinary lease:pin releases controls when a native call fails.
      -- A transaction must retain that lease until all actors can roll back.
      assert(actor:K2_SetActorLocationAndRotation(position,{Pitch=0,Yaw=yaw,Roll=0},false,{},true)==true,
        'boat-external-passenger-move-rejected')
      local observed=actor:K2_GetActorLocation()
      assert(math.abs(observed.X-position.X)+math.abs(observed.Y-position.Y)+math.abs(observed.Z-position.Z)<.05,
        'boat-external-passenger-readback-mismatch')
    end
    function transaction:apply()
      if self.applied then return true end
      local accepted,why=pcall(function()
        assert(not self.rolled_back and not self.finished,'boat-external-ticket-retired')
        assert(boat.state.x==old_state.x and boat.state.y==old_state.y and boat.state.z==old_state.z,'boat-external-state-changed')
        self.started=true -- wrappers may throw after moving the native actor
        local actual=boat_service.world:external_push_apply(handle,target)
        boat.state.x,boat.state.y,boat.state.z,boat.state.yaw=actual.x,actual.y,actual.z,actual.yaw
        for i,row in ipairs(passengers)do
          assert(row.lease:is_current(),'boat-external-passenger-changed')
          local offset=rules.offset(boat.state,i);local angle=math.rad(boat.state.yaw)
          local p={X=actual.x+offset.x*math.cos(angle),Y=actual.y+offset.x*math.sin(angle),
            Z=actual.z+offset.z+row.lease.capsuleHalfHeight}
          move_passenger(row,p,actual.yaw)
        end
        local record=boat_service.records[handle.id]
        record.x,record.y,record.z,record.yaw=actual.x,actual.y,actual.z,actual.yaw
        boat.resting=false;boat.surface=nil;boat.ground_surface=nil;boat.next_sim_at=0;boat.support_at=0;boat.pin_at=0
        if boat_service.driver==boat and boat_service.binding.mc_boat_riding then boat_service.binding.mc_boat_riding.yaw=actual.yaw end
        self.applied=true
      end)
      return accepted,not accepted and tostring(why)or nil
    end
    function transaction:rollback()
      if self.rolled_back or not self.started then self.rolled_back=true;return true end
      local accepted,why=pcall(function()
        boat_service.world:external_push_apply(handle,before)
        for _,row in ipairs(passengers)do
          move_passenger(row,row.position,row.yaw)
        end
        boat.state=state.clone(old_state);boat_service.records[handle.id]=state.clone(old_record)
        for _,name in ipairs(fields)do boat[name]=old[name]end
        if boat_service.driver==boat and boat_service.binding.mc_boat_riding then boat_service.binding.mc_boat_riding.yaw=before.yaw end
        self.rolled_back=true;self.applied=false
      end)
      return accepted,not accepted and tostring(why)or nil
    end
    function transaction:finish()
      assert(self.applied and not self.rolled_back,'boat-external-uncommitted')
      if not self.finished then boat_service.dirty=true;boat_service.moved_at=now;self.finished=true end
      return true
    end
    return transaction
  end)
  if not ok then return nil,tostring(ticket)end
  return ticket,reason
end
function Service:tick()
  if self.closed then return end
  if self.failed then M.close();return end
  if not next(self.boats) and #self.pending==0 and not next(self.deferred)
      and #self.cleanup==0 and not self.dirty and not self.driver then
    self.last_time=nil;self.capture_regions=nil
    self.idle_frames=(self.idle_frames or 0)+1
    if self.idle_frames%30==1 and not self:current()then M.close()end
    return
  end
  if not self:current()then M.close();return end
  local game=StaticFindObject('/Script/Engine.Default__GameplayStatics')
  if game:IsGamePaused(self.binding.actor)then self.input={};self.last_time=nil;return end
  local now=time(self.binding);self.now=now
  for i=#self.cleanup,1,-1 do local lease=self.cleanup[i];if lease:release(alive(lease.actor))then table.remove(self.cleanup,i)end end
  local camera=require('host.pbz.first_person_camera').get()
  if self.driver and (not alive(self.binding.actor) or camera and camera:native_takeover())then
    self:release(self.driver,key(self.binding.actor),'native-takeover-or-death',false);self.input={}
  end
  self:observer_position();self:restore_nearby(now)
  for _,boat in pairs(self.boats)do self:awake(boat)end
  local elapsed=self.last_time and math.max(0,math.min(.15,now-self.last_time))or 0;self.last_time=now
  self.accumulator=self.accumulator+elapsed
  local steps=math.min(3,math.floor(self.accumulator/.05));self.accumulator=self.accumulator-steps*.05
  local maintenance=2 -- Spread resting-boat support/ownership checks across frames.
  for _=1,steps do
    for id,boat in pairs(self.boats)do
      local s=boat.state;local input=self.driver==boat and self.input or {}
      local running=not boat.resting or s.damage>0 or s.hurt_ticks>0 or boat.animated
        or input.forward or input.back or input.left or input.right
      if not boat.dormant_reason and (running or now>=(boat.next_sim_at or 0)and maintenance>0)then
      local simulated,simulation_error=pcall(function()
      if not running then maintenance=maintenance-1 end
      boat.next_sim_at=now+1
      if boat.retired or boat.state.destroyed then self:remove(boat,'broken-retry')
      elseif not self.world:valid(boat.handle)then
        boat.state.destroyed=true;self:remove(boat,'native-removed')
      else
        local dynamic=self.driver==boat or math.abs(boat.state.vx)+math.abs(boat.state.vy)+math.abs(boat.state.vz)>.01
        if not boat.surface or dynamic or now>=(boat.support_at or 0)then
          boat.ground_surface=self.world:surface(boat.handle);boat.support_at=now+1
        end
        local surface=boat.ground_surface or boat.surface
        local sampler=self.binding.mc_fluid_sampler
        local water=sampler and sampler:boat_surface(boat.state)
        if water then water.ground_z=surface and surface.ground_z;surface=water end
        boat.surface=surface
        local frame=rules.step(boat.state,self.driver==boat and self.input or {},surface)
        local oldx,oldy,oldz,oldyaw=boat.state.x,boat.state.y,boat.state.z,boat.state.yaw
        local delta=math.abs(frame.x-oldx)+math.abs(frame.y-oldy)+math.abs(frame.z-oldz)+math.abs(frame.yaw-oldyaw)
        local pose,new_surface
        if delta>.001 then pose,new_surface=self.world:move(boat.handle,frame)
        else pose={x=oldx,y=oldy,z=oldz,yaw=oldyaw};boat.state.vx=0;boat.state.vy=0;boat.state.delta_yaw=0 end
        if new_surface then boat.ground_surface=new_surface end
        if pose then
          if math.abs(frame.x-pose.x)>.5 then boat.state.vx=0 end
          if math.abs(frame.y-pose.y)>.5 then boat.state.vy=0 end
          if math.abs(frame.z-pose.z)>.5 then boat.state.vz=0 end
          if math.abs(frame.yaw-pose.yaw)>.01 then boat.state.delta_yaw=0 end
          boat.state.x,boat.state.y,boat.state.z,boat.state.yaw=pose.x,pose.y,pose.z,pose.yaw
          local moved=math.abs(pose.x-oldx)+math.abs(pose.y-oldy)+math.abs(pose.z-oldz)+math.abs(pose.yaw-oldyaw)>.001
          boat.resting=not moved and math.abs(boat.state.vx)+math.abs(boat.state.vy)+math.abs(boat.state.delta_yaw)<.01
          if boat.resting then boat.state.vz=0 end -- A blocked fall must not spin forever at 20 Hz.
          if moved then
            local record=self.records[id];record.x,record.y,record.z,record.yaw=pose.x,pose.y,pose.z,pose.yaw
            self.dirty=true;self.moved_at=now
          end
        end
        if boat.state.hurt_ticks>0 or boat.animated or not boat.rendered
            or boat.state.paddling.left or boat.state.paddling.right then
          self.world:render(boat.handle,boat.state);boat.rendered=true
          boat.animated=boat.state.hurt_ticks>0 or boat.state.paddling.left or boat.state.paddling.right
        end
      end
      end)
      if not simulated then self:isolate(boat,simulation_error)end
      end
    end
  end
  for _,boat in pairs(self.boats)do
    if not boat.retired and #boat.state.riders>0 then
      local ok,why=pcall(function()
        if boat.dormant_reason then self:maintain_dormant(boat,now)
        elseif self.driver==boat or not boat.resting or now>=(boat.pin_at or 0)then
          boat.pin_at=now+.1;self:pin(boat,now)
        end
      end)
      if not ok then self:isolate(boat,why)end
    end
  end
  if self.capture_regions or now>=(self.capture_at or 0)then
    if not self.capture_regions then self.capture_at=now+.1 end
    self:scan(now)
  end
  if self.dirty and self.moved_at and now-self.moved_at>.4 and not self.session.session.opened then self:flush_memory()end
end
function Service:state()
  local boats={}
  for id,boat in pairs(self.boats)do
    local s=boat.state;local riders={}
    for _,r in ipairs(s.riders)do riders[#riders+1]={kind=r.kind,name=boat.leases[r.key]and boat.leases[r.key].id.name}end
    boats[#boats+1]={id=id,x=s.x,y=s.y,z=s.z,yaw=s.yaw,vx=s.vx,vy=s.vy,damage=s.damage,riders=riders,
      destroyed=s.destroyed or false,error=boat.simulation_error or boat.remove_error or boat.pin_error,
      dormant_reason=boat.dormant_reason,vz=s.vz,surface=boat.surface and boat.surface.kind}
  end
  return {boats=boats,pending=#self.pending,placed=self.placed,removed=self.removed,hits=self.hits,captured=self.captured,
    driver=self.driver and self.driver.handle.id,dirty=self.dirty,commits=self.commits,cleanup=#self.cleanup,
    deferred=state.clone(self.deferred),last_event=self.last_event,last_detail=self.last_detail,error=self.error,restore_error=self.restore_error}
end
function M.close()
  local self=active;if not self then return true end
  self.input={}
  for _,boat in pairs(self.boats)do
    local keys={};for rider in pairs(boat.leases)do keys[#keys+1]=rider end
    for _,rider in ipairs(keys)do local ok,why=self:release(boat,rider,'lifecycle',false);if not ok then return false,why end end
  end
  for i=#self.cleanup,1,-1 do if self.cleanup[i]:release(alive(self.cleanup[i].actor))then table.remove(self.cleanup,i)end end
  if #self.cleanup>0 then return false,'boat-passenger-cleanup-pending' end
  -- Cleanup cannot depend on a successful inventory transaction. A busy or
  -- changed store must never strand actors with paused animation/time/AI.
  if self.dirty then
    if self:current()then
      local ok,why=pcall(self.flush_memory,self)
      if not ok then self:report('pose-commit-deferred',tostring(why))end
    end
    if self.dirty then handoff={campaign_id=self.session.campaign_id,epoch=self.session.epoch,mode=self.session.mode,
      records=state.clone(self.records),baseline=state.clone(self.baseline)}end
  end
  local ok,why=self.world:close();if ok==false then return false,why end
  self.closed=true;if self.loop then CancelDelayedAction(self.loop);self.loop=nil end
  if active==self then active=nil end;return true
end
function M.ensure(binding,directory,log)
  if active and (active.binding~=binding or not active:current())then local ok,why=M.close();assert(ok,why)end
  if active then return active end
  local s=campaign.ensure(binding);local records=state.clone(s.store.core.vehicles or state.object())
  local self=setmetatable({binding=binding,session=s,world_id=binding.world_id.name,records=records,baseline=state.clone(records),
    world=require('host.pbz.boat_world').new(binding,directory,log),log=log,boats={},passengers={},released={},cleanup={},
    pending={},deferred={},input={},accumulator=0,placed=0,removed=0,hits=0,captured=0,commits=0,serial=0,dirty=false},Service)
  self.world_id=self.world.world_id or self.world_id
  self:observer_position()
  if handoff and handoff.campaign_id==s.campaign_id and handoff.epoch==s.epoch and handoff.mode==s.mode
      and equal(records,handoff.baseline)then self.records=handoff.records;self.dirty=true;self:flush_memory()end
  handoff=nil
  for id,r in pairs(self.records)do if r.world==self.world_id then self.pending[#self.pending+1]=id end end
  table.sort(self.pending);active=self
  self.loop=LoopInGameThreadAfterFrames(1,function()
    local ok,why=pcall(self.tick,self)
    if not ok then
      local message=tostring(why);if self.error~=message then self.error=message;self:report('service-error',message)end
      self.input={}
      -- Stop control immediately; retain every lease so the next callback can
      -- retry cleanup even when the old player/world binding is no longer live.
      self.failed=true;local clean,err=pcall(M.close);if not clean then self.cleanup_error=tostring(err)end
    end
  end)
  self:report('bound','restore='..#self.pending);return self
end
return M
