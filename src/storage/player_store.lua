-- A small, single-writer player journal. Immutable core/page blobs are staged
-- first; one of two checksummed heads is renamed last, committing all owners.
-- A checkout contains ONLY requested ender pages. Missing pages in that view
-- do not mean missing pages in the save. No native slot-name fallback is used.
local state=require('storage.state')
local player=require('storage.player_state')
local slots=require('rules.container_slots')
local stacks=require('rules.item_stack')
local encode=require('storage.canonical_json')
local sha=require('storage.sha256')
local json=require('dkjson')
local native_slot=require('rules.native_slot_reference')
local M={};M.__index=M
local function object(value)
  return type(value)=='table' and value~=json.null and state.json_kind(value)=='object'
end
local function integer(n) return type(n)=='number' and n%1==0 and n>=0 and n<2^53 end
local function hash(s) return type(s)=='string' and #s==64 and s:match('^[0-9a-f]+$') end
local function uuid(s)
  if type(s)~='string' then return false end
  local a,b,c,d,e=s:match('^(%x+)%-(%x+)%-(%x+)%-(%x+)%-(%x+)$')
  return a and #a==8 and #b==4 and #c==4 and #d==4 and #e==12 and s==s:lower()
end
local function scope_key(scope)
  assert(type(scope)=='table' and uuid(scope.campaign_id),'missing-native-campaign-uuid')
  assert(type(scope.player_id)=='string' and #scope.player_id>0 and #scope.player_id<=128 and
    not scope.player_id:find('\0',1,true),'invalid-player-id')
  assert(scope.mode=='free' or scope.mode=='adventure','invalid-mode')
  assert(scope.slot==nil and scope.world==nil,'scope-is-campaign-player-mode')
  return sha(scope.campaign_id..'\0'..scope.player_id..'\0'..scope.mode)
end
local function signature(value)
  local copy=stacks.copy(value);copy.count=nil;return sha(encode(copy))
