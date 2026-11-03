-- Food completion starts a bounded search; only a verified final point moves
-- the current player. Cooldown is a lightweight memory transaction, no save.
local rules=require('rules.chorus_fruit')
local status_rules=require('rules.status_effects')
local identity=require('host.pbz.object_identity')
local M={};M.__index=M
local function low(p)return {x=p.X,y=p.Y,z=p.Z}end
local function native(p)return {X=p.x,Y=p.y,Z=p.z}end
local function distance(a,b)return math.sqrt((a.x-b.x)^2+(a.y-b.y)^2+(a.z-b.z)^2)end
function M.new(status)
 return setmetatable({status=status,binding=status.binding,report={used=0,teleported=0,rejected=0}},M)
end
function M:current()
 return not self.closed and self.status:current() and self.binding.actor.AttributeSetBase.Health.CurrentValue>0
end
function M:finish(reason,after)
 if self.timer then CancelDelayedAction(self.timer);self.timer=nil end
 self.report.last=self.report.last or {};self.report.last.reason=reason
 self.report.last.after=after;self.report.last.queries=self.world and self.world.report.queries
 if after then self.report.teleported=self.report.teleported+1 else self.report.rejected=self.report.rejected+1 end
 self.report.searching=false;self.job=nil;self.destination=nil;self.phase=nil
 self.status.log('MC chorus '..(after and 'teleported' or 'rejected')..' reason='..reason
  ..' queries='..tostring(self.report.last.queries)..' health-cost=0 count-unchanged')
