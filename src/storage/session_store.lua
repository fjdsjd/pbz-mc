-- Gameplay commits are memory transactions. The immutable disk journal is
-- advanced only by flush(), at the host's accepted savepoint collection event.
local Store=require('storage.player_store')
local state=require('storage.state')
local slots=require('rules.container_slots')
local M={}
local block_properties=require('rules.block_properties')
local building_fields={id=true,content_id=true,world=true,x=true,y=true,z=true,yaw=true,properties=true}
local function same_record(a,b)
  if a==nil or b==nil then return a==b end
  if a==b then return true end
  for k,v in pairs(a) do
    if k=='properties' then if not block_properties.equal(v,b[k]) then return false end
    elseif b[k]~=v then return false end
  end
  for k,v in pairs(b) do
    if k=='properties' then if not block_properties.equal(v,a[k]) then return false end
    elseif a[k]~=v then return false end
  end
  return true
end
local function same_grid(a,b)
  if a==nil or b==nil then return a==b end
  for k,v in pairs(a) do if b[k]~=v then return false end end
  for k,v in pairs(b) do if a[k]~=v then return false end end
  return true
end
-- Shared by the campaign facade when an inventory commit cloned the core.
-- Unchanged building pointers are a fast path only for immutable store cores.
M.same_building=same_record
M.same_building_grid=same_grid
M.__index=function(self,key) return M[key] or Store[key] or self.durable[key] end
function M.new(durable)
  if getmetatable(durable)==M then return durable end
  assert(durable.loaded and durable.core and not durable.read_only,'session-store-requires-loaded-profile')
  return setmetatable({durable=durable,core=durable.core,head={pages=state.clone(durable.head.pages)},
    generation=durable.generation,loaded=true,dirty=false,pending_pages={},page_cache={},
    commits=0,flushes=0},M)
end
function M:read_page(entry)
  if entry.session_page then return state.clone(assert(self.pending_pages[entry.session_page])) end
  local data=self.page_cache[entry.blob]
  if not data then data=self.durable:read_page(entry);self.page_cache[entry.blob]=data end
  return state.clone(data)
end
function M:commit(ticket,data)
  if self.read_only then return false,self.warning or 'session-store-not-writable' end
  if ticket.owner~=self or ticket.generation~=self.generation or ticket.consumed then return false,'stale-player-checkout' end
  local ok,core,pages,pending=pcall(function()
    local replaced={};for page in pairs(ticket.pages) do replaced[page]=true end
    for page in pairs(data.containers.ender) do
      assert(ticket.pages[page] or not self.head.pages[page],'page-outside-checkout');replaced[page]=true
    end
    self:validate_ownership(data,self.head.pages,replaced)
    assert(self.generation+1<2^53,'player-generation-exhausted')
    local next_pages=state.clone(self.head.pages);local next_pending={}
    for page,values in pairs(self.pending_pages) do next_pending[page]=values end
    for page in pairs(replaced) do
      local values=data.containers.ender[page]
      next_pending[page]=values and state.clone(values) or false
      if values and next(values) then
        local entry=Store.page_summary(values,self.definitions);entry.session_page=page;next_pages[page]=entry
      else next_pages[page]=nil end
    end
    local next_core=state.clone(data);next_core.containers.ender=state.object()
    return next_core,next_pages,next_pending
  end)
  if not ok then return false,tostring(core) end
  self.core=core;self.head={pages=pages};self.pending_pages=pending
  self.runtime_selected=nil;self.generation=self.generation+1;self.dirty=true
  ticket.consumed=true;self.commits=self.commits+1
  return true