end
local function ordered(pages)
  local result={};for page in pairs(pages) do result[#result+1]=page end
  table.sort(result,function(a,b) return #a<#b or (#a==#b and a<b) end);return result
end
local function summary(page,definitions)
  local result=state.object({holes=27,room=state.object(),instances=state.object()})
  for _,value in pairs(page) do
    result.holes=result.holes-1
    if value.instance_id then result.instances[value.instance_id]=true end
    local definition=definitions.get(value.content_id)
    local room=definition and definition.stack_limit-value.count or 0
    if room>0 then
      local key=signature(value);result.room[key]=(result.room[key] or 0)+room
    end
  end
  return result
end
M.page_summary=summary
function M.open(directory,scope,definitions,filesystem)
  local key=scope_key(scope)
  local self=setmetatable({io=filesystem or require('storage.file_io'),scope=state.clone(scope),key=key,
    prefix=directory..'/'..key,definitions=definitions,generation=0,raw={},heads={}},M)
  self.paths={self.prefix..'.head-a.json',self.prefix..'.head-b.json'}
  self.retention_path=self.prefix..'.history-retained.json'
  return self
end
function M:blob_path(digest) assert(hash(digest),'invalid-blob-hash');return self.prefix..'.blob-'..digest..'.json' end
function M:checkpoint_path(digest)
  assert(hash(digest),'invalid-player-checkpoint-digest')
  return self.prefix..'.checkpoint-'..digest..'.json'
end
local function retention_record(self)
  return encode({format='pbzmc-player-history-retention',version=1,scope=self.scope})
end
function M:history_retention()
  local raw=self.io.read(self.retention_path,false)
  if not raw then
    assert(not self.history_retained,'missing-player-history-retention')
    return false
  end
  assert(raw==retention_record(self),'invalid-player-history-retention')
  self.history_retained=true
  return true
end
function M:retain_history()
  if self:history_retention() then return end
  local raw=retention_record(self);local path=self.retention_path
  self.io.write(path..'.tmp',raw)
  assert(self.io.read(path..'.tmp',false)==raw,'player-retention-readback-mismatch')
  -- This immutable scope-wide barrier precedes every checkpoint publication.
  -- A stale Store must reread it before deleting any retired blob.
  self.io.rename(path..'.tmp',path)
  self.history_retained=true
  assert(self.io.read(path,false)==raw,'player-retention-readback-unavailable')
end
function M:read_blob(digest)
  local raw=assert(self.io.read(self:blob_path(digest),false),'missing-player-blob')
  assert(sha(raw)==digest,'player-blob-checksum-mismatch')
  return state.decode(raw)
end
function M:write_blob(value)
  local raw=encode(value);local digest=sha(raw);local path=self:blob_path(digest)
  local existing=self.io.read(path,false)
  if existing then assert(existing==raw,'existing-player-blob-mismatch');return digest end
  self.io.write(path..'.tmp',raw)
  assert(self.io.read(path..'.tmp',false)==raw,'player-blob-readback-mismatch')
  self.io.rename(path..'.tmp',path)
  return digest
end
function M:validate_head(head)
  assert(object(head),'invalid-player-head')
  assert(scope_key(head.scope)==self.key,'player-scope-mismatch')
  assert(integer(head.generation) and head.generation>0 and hash(head.core),'invalid-player-head')
  assert(head.history_retained==nil or head.history_retained==true,'invalid-player-history-flag')
  assert(object(head.pages),'invalid-ender-index')
  local instances={}
  for page,entry in pairs(head.pages) do
    slots.address('ender/'..page..'/1')
    assert(object(entry) and hash(entry.blob) and integer(entry.holes) and entry.holes<27,'invalid-page-summary')
    assert(object(entry.room) and object(entry.instances),'invalid-page-index')
    for key,count in pairs(entry.room) do assert(hash(key) and integer(count) and count>0,'invalid-page-room') end
    for id,present in pairs(entry.instances) do
      assert(type(id)=='string' and #id>0 and present==true and not instances[id],'duplicate-indexed-instance')
      instances[id]=true
    end
  end
  return head
end
function M:unpack(raw)
  local envelope=state.decode(raw)
  assert(envelope.format=='pbzmc-player' and envelope.version==1,'unsupported-player-envelope')
  assert(type(envelope.payload)=='string' and sha(envelope.payload)==envelope.sha256,'player-head-checksum-mismatch')
  return self:validate_head(state.decode(envelope.payload))
end
function M:read_page(entry)
  local data=self:read_blob(entry.blob)
  local container=slots.empty();container.ender['1']=data;slots.validate(container,self.definitions)
  local index=summary(data,self.definitions);index.blob=entry.blob
  assert(encode(index)==encode(entry),'page-index-mismatch')
  return data
end
function M:validate_closure(head)
  self:validate_head(head)
  local core=self:read_blob(head.core)
  player.validate(core,self.definitions);assert(next(core.containers.ender)==nil,'pages-in-core')
  self:validate_ownership(core,head.pages,{})
  -- Check every page, including unloaded pages, without retaining all payloads
  -- in memory. Exact summaries plus ownership validation close the reference set.
  for _,page in ipairs(ordered(head.pages)) do self:read_page(head.pages[page]) end
  return core
end
function M:load()
  assert(not self.loaded,'player-store-already-loaded')
  local errors={}
  for i,path in ipairs(self.paths) do
    local ok,head=pcall(function()
      self.raw[i]=self.io.read(path,false)
      if not self.raw[i] then return nil end
      local value=self:unpack(self.raw[i]);local core=self:read_blob(value.core)
      player.validate(core,self.definitions);assert(next(core.containers.ender)==nil,'pages-in-core')
      self:validate_ownership(core,value.pages,{})
      value.loaded_core=core;return value
    end)
    if ok then self.heads[i]=head else errors[#errors+1]='head-'..i..': '..tostring(head) end
  end
  local a,b=self.heads[1],self.heads[2]
  if a and b and a.generation==b.generation and self.raw[1]~=self.raw[2] then
    errors[#errors+1]='conflicting-player-generations';self.heads={}
  end
  for i=1,2 do
    local head=self.heads[i]
    if head and head.history_retained then self.history_retained=true end
    if head and head.generation>self.generation then self.active=i;self.generation=head.generation end
  end
  local retained,retention_error=pcall(self.history_retention,self)
  if not retained then errors[#errors+1]=tostring(retention_error) end
  if not self.active and self.history_retained then errors[#errors+1]='player-history-requires-checkpoint' end
  self.loaded=true;self.read_only=#errors>0;self.warning=self.read_only and table.concat(errors,'; ') or nil
  self.head=self.active and self.heads[self.active] or {pages=state.object()}
  self.core=self.head.loaded_core or player.empty()
  if not self.active and self.read_only then self.head=nil;self.core=nil;return nil,self.warning end
  return state.clone(self.core),self.warning
end
function M:create_checkpoint()
  if not self.loaded or self.read_only or not self.head or not self.head.core then
    return nil,self.warning or 'player-checkpoint-requires-committed-state'
  end
  local ok,result=pcall(function()
    self:check_heads()
    local manifest={format='pbzmc-player-checkpoint',version=1,scope=state.clone(self.scope),
      generation=self.head.generation,core=self.head.core,pages=state.clone(self.head.pages)}
    local valid,why=pcall(self.validate_closure,self,manifest)
    if not valid then self.read_only=true;self.warning=tostring(why);error(why) end
    local raw=encode(manifest);local digest=sha(raw);local path=self:checkpoint_path(digest)
    self:check_heads();self:retain_history()
    local existing=self.io.read(path,false)
    if existing then
      assert(existing==raw,'existing-player-checkpoint-mismatch')
      self:check_heads();return digest
    end
    self.io.write(path..'.tmp',raw)
    assert(self.io.read(path..'.tmp',false)==raw,'player-checkpoint-readback-mismatch')
    self:check_heads()
    self.io.rename(path..'.tmp',path)
    assert(self.io.read(path,false)==raw,'player-checkpoint-readback-unavailable')
    return digest
  end)
  -- On a failure after rename an immutable, pinned orphan can remain. It is
  -- safe to retry idempotently; callers must not publish a host marker on nil.
  if not ok then return nil,tostring(result) end
  return result
end
function M:load_checkpoint(expected_digest)
  assert(not self.loaded,'player-store-already-loaded')
  local ok,core=pcall(function()
    local path=self:checkpoint_path(expected_digest)
    local raw=assert(self.io.read(path,false),'missing-player-checkpoint')
    assert(sha(raw)==expected_digest,'player-checkpoint-checksum-mismatch')
    local manifest=state.decode(raw)
    assert(object(manifest) and manifest.format=='pbzmc-player-checkpoint' and manifest.version==1,
      'unsupported-player-checkpoint')
    local data=self:validate_closure(manifest)
    self.history_retained=true;self:history_retention()
    -- Heads provide only a concurrency fence and the next generation floor.
    -- Neither their core nor their pages replace this exact historical state.
    local errors={};self.generation=manifest.generation
    for i,path in ipairs(self.paths) do
      local read,head=pcall(function()
        self.raw[i]=self.io.read(path,false)
        if self.raw[i] then return self:unpack(self.raw[i]) end
      end)
      if not read then errors[#errors+1]='head-'..i..': '..tostring(head)
      elseif head then
        self.heads[i]=head
        self.generation=math.max(self.generation,head.generation)
        if not self.active or head.generation>self.heads[self.active].generation then self.active=i end
      end
    end
    local a,b=self.heads[1],self.heads[2]
    if a and b and a.generation==b.generation and self.raw[1]~=self.raw[2] then
      errors[#errors+1]='conflicting-player-generations'
    end
    local stable,why=pcall(self.check_heads,self)
    if not stable then errors[#errors+1]=tostring(why) end
    self.head=manifest;self.core=data;self.checkpoint_digest=expected_digest
    self.read_only=#errors>0;self.warning=self.read_only and table.concat(errors,'; ') or nil
    return data
  end)
  self.loaded=true
  if not ok then
    self.read_only=true;self.warning=tostring(core);self.head=nil;self.core=nil
    return nil,self.warning
  end
  return state.clone(core),self.warning
end
function M:validate_ownership(data,pages,replaced)
  player.validate(data,self.definitions)
  local instances={}
  local function own(value)
    if value.instance_id then
      assert(not instances[value.instance_id],'duplicate-owned-item-instance');instances[value.instance_id]=true
    end
  end
  slots.visit(data.containers,function(_,value) own(value) end)
  for _,record in pairs(data.world_items) do own(record.stack) end
  for page,entry in pairs(pages) do
    if not replaced[page] then
      for id in pairs(entry.instances) do
        assert(not instances[id],'duplicate-unloaded-item-instance');instances[id]=true
      end
    end
  end
end
function M:checkout(requested)
  assert(self.loaded and self.core,'player-store-not-loaded')
  local ticket={owner=self,generation=self.generation,pages={},data=state.clone(self.core)}
  if self.runtime_selected then ticket.data.containers.player.selected=self.runtime_selected end
  for page in pairs(requested or {}) do
    slots.address('ender/'..page..'/1');ticket.pages[page]=true
    local entry=self.head.pages[page]
    if entry then
      local ok,values=pcall(self.read_page,self,entry)
      if not ok then self.read_only=true;self.warning=tostring(values);error(self.warning) end
      ticket.data.containers.ender[page]=values
    end
  end
  return ticket
end
function M:pages_for_offer(value)
  stacks.validate(value,self.definitions,{batch=true})
  if native_slot.is(value) then return {} end
  local selected,remaining={},value.count
  local pages=ordered(self.head.pages);local key=signature(value)
  for _,page in ipairs(pages) do
    local room=self.head.pages[page].room[key] or 0
    if room>0 then selected[page]=true;remaining=remaining-room end
    if remaining<=0 then return selected end
  end
  local limit=stacks.limit(value,self.definitions)
  for _,page in ipairs(pages) do
    local holes=self.head.pages[page].holes
    if holes>0 then selected[page]=true;remaining=remaining-holes*limit end
    if remaining<=0 then break end
  end
  return selected
end
function M:transfer_options()
  return {new_ender_page=function(loaded)
    local page=1
    while self.head.pages[tostring(page)] or loaded[tostring(page)] do page=page+1 end
    return page
  end}
end
function M:check_heads()
  for i,path in ipairs(self.paths) do assert(self.io.read(path,false)==self.raw[i],'external-player-save-change') end
end
local function references(head,result)
  if not head then return end
  if head.core then result[head.core]=true end
  for _,entry in pairs(head.pages) do result[entry.blob]=true end
end
function M:commit(ticket,data)
  if not self.loaded or self.read_only then return false,self.warning or 'player-store-not-writable' end
  if ticket.owner~=self or ticket.generation~=self.generation or ticket.consumed then return false,'stale-player-checkout' end
  local destination_index=self.active==1 and 2 or 1
  local destination=self.paths[destination_index]
  local head,core,raw
  local ok,err=pcall(function()
    local replaced={};for page in pairs(ticket.pages) do replaced[page]=true end
    for page in pairs(data.containers.ender) do
      assert(ticket.pages[page] or not self.head.pages[page],'page-outside-checkout');replaced[page]=true
    end
    self:validate_ownership(data,self.head.pages,replaced)
    self:check_heads()
    local retained=self:history_retention()
    head={scope=self.scope,generation=self.generation+1,pages=state.clone(self.head.pages)}
    if retained then head.history_retained=true end
    assert(integer(head.generation),'player-generation-exhausted')
    for page in pairs(replaced) do
      local values=data.containers.ender[page]
      if values and next(values) then
        local entry=summary(values,self.definitions);entry.blob=self:write_blob(values);head.pages[page]=entry
      else head.pages[page]=nil end
    end
    core=state.clone(data);core.containers.ender=state.object()
    head.core=self:write_blob(core)
    local payload=encode(head)
    raw=encode({format='pbzmc-player',version=1,payload=payload,sha256=sha(payload)})
    self.io.write(destination..'.tmp',raw)
    assert(self.io.read(destination..'.tmp',false)==raw,'player-head-readback-mismatch')
    self:unpack(raw);self:check_heads()
    if self.raw[destination_index] then self.io.remove(destination);self.raw[destination_index]=nil end
    self.io.rename(destination..'.tmp',destination)
  end)
  if not ok then return false,tostring(err) end
  -- The head rename above is the commit point. Nothing below may return false.
  local retired={};references(self.heads[destination_index],retired)
  self.raw[destination_index]=raw;self.heads[destination_index]=head;self.head=head;self.core=core
  self.active=destination_index;self.generation=head.generation;ticket.consumed=true
  self.runtime_selected=nil
  local verified,readback=pcall(self.io.read,destination,false)
  if not verified or readback~=raw then
    self.read_only=true;self.warning='player-committed-but-readback-unavailable'
  else
    local checked,history=pcall(self.history_retention,self)
    if not checked then
      self.read_only=true;self.warning='player-committed-history-retention-unavailable'
    elseif not history then
      local retained={};for _,value in pairs(self.heads) do references(value,retained) end
      for digest in pairs(retired) do
        if not retained[digest] then
          -- Delete only a known previous blob, never scan/delete arbitrary files.
          local removed=pcall(self.io.remove,self:blob_path(digest))
          if not removed then self.warning='player-committed-old-blob-retained' end
        end
      end
    end
  end
  return true,self.warning
end
return M
