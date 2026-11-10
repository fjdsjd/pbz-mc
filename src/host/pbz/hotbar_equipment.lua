-- Preserve native armed/combo stages; only commit an observed equipment choice.
local native=require('rules.native_slot_reference')
local slots=require('rules.container_slots')
local campaign=require('host.pbz.campaign_inventory')
local M={};M.__index=M
function M.new(binding,pc,epoch,context,log)
  local reader,why=require('host.pbz.native_weapon_request').new(binding,pc,epoch,context)
  assert(reader,why)
  return setmetatable({binding=binding,pc=pc,epoch=epoch,reader=reader,context=context,log=log,recoveries=0},M)
end
function M:camera_transition(enabled)
  local camera=require('host.pbz.first_person_camera').get()
  if camera then camera.transition=enabled;if enabled then camera:release_movement() end end
end
function M:idle()
  return require('host.pbz.native_input_dispatch').action_idle(self.pc,function()
    self.reader:check(self.context().epoch,true);return true
  end)
end
function M:begin(p,now)
  -- Returning to MC never equips or stows a PBZ weapon. Story loadouts can
  -- have no runtime slot, or have a different size from the saved backpack.
  if not native.is(p.after) then
    if not self:idle() then return {phase='waiting',reason='native-action-active'} end
    return {phase='ready',reason='native-action-idle-no-stow'}
  end
  local observed=self.reader:observe(p.epoch,p.after.metadata.category)
  local slot=assert(observed.slot or (p.after.metadata.category=='main' and observed.main),'native-request-runtime-slot-unavailable')
  if observed.runtime.in_weapon_transition or slot.with_pending_differs then
    return {phase='waiting',reason='native-weapon-transition'}
  end
  if slot.current_index~=p.after.metadata.native_slot_index and not native.is(p.before) and not self:idle() then
    return {phase='waiting',reason='native-action-active'}
  end
  local result,why=self.reader:start(p.after,nil,p.epoch,now,observed);assert(result,why);return result
end
function M:request(request,data,revision,context,now)
  if self.pending then return true end
  if request.kind~='select_slot' and request.kind~='scroll_slots' then return false end
  local index=request.kind=='select_slot' and request.index or ((data.player.selected-1+request.steps)%9)+1
  local before=slots.get(data,'player/hotbar/'..data.player.selected)
  local after=slots.get(data,'player/hotbar/'..index)
  if index==data.player.selected or not native.is(before) and not native.is(after) then return false end
  if not self.reader then self.reader=assert(require('host.pbz.native_weapon_request').new(self.binding,self.pc,self.epoch,self.context)) end
  self:camera_transition(true)
  local p={request={kind='select_slot',index=index},before=before,after=after,revision=revision,
    before_index=data.player.selected,epoch=context.epoch,started=now}
  local ok,result=pcall(self.begin,self,p,now)
  if not ok or result.phase=='rejected' then self:camera_transition(false);error(ok and result.reason or result) end
  p.result=result;self.pending=p;self.binding.mc_native_selection_pending=true
  -- While an original action finishes, keep original movement and mouse view.
  -- A boat uses the MC mouse/movement lease even with a native slot selected.
  -- Keep that lease released until the equipment receipt commits; otherwise
  -- the next camera tick re-acquires IgnoreMove/Look and rejects our own idle
  -- check when switching from PBZ back to an MC item.
  self:camera_transition(not native.is(before) or self.binding.mc_boat_riding~=nil)
  self.last_result=result
  return true
end
function M:abort(reason)
  self.last_failure=tostring(reason);self.recoveries=self.recoveries+1
  if self.reader then self.reader:close();self.reader=nil end
  self.pending=nil;self.queued=nil;self.binding.mc_native_selection_pending=nil;self:camera_transition(false)
  self.log('native hotbar request released: '..self.last_failure..'; no action replayed')
