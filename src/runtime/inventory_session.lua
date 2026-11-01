-- Converts UI intents to the shared rules and one player-store commit. Native
-- input leases and real world-item preparation are supplied by the PBZ adapter.
local state=require('storage.state')
local slots=require('rules.container_slots')
local actions=require('rules.container_actions')
local transfer=require('rules.container_transfer')
local world_items=require('rules.world_items')
local native_slot=require('rules.native_slot_reference')
local M={};M.__index=M
local function with_containers(data,containers)
  if containers==data.containers then return data end
  local result=state.object();for key,value in pairs(data) do result[key]=value end
  result.containers=containers;return result
end
function M.new(store,host,world)
  assert(store.loaded and type(world)=='string' and #world>0,'inventory-session-not-ready')
  assert(type(host.is_current)=='function','missing-inventory-lifecycle-adapter')
  return setmetatable({store=store,definitions=store.definitions,host=host,world=world,epoch=0},M)
end
function M:open(context,page)
  if self.quarantined or not self.host:is_current() then return false,'inventory-scene-unavailable' end
  if context~='inventory' and context~='ender' then return false,'invalid-container-context' end
  if context=='ender' then
    page=tostring(page or 1);slots.address('ender/'..page..'/1')
    if not self.host.ender_access or not self.host:ender_access() then return false,'ender-access-unavailable' end
  end
  if not self.opened then
    -- An interrupted forced close can leave the last trash stack in the same
    -- campaign snapshot. Finish deletion before accepting another UI gesture.
    if self.store.core.containers.trash then
      local ticket=self.store:checkout({})
      local cleared=with_containers(ticket.data,require('rules.inventory_trash').clear(ticket.data.containers))
      local saved,why=self:commit(ticket,cleared)
      if not saved then return false,why end
    end
    assert(type(self.host.begin_inventory)=='function','missing-inventory-input-adapter')
    local ok,lease=pcall(self.host.begin_inventory,self.host)
    if not ok or not lease or type(lease.release)~='function' then return false,'inventory-input-lease-failed' end
    self.lease=lease;self.opened=true
  end
  self.context=context;self.page=page;self.epoch=self.epoch+1
  return true
end
function M:view()
  local pages={};if self.opened and self.context=='ender' then pages[self.page]=true end
  local ticket=self.store:checkout(pages)
  return {data=ticket.data,epoch=self.epoch,revision=self.store.generation,context=self.context,page=self.page,opened=self.opened}
end
function M:visible(address,cursor)
  if address=='cursor' then return cursor==true end
  local area,_,page=slots.address(address)
  if area=='main' or area=='hotbar' then return true end
  if self.context=='inventory' then return area=='armor' or area=='offhand' or area=='craft' or area=='trash' end
  return area=='ender' and page==self.page
end
function M:check_request(request)
  assert(self.opened and not self.quarantined and not self.busy,'inventory-session-unavailable')
  assert(request.epoch==self.epoch and request.revision==self.store.generation,'stale-inventory-intent')
  assert(self.host:is_current(),'inventory-scene-changed')
  if self.context=='ender' then assert(self.host:ender_access(),'ender-access-lost') end
end
function M:commit(ticket,candidate,validate_context)
  if candidate==ticket.data then return true end
  local epoch=self.epoch
  local prepared
  local ok,err=pcall(function()
    assert(self.host:is_current(),'inventory-scene-changed')
    if validate_context then validate_context() end
    local previous=ticket.data.containers.player
    local proposed=candidate.containers.player
    local before,after=previous.hotbar[tostring(previous.selected)],proposed.hotbar[tostring(proposed.selected)]
    if native_slot.is(before) or native_slot.is(after) then
      -- A real switch must be confirmed by the native equipment coordinator.
      -- Until that adapter exists, reject changing the active reference rather
      -- than committing a selection that only the UI believes succeeded.
      local unchanged=previous.selected==proposed.selected and before and after and before.instance_id==after.instance_id
      assert(unchanged or (type(self.host.authorize_selection)=='function'
        and self.host:authorize_selection(before,after)==true),'native-equipment-coordinator-unavailable')
    end
    if candidate.world_items~=ticket.data.world_items then
      assert(type(self.host.prepare_items)=='function','world-item-adapter-unavailable')
      prepared=self.host:prepare_items(ticket.data.world_items,candidate.world_items)
      assert(prepared and type(prepared.rollback)=='function' and type(prepared.finish)=='function','invalid-world-item-preparation')
    end
    assert(self.host:is_current() and self.epoch==epoch,'inventory-scene-changed')
    if validate_context then validate_context() end
    if self.context=='ender' then assert(self.host:ender_access(),'ender-access-lost') end
    local saved,why=self.store:commit(ticket,candidate);assert(saved,why)
  end)
  if not ok then
    -- A native adapter that cannot clean a partial construction must return its
    -- owned preparation in the error, so the session can retry that cleanup.
    if type(err)=='table' and err.preparation then prepared=err.preparation end
    if prepared then
      local undone,result=pcall(prepared.rollback,prepared)
      if not undone or result~=true then
        self.quarantined=true;self.pending_world=prepared;self.pending_world_action='rollback'
      end
    end
    return false,tostring(err)
  end
  if prepared then
    local finished,result=pcall(prepared.finish,prepared)
    if not finished or result~=true then
      self.quarantined=true;self.pending_world=prepared;self.pending_world_action='finish'
      return true,'inventory-committed-world-reconcile-required'
    end
  end
  return true,self.store.warning
end
function M:controls(request)
  if self.busy then return false,'inventory-transaction-in-progress' end
  local ok,result,warning=pcall(function()
    assert(not self.opened and not self.quarantined,'hotbar-context-unavailable')
    assert(request.epoch==self.epoch and request.revision==self.store.generation,'stale-hotbar-intent')
    assert(type(self.host.item_controls_context)=='function','item-controls-adapter-unavailable')
    local function validate_context()
      local context=self.host:item_controls_context()
      assert(self.host:is_current() and type(context)=='table' and context.kind=='game'
        and (context.weapon_group=='mc' or context.unified_hotbar and
          (request.kind=='select_slot' or request.kind=='scroll_slots')),'hotbar-gameplay-unavailable')
      assert(type(context.epoch)=='number' and context.epoch%1==0 and context.epoch>=0 and context.epoch==request.input_epoch,'stale-input-context')
    end
    validate_context();self.busy=true
    local ticket=self.store:checkout({});local data=ticket.data
    local hotbar=require('rules.hotbar');local candidate
    if request.kind=='select_slot' then candidate=with_containers(data,hotbar.select(data.containers,request.index))
    elseif request.kind=='scroll_slots' then candidate=with_containers(data,hotbar.scroll(data.containers,request.steps))
    elseif request.kind=='swap_selected_offhand' then candidate=with_containers(data,hotbar.swap_offhand(data.containers,self.definitions))
    elseif request.kind=='drop_selected' then candidate=self:drop(data,'player/hotbar/'..data.containers.player.selected,request.count)
    elseif request.kind=='pick_existing' then
      assert(type(self.host.pick_target)=='function','pick-target-adapter-unavailable')
      local target=self.host:pick_target();assert(target,'pick-target-unavailable')
      local pick=require('rules.game_mode').creative(data)and hotbar.pick_creative or hotbar.pick_existing
      candidate=with_containers(data,pick(data.containers,target.content_id,target.metadata,self.definitions))
    else error('unsupported-hotbar-intent') end
    return self:commit(ticket,candidate,validate_context)
  end)
  self.busy=false
  if not ok then return false,tostring(result) end
  return result,warning
end
function M:drop(data,address,count,ordinal)
  -- World drops were removed from the product. Only infinite block references
  -- may be cleared; finite items/native equipment remain owned in their slot.
  return with_containers(data,require('rules.block_catalogue').clear(data.containers,address))
end
function M:dispatch(request)
  if self.busy then return false,'inventory-transaction-in-progress' end
  local ok,result,warning=pcall(function()
    self:check_request(request)
    self.busy=true
    local kind=request.kind
    if request.address then assert(self:visible(request.address,kind=='drop' or kind=='trash'),'slot-not-visible') end
    if request.addresses then
      for _,address in ipairs(request.addresses) do assert(self:visible(address,false),'slot-not-visible') end
    end
    local pages={};if self.context=='ender' then pages[self.page]=true end
    if kind=='shift' and self.context=='ender' and not request.address:match('^ender/') then
      local value=slots.get(self.store.core.containers,request.address)
      if value then for page in pairs(self.store:pages_for_offer(value)) do pages[page]=true end end
    end
    local ticket=self.store:checkout(pages)
    local data,containers=ticket.data,ticket.data.containers
    local candidate
    if kind=='catalogue_take' then
      assert(self.context=='inventory','catalogue-context-required')
      local target=request.index and 'player/hotbar/'..request.index or 'cursor'
      local category=assert(require('rules.item_catalogue').kind(request.content_id),'catalogue-content-unavailable')
      if category=='equipment'then
        candidate=require('rules.equipment_catalogue').take(data,request.content_id,
          assert(self.store.scope and self.store.scope.campaign_id,'catalogue-campaign-required'),target,
          {instance_exists=function(id)
            for _,page in pairs(self.store.head and self.store.head.pages or {})do
              if page.instances and page.instances[id]then return true end
            end
            return false
          end})
      elseif category=='supply'then
        candidate=with_containers(data,require('rules.supply_catalogue').take(containers,request.content_id,target))
      else
        candidate=with_containers(data,require('rules.block_catalogue').take(containers,request.content_id,target,self.definitions))
      end
    elseif kind=='catalogue_return' then
      candidate=with_containers(data,require('rules.block_catalogue').clear(containers,'cursor'))
    elseif kind=='trash' then
      assert(self.context=='inventory','trash-inventory-required')
      candidate=with_containers(data,require('rules.inventory_trash').put(containers,request.address,self.definitions))
    elseif kind=='click' then candidate=with_containers(data,actions.click(containers,request.address,request.button,self.definitions))
    elseif kind=='shift' then candidate=with_containers(data,transfer.shift(containers,request.address,self.context,self.definitions,self.store:transfer_options()))
    elseif kind=='drag' then candidate=with_containers(data,actions.drag(containers,request.addresses,request.button,self.definitions))
    elseif kind=='gather' then candidate=with_containers(data,actions.gather(containers,request.addresses,self.definitions))
    elseif kind=='hotbar_swap' then
      assert(type(request.index)=='number' and request.index%1==0 and request.index>=1 and request.index<=9,'invalid-hotbar-index')
      candidate=with_containers(data,actions.swap(containers,request.address,'player/hotbar/'..request.index,self.definitions))
    elseif kind=='offhand_swap' then candidate=with_containers(data,actions.swap(containers,request.address,'player/offhand',self.definitions))
    elseif kind=='drop' then candidate=self:drop(data,request.address,request.count)
    else error('unsupported-inventory-intent') end
    return self:commit(ticket,candidate)
  end)
  self.busy=false
  if not ok then return false,tostring(result) end
  return result,warning
end
function M:reconcile()
  if self.busy then return false,'inventory-transaction-in-progress' end
  if self.pending_world then
    local preparation=self.pending_world
    local ok,done=pcall(preparation[self.pending_world_action],preparation)
    if not ok or done~=true then return false,'world-reconcile-pending' end
    self.pending_world=nil;self.pending_world_action=nil
  end
  if self.pending_lease then
    local ok,done=pcall(self.pending_lease.release,self.pending_lease)
    if not ok or done~=true then return false,'input-release-pending' end
    self.pending_lease=nil
  end
  self.quarantined=false;return true
end
function M:release()
  self.opened=false;self.context=nil;self.page=nil;self.epoch=self.epoch+1
  if not self.lease then return true end
  local lease=self.lease;self.lease=nil
  local ok,done=pcall(lease.release,lease)
  if not ok or done~=true then self.quarantined=true;self.pending_lease=lease;return false,'inventory-input-release-failed' end
  return true
end
function M:close(reason)
  if not self.opened then return true end
  -- Every completed click already persisted cursor/craft ownership. Forced
  -- lifecycle closure must release input even when the old world no longer
  -- exists, without inventing death drops or writing into another campaign.
  if reason=='death' or reason=='reload' or reason=='map' or reason=='cinematic' or reason=='shutdown' then
    -- Only the outgoing store is touched. Trash changes neither native equipment
    -- nor world objects, so it can be cleared after the actor has gone away.
    -- A failed cleanup never holds input; the next open retries from the snapshot.
    if not self.busy and self.store.core.containers.trash then
      local ok,result,why=pcall(function()
        local ticket=self.store:checkout({})
        local candidate=with_containers(ticket.data,require('rules.inventory_trash').clear(ticket.data.containers))
        if candidate==ticket.data then return true end
        return self.store:commit(ticket,candidate)
      end)
      self.trash_cleanup_error=not ok and tostring(result) or (not result and tostring(why) or nil)
    end
    return self:release()
  end
  if reason~='normal' then return false,'invalid-inventory-close-reason' end
  if self.busy then return false,'inventory-transaction-in-progress' end
  local ok,result,warning=pcall(function()
    assert(not self.quarantined and self.host:is_current(),'inventory-scene-unavailable')
    self.busy=true
    local ticket=self.store:checkout({})
    local candidate=with_containers(ticket.data,require('rules.inventory_trash').clear(ticket.data.containers))
    local sources={'cursor','craft/1','craft/2','craft/3','craft/4'}
    for i,address in ipairs(sources) do
      local containers=transfer.move(candidate.containers,address,'player',nil,self.definitions)
      candidate=with_containers(candidate,containers)
      -- Full inventory keeps cursor/crafting ownership in the persisted state.
      -- Closing must still release input; never turn leftovers into drops.
    end
    return self:commit(ticket,candidate)
  end)
  self.busy=false
  if not ok then return false,tostring(result) end
  if not result then return false,warning end
  local released,why=self:release()
  return released,why or warning
end
return M
