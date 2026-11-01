local Store=require('storage.build_store')
local transaction=require('rules.place_transaction')
local policy=require('rules.build_policy')
local M={};M.__index=M
function M.open(directory,scope,host,registry)
  local store=Store.open(directory,scope)
  return M.attach(store,scope.mode,host,registry)
end
-- Production uses the existing campaign/player-store transaction facade.
function M.attach(store,mode,host,registry)
  local data,warning=store:load()
  assert(data,warning)
  local self=setmetatable({store=store,data=data,mode=mode,creative=false,host=host,registry=registry,
    world=host.world_id,generation=1,handles={},pending={},warning=warning},M)
  for id,record in pairs(data.buildings) do
    if record.world==self.world and registry.get(record.content_id) then self.pending[#self.pending+1]=id end
  end
  table.sort(self.pending)
  if host.restore_distance then
    local distances={};for _,id in ipairs(self.pending) do distances[id]=host:restore_distance(data.buildings[id]) end
    table.sort(self.pending,function(a,b) return distances[a]==distances[b] and a<b or distances[a]<distances[b] end)
  end
  self.grid=data.building_grids and data.building_grids[self.world]
    or require('rules.build_grid').origin(data.buildings,self.world)
  return self
end
function M:pending_reservations()
  if not self.reservations then
    self.reservations=require('rules.build_reservations').new(self.registry)
    for _,id in ipairs(self.pending) do self.reservations:put(self.data.buildings[id]) end
  end
  return self.reservations
end
function M:next_id()
  self.serial=(self.serial or 0)+1
  return string.format('b-%016x-%08x',self.store.generation+1,self.serial)
end
function M:notify(changes)
  if self.on_change then
    local ok,why=pcall(self.on_change,changes)
    if not ok then self.notification_error=tostring(why) end
  end
end
function M:batch(changes,options)return require('rules.build_batch').apply(self,changes,options)end
function M:restore_batch(limit)
  if self.closed or self.quarantined then return false,'session-unavailable' end
  if not self.host:is_current() then return false,'stale-scene' end
  local attempts=0
  while #self.pending>0 and attempts<limit do
    attempts=attempts+1
    local id=self.pending[1]
    local record=self.data.buildings[id]
    local allowed,reason=self.host:can_place(record)
    if not allowed then
      -- A player/NPC may temporarily stand in one saved block. Defer only
      -- that record and continue the queue; never freeze all build input.
      table.remove(self.pending,1);self.pending[#self.pending+1]=id
      self.restore_blocked=(self.restore_blocked or 0)+1
      self.last_restore_block={id=id,reason=reason}
      if self.restore_blocked>=#self.pending then
        self.restore_blocked=0;return false,'restore-space-occupied:'..id
      end
      return true,#self.pending
    end
    local ok,handle=pcall(self.host.create,self.host,record)
    if not ok then
      if type(handle)=='table' and handle.cleanup_handle then
        self.quarantined=true;self.pending_cleanup=handle.cleanup_handle;self.pending_action='destroy'
      end
      return false,tostring(type(handle)=='table' and handle.reason or handle)
    end
    self.handles[id]=handle
    self:notify({{after=record,restored=true}})
    table.remove(self.pending,1)
    if self.reservations then self.reservations:remove(id) end
    self.restore_blocked=0
  end
  return true,#self.pending
end
function M:place(content_id,position)
  if self.closed then return false,'session-closed' end
  self:poll_cleanup()
  if not self.host:is_current() then return false,'stale-scene' end
  local definition=self.registry.get(content_id)
  if not definition then return false,'unsupported-content' end
  if #self.pending>0 and self:pending_reservations():overlap(content_id,position) then return false,'reserved-by-restoring-building' end
  if not policy.has_capacity(self.data,self.world,definition,self.registry) then return false,'building-capacity' end
  local request={generation=self.generation,content_id=content_id,
    instance_id=string.format('b-%016x',self.store.generation+1),cost=policy.cost(self.mode,self.creative),
    x=position.x,y=position.y,z=position.z,yaw=position.yaw or 0,properties=position.properties,
    grid=self.grid or {x=position.x,y=position.y,z=position.z}}
  local ok,why=transaction.place(self,request,self.host,self.store)
  if ok then self.grid=self.data.building_grids[self.world] end
  return ok,why
end
function M:remove(id,cause)
  if self.closed then return false,'session-closed' end
  self:poll_cleanup()
  if not self.host:is_current() then return false,'stale-scene' end
  local record=self.data.buildings[id]
  if not record then return false,'unknown-instance' end
  local definition=self.registry.get(record.content_id)
  if not definition then return false,'unsupported-content' end
  if self.expand_removals then
    local ids=self.expand_removals({id})
    if #ids>1 then return require('rules.remove_buildings')(self,ids,self.host,self.store)end
  end
  return transaction.remove(self,{generation=self.generation,instance_id=id,
    refund=policy.refund(self.mode,definition,cause)},self.host,self.store)
end
function M:poll_cleanup()
  if self.batch_recovery then
    for i=#self.batch_recovery,1,-1 do
      local row=self.batch_recovery[i]
      local ok,done=pcall(function()
        if row.after then return self.host:revise(row.handle,row.before,{rollback=true})end
        return self.host:set_active(row.handle,true)
      end)
      if not ok or not done then return false end
      table.remove(self.batch_recovery,i)
    end
    self.batch_recovery=nil
    self.quarantined=self.pending_group~=nil or self.pending_cleanup~=nil
  end
  if self.pending_group then
    local processed=0
    while #self.pending_group>0 and processed<8 do
      local h=self.pending_group[#self.pending_group];local ok,done
      if self.group_action=='activate' then
        if not self.host:is_current() then return false end
        ok,done=pcall(self.host.set_active,self.host,h,true)
      else ok,done=pcall(self.host.destroy,self.host,h) end
      if not ok or done~=true then return false end
      table.remove(self.pending_group);processed=processed+1
    end
    if #self.pending_group>0 then return false end
    self.pending_group=nil;self.group_action=nil;self.quarantined=false
  end
  if not self.pending_cleanup then return not self.quarantined end
  local ok,done
  if self.pending_action=='activate' then
    if not self.host:is_current() then return false end
    ok,done=pcall(self.host.set_active,self.host,self.pending_cleanup,true)
  else ok,done=pcall(self.host.destroy,self.host,self.pending_cleanup) end
  if ok and done==true then
    self.pending_cleanup=nil;self.pending_action=nil;self.quarantined=false
    return true
  end
  return false
end
function M:close()
  self.generation=self.generation+1
  local errors={}
  if self.pending_group then
    local remaining={}
    for _,h in ipairs(self.pending_group) do
      local ok,removed=pcall(self.host.destroy,self.host,h)
      if not ok or not removed then remaining[#remaining+1]=h end
    end
    self.pending_group=#remaining>0 and remaining or nil
    if self.pending_group then errors[#errors+1]='pending-group-cleanup' end
  end
  if self.pending_cleanup then
    local ok,removed=pcall(self.host.destroy,self.host,self.pending_cleanup)
    if ok and removed then self.pending_cleanup=nil;self.pending_action=nil else errors[#errors+1]='pending-cleanup' end
  end
  for id,handle in pairs(self.handles) do
    local ok,removed=pcall(self.host.destroy,self.host,handle)
    if ok and removed then self.handles[id]=nil else errors[#errors+1]=id end
  end
  self.closed=#errors==0
  if not self.closed then self.quarantined=true end
  return #errors==0,table.concat(errors,',')
end
return M