end
function M:queue(request)
  if request.kind=='select_slot' then self.queued={kind='select_slot',index=request.index}
  elseif request.kind=='scroll_slots' then
    local index=self.queued and self.queued.index or self.pending.request.index
    self.queued={kind='select_slot',index=((index-1+request.steps)%9)+1}
  end
end
function M:_tick(now)
  local p=self.pending;if not p then return end
  if p.result.phase=='waiting' and self.queued then
    -- No native action has been sent. The latest wheel/digit intent can
    -- replace this wait, including selecting the currently equipped slot.
    local next_request=self.queued;self.queued=nil
    self.pending=nil;self.binding.mc_native_selection_pending=nil;self:camera_transition(false)
    local data,revision=campaign.view(self.binding);local context=self.context()
    assert(context.epoch==p.epoch and context.kind=='game','native-selection-context-changed')
    if next_request.index~=data.player.selected and not self:request(next_request,data,revision,context,now) then
      campaign.dispatch(self.binding,next_request,context)
    end
    return
  end
  if p.result.phase=='waiting' then
    p.result=self:begin(p,now)
    if p.result.phase~='waiting' then p.dispatched_at=now end
  elseif p.result.phase~='ready' then
    local result,why=self.reader:poll(now,true);assert(result,why);p.result=result
  end
  self.last_result=p.result
  if p.result.phase=='rejected' then self:abort(p.result.reason);return end
  if p.result.phase~='ready' then
    -- Native root motion can legitimately last longer than five seconds.
    -- Only a dispatched request can time out with an uncertain outcome.
    if p.result.phase~='waiting' and now-(p.dispatched_at or p.started)>=5 then self:abort(p.result.reason or 'native-selection-deadline') end
    return
  end
  local data,revision=campaign.view(self.binding)
  local encode=require('storage.canonical_json')
  local function same(a,b) return a==b or a and b and encode(a)==encode(b) end
  -- A native savepoint legitimately advances the store revision while a draw
  -- animation is pending. Validate the actual selected/target items instead.
  assert(data.player.selected==p.before_index and same(slots.get(data,'player/hotbar/'..p.before_index),p.before)
    and same(slots.get(data,'player/hotbar/'..p.request.index),p.after),'native-selection-inventory-changed')
  local context=self.context();assert(context.epoch==p.epoch and context.kind=='game','native-selection-context-changed')
  local function authorize(before,after)
    assert((before and before.instance_id)==(p.before and p.before.instance_id)
      and (after and after.instance_id)==(p.after and p.after.instance_id),'native-selection-receipt-mismatch')
    if not native.is(after) then return self:idle() end
    local observed=self.reader:observe(context.epoch,after.metadata.category)
    local slot=observed.slot or (after.metadata.category=='main' and observed.main)
    return slot and not observed.runtime.in_weapon_transition and not slot.with_pending_differs
      and slot.current_index==after.metadata.native_slot_index
  end
  campaign.dispatch(self.binding,p.request,context,authorize)
  local queued=self.queued;self.queued=nil;self.pending=nil;self.binding.mc_native_selection_pending=nil;self:camera_transition(false)
  self.log('native hotbar selection observed and committed slot='..p.request.index)
  if queued then
    data,revision=campaign.view(self.binding)
    if not self:request(queued,data,revision,context,now) then campaign.dispatch(self.binding,queued,context) end
  end
end
function M:tick(now)
  local ok,why=pcall(self._tick,self,now)
  if not ok then self:abort(why) end -- A failed switch must not kill the whole input monitor.
end
function M:state()
  local p=self.pending
  return {pending=p and {index=p.request.index,started=p.started,phase=p.result.phase,reason=p.result.reason},
    queued=self.queued,last_result=self.last_result,last_failure=self.last_failure,recoveries=self.recoveries}
end
function M:close()
  if self.reader then self.reader:close();self.reader=nil end
  self.pending=nil;self.queued=nil;self.binding.mc_native_selection_pending=nil;self:camera_transition(false)
end
return M