end
function M:consume(record)
 if not self:current() or self.job or self.status.seen[record.action_id] then return false end
 local item=record.equipment[record.hand]
 if not item or item.content_id~=rules.id or status_rules.remaining(self.status.value,rules.id)>0 then return false end
 local hands=self.status:held();if not hands then return false end
 local selected=record.hand=='offhand' and hands[2] or hands[1]
 local camera=require('host.pbz.first_person_camera').get()
 if camera and camera:native_takeover()then return false end
 local pawn=self.binding.actor
 local origin=low(pawn:K2_GetActorLocation())
 local radius=pawn.CapsuleComponent:GetScaledCapsuleRadius()+6
 local half=pawn.CapsuleComponent:GetScaledCapsuleHalfHeight()+2
 local world=require('host.pbz.chorus_world').new(self.binding)
 -- Validate the exact active stack at acceptance. A failed search still gets
 -- the vanilla one-second cooldown, but never consumes the rescue item.
 self.status:commit(status_rules.start_cooldown(self.status.value,rules.id),selected.address,item,false)
 self.status.seen_order=self.status.seen_order or {};self.status.seen_order[#self.status.seen_order+1]=record.action_id
 if #self.status.seen_order>128 then self.status.seen[table.remove(self.status.seen_order,1)]=nil end
 self.status.seen[record.action_id]=true
 self.world,self.job,self.radius,self.half,self.origin=world,{},radius,half,origin
 self.phase='decide'
 self.report.used=self.report.used+1;self.report.searching=true
 self.report.last={action_id=record.action_id,hand=record.hand,before=origin,cooldown=rules.cooldown_ticks,consumed=false}
 self.status:sound('burp')
 self.timer=LoopInGameThreadAfterFrames(1,function()
  local ok,err=pcall(self.tick,self)
  if not ok then self.report.error=tostring(err);self:finish('error:'..tostring(err))end
 end)
 self.status.log('MC chorus searching action='..record.action_id..' hand='..record.hand..' cooldown=20t count-unchanged')
 return true
end
function M:teleport(position)
 local pawn=self.binding.actor;local before=low(pawn:K2_GetActorLocation())
 local ready=self.world:clear(position,self.radius,self.half)
 if not ready then self:finish('occupied-before-move');return end
 local function same_player()
  return self.binding:is_current() and identity.matches(pawn,self.binding.actor_id)
   and identity.matches(pawn:GetWorld(),self.binding.world_id)
 end
 local function writable()
  if not same_player() or not self:current() or not require('host.pbz.item_interface').equipment_available(self.binding)then return false end
  local camera=require('host.pbz.first_person_camera').get()
  return not (camera and camera:native_takeover())
 end
 local after
 local ok,why=pcall(function()
  assert(writable(),'owner-changed-before-move')
  assert(pawn:K2_SetActorLocation(native(position),false,{},true),'native-move-rejected')
  -- Teleport overlaps may synchronously start a cutscene, death or travel.
  -- Once that happens the native owner wins, including over our rollback.
  assert(writable(),'native-owner-took-over-after-move')
  after=low(pawn:K2_GetActorLocation())
  assert(distance(after,position)<2,'native-move-position-mismatch')
  local safe,reason=self.world:verify(after,self.radius,self.half)
  assert(safe,reason or 'destination-postcheck-failed')
  if self.binding.mc_boat_riding then
   local boats=require('host.pbz.boat_service').get(self.binding)
   assert(boats and boats:leave_for_teleport(),'boat-seat-release-failed')
  end
  assert(writable(),'native-owner-took-over-after-seat-release')
 end)
 if not ok then
  local rolled,err=pcall(function()
   assert(writable(),'rollback-owner-changed-or-native-takeover')
   assert(pawn:K2_SetActorLocation(native(before),false,{},true),'rollback-move-rejected')
   assert(distance(low(pawn:K2_GetActorLocation()),before)<2,'rollback-position-mismatch')
  end)
  self.report.last.rollback=rolled;self.report.last.rollback_error=not rolled and tostring(err)or nil
  self:finish(tostring(why));return
 end
 local movement_ok,movement_error=pcall(function()
  pawn.CharacterMovement:StopMovementImmediately();pawn.CharacterMovement:SetMovementMode(3,0)
 end)
 if not movement_ok then self.report.movement_error=tostring(movement_error)end
 -- The teleport displacement must not become a fall-critical or fall-damage
 -- distance; no synthetic movement/attack input is emitted.
 require('host.pbz.item_interface').reset_fall_after_teleport(self.binding)
 local ok,err=pcall(function()
  if not self.fx then self.fx=require('host.pbz.portal_particles').new(self.binding,require('host.pbz.local_player').controller())end
  self.fx:burst(native(before));self.fx:burst(native(after))
  self.status:sound('pearl_teleport')
 end)
 if not ok then self.report.fx_error=tostring(err)end
 self:finish(self.report.last.mode=='random' and 'random-safe-flat-point' or 'nearest-flat-sampled-point',after)
end
function M:tick()
 if not self:current()then self:finish('owner-changed');return end
 local camera=require('host.pbz.first_person_camera').get()
 if camera and camera:native_takeover()then self:finish('native-camera-takeover');return end
 if not require('host.pbz.item_interface').equipment_available(self.binding)then self:finish('equipment-unavailable');return end
 local current=low(self.binding.actor:K2_GetActorLocation())
 -- A rescue food must remain usable while sliding, falling or being pushed
 -- out of a wall. Keep the completed-eating origin; cancel only once the
 -- player has left that bounded search region altogether.
 if (current.x-self.origin.x)^2+(current.y-self.origin.y)^2>1600^2 or math.abs(current.z-self.origin.z)>800 then
  self:finish('left-search-region');return
 end
 if StaticFindObject('/Script/Engine.Default__GameplayStatics'):IsGamePaused(self.binding.actor)then return end
 if self.phase=='decide'then
  local flat=self.world:standing_flat(self.origin,self.radius,self.half)
  local mode=flat and 'random' or 'nearest'
  self.job=rules.new({origin=self.origin,radius=self.radius,half_height=self.half,clearance=3,
   queries_per_step=8,candidates_per_step=2,mode=mode})
  self.report.last.mode=mode;self.report.last.standing_flat=flat;self.phase=nil
  self.status.log('MC chorus mode='..mode..' standing-flat='..tostring(flat));return
 end
 if self.phase=='move'then self:teleport(self.destination);return end
 if self.phase=='precheck'then
  local ok,why=self.world:verify(self.destination,self.radius,self.half)
  if not ok then self:finish(why or 'recheck-failed');return end
  self.phase='move';return
 end
 local result=rules.advance(self.job,self.world:callbacks())
 self.report.last.search=result.report
 if result.status=='found'then self.destination=result.position;self.phase='precheck'
 elseif result.status~='searching'then self:finish(result.reason or result.report and result.report.reason or 'no-safe-flat-ground')end
end
function M:close()
 if self.timer then CancelDelayedAction(self.timer);self.timer=nil end
 if self.fx then self.fx:close()end
 self.job=nil;self.destination=nil;self.closed=true;self.report.searching=false
end
return M