end
-- World-only memory transaction. This ticket deliberately has no inventory
-- checkout, page read, ownership scan, selection authority or native pointer.
-- Its write set is the dense, bounded changes list, not a replacement profile.
function M:commit_buildings(ticket,changes,grids)
  if self.read_only then return false,self.warning or 'session-store-not-writable' end
  if not self.loaded or not self.core or type(ticket)~='table' or ticket.owner~=self
    or ticket.generation~=self.generation or ticket.consumed or ticket.core~=self.core
    or ticket.buildings~=self.core.buildings or ticket.building_grids~=self.core.building_grids then
    return false,'stale-building-checkout'
  end
  local starting_core,starting_generation=self.core,self.generation
  local ok,next_core=pcall(function()
    assert(type(changes)=='table' and #changes>0 and #changes<=128,'invalid-building-delta')
    local count=0
    for index in pairs(changes) do
      assert(type(index)=='number' and index%1==0 and index>=1 and index<=#changes,'invalid-building-delta-index')
      count=count+1
    end
    assert(count==#changes,'sparse-building-delta')
    local updates,seen,worlds={},{},{}
    local next_count=0
    for _,row in ipairs(changes) do
      assert(type(row)=='table','invalid-building-delta-row')
      local before,after=row.before,row.after
      assert((before==nil or type(before)=='table') and (after==nil or type(after)=='table'),'invalid-building-delta-record')
      local id=after and after.id or before and before.id
      assert(type(id)=='string' and #id>0 and #id<=128 and not seen[id],'invalid-or-duplicate-building-delta-id')
      assert(not before or before.id==id,'building-delta-id-changed')
      assert(row.id==nil or row.id==id,'building-delta-row-id-mismatch')
      assert(same_record(starting_core.buildings[id],before),'building-delta-before-changed')
      if before then worlds[before.world]=true end
      if after then
        -- Changed records are the sole new owned references. Their exact
        -- stable schema also excludes numeric native handles under new keys.
        for field in pairs(after) do assert(building_fields[field],'unstable-building-field:'..tostring(field)) end
        state.validate_buildings(state.object({[id]=after}));state.validate_value(after)
        assert(not before or after.world==before.world,'building-delta-world-changed')
        worlds[after.world]=true
        updates[id]=state.clone(after)
        if not before then next_count=next_count+1 end
      else updates[id]=false;next_count=next_count-1 end
      seen[id]=true
    end
    local next_grids=starting_core.building_grids
    if grids~=nil and grids~=next_grids then
      state.validate_building_grids(grids);state.validate_value(grids)
      for world,origin in pairs(next_grids or {}) do
        assert(same_grid(origin,grids[world]),'building-grid-changed')
      end
      local additions={}
      for world,origin in pairs(grids) do
        for axis in pairs(origin) do assert(axis=='x' or axis=='y' or axis=='z','unstable-building-grid-field') end
        if not next_grids or not next_grids[world] then
          assert(worlds[world],'unrelated-building-grid-addition');additions[world]=state.clone(origin)
        end
      end
      if next(additions) then
        next_grids=state.object()
        for world,origin in pairs(starting_core.building_grids or {}) do next_grids[world]=origin end
        for world,origin in pairs(additions) do next_grids[world]=origin end
      end
    end
    local buildings=require('storage.building_map').updated(starting_core.buildings,updates,next_count)
    local core=state.object();for k,v in pairs(starting_core) do core[k]=v end
    core.buildings=buildings;core.building_grids=next_grids
    assert(starting_generation+1<2^53,'player-generation-exhausted')
    return core
  end)
  if not ok then return false,tostring(next_core) end
  if self.core~=starting_core or self.generation~=starting_generation or self.read_only then
    return false,'building-state-changed-during-validation'
  end
  self.core=next_core;self.generation=self.generation+1;self.dirty=true;self.commits=self.commits+1
  ticket.consumed=true
  -- runtime_selected, containers, head/pages, page_cache, pending_pages,
  -- status/vehicles and selection caches stay exactly as owned before.
  return true,self.warning
end
function M:flush()
  if not self.dirty and not self.runtime_selected then return true end
  if self.read_only then return false,self.warning or 'session-store-not-writable' end
  -- Building/item IDs use this revision as a nonce. Persist its high-water
  -- mark so a restart cannot reuse an ID issued by an unsaved memory commit.
  self.durable.generation=math.max(self.durable.generation,self.generation)
  local ticket=self.durable:checkout({});local data=state.clone(self.core)
  if self.runtime_selected then data.containers.player.selected=self.runtime_selected end
  for page,values in pairs(self.pending_pages) do
    ticket.pages[page]=true
    if values then data.containers.ender[page]=state.clone(values) end
  end
  local ok,why=self.durable:commit(ticket,data)
  if not ok then return false,why end
  if self.durable.read_only then return false,self.durable.warning end
  self.core=self.durable.core;self.head={pages=state.clone(self.durable.head.pages)}
  self.runtime_selected=nil;self.pending_pages={};self.page_cache={};self.dirty=false
  self.generation=self.durable.generation
  self.flushes=self.flushes+1
  -- Both revisions remain monotonic across this persistence boundary.
  return true,why
end
function M:check_heads() return self.durable:check_heads() end
function M:create_checkpoint()
  assert(not self.dirty and not self.runtime_selected,'session-profile-not-flushed')
  return self.durable:create_checkpoint()
end
return M
