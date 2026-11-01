-- P22/P23: scoped, checksummed two-generation journal. One in-process writer.
-- Never replaces the active generation. Corrupt slots require explicit recovery.
local json=require('dkjson')
local state=require('storage.state')
local sha256=require('storage.sha256')
local M={};M.__index=M
local function scope_key(scope)
  assert(type(scope)=='table' and (scope.mode=='free' or scope.mode=='adventure'),'invalid-mode')
  assert(type(scope.slot)=='string' and #scope.slot>0 and #scope.slot<1024 and not scope.slot:find('\0',1,true),'invalid-slot')
  assert(scope.world==nil,'world-belongs-in-building-records')
  -- Inventory is shared across maps. A single commit contains that inventory
  -- and every map's buildings, rather than duplicating inventory per map.
  return sha256(scope.slot..'\0'..scope.mode)
end
function M.open(directory,scope,filesystem)
  local self=setmetatable({io=filesystem or require('storage.file_io'),scope=state.clone(scope),
    generation=0,active=nil,raw={},loaded=false,read_only=false},M)
  self.key=scope_key(scope)
  self.paths={directory..'/'..self.key..'.a.json',directory..'/'..self.key..'.b.json'}
  return self
end
function M:unpack(raw)
  local envelope=state.decode(raw)
  assert(envelope.format=='pbzmc-builds' and envelope.version==1,'unsupported-envelope')
  assert(scope_key(envelope.scope)==self.key,'scope-mismatch')
  assert(type(envelope.generation)=='number' and envelope.generation%1==0 and envelope.generation>0 and envelope.generation<2^53,'invalid-generation')
  assert(type(envelope.payload)=='string' and sha256(envelope.payload)==envelope.sha256,'checksum-mismatch')
  local data=state.decode(envelope.payload)
  state.validate(data)
  return {generation=envelope.generation,data=data}
end
function M:load()
  assert(not self.loaded,'store-already-loaded')
  local slots,errors={},{}
  for i,path in ipairs(self.paths) do
    local ok,raw=pcall(self.io.read,path)
    if ok then self.raw[i]=raw end
    if not ok then errors[#errors+1]='slot-'..i..': '..tostring(raw)
    elseif raw then
      local valid,value=pcall(self.unpack,self,raw)
      if valid then slots[i]=value else errors[#errors+1]='slot-'..i..': '..tostring(value) end
    end
  end
  if slots[1] and slots[2] and slots[1].generation==slots[2].generation and self.raw[1]~=self.raw[2] then
    errors[#errors+1]='conflicting-generations'
    slots={}
  end
  self.loaded=true
  self.read_only=#errors>0
  self.warning=self.read_only and table.concat(errors,'; ') or nil
  for i=1,2 do
    if slots[i] and slots[i].generation>self.generation then self.active=i;self.generation=slots[i].generation end
  end
  if not self.active then
    if self.read_only then return nil,self.warning end
    return state.empty()
  end
  return slots[self.active].data,self.warning
end
function M:commit(data)
  if not self.loaded or self.read_only then return false,self.warning or 'store-not-writable' end
  local next_index=self.active==1 and 2 or 1
  local destination=self.paths[next_index]
  local temporary=destination..'.tmp'
  local next_generation=self.generation+1
  local raw
  local ok,err=pcall(function()
    state.validate(data)
    assert(next_generation<2^53,'generation-exhausted')
    local payload=json.encode(data)
    raw=json.encode({format='pbzmc-builds',version=1,generation=next_generation,
      scope=self.scope,sha256=sha256(payload),payload=payload})
    assert(#raw<=16*1024*1024,'save-too-large')
    -- Detect edits/recovery by another process before touching either generation.
    for i,path in ipairs(self.paths) do assert(self.io.read(path)==self.raw[i],'external-save-change') end
    self.io.write(temporary,raw)
    assert(self.io.read(temporary)==raw,'temporary-readback-mismatch')
    self:unpack(raw)
    if self.raw[next_index] then self.io.remove(destination);self.raw[next_index]=nil end
    self.io.rename(temporary,destination)
  end)
  if not ok then return false,tostring(err) end
  -- Rename is the commit point. Never return failure afterwards: callers would
  -- incorrectly roll back a world change already recorded on disk.
  self.active=next_index;self.generation=next_generation;self.raw[next_index]=raw
  local verified,readback=pcall(self.io.read,destination)
  if not verified or readback~=raw then
    self.read_only=true;self.warning='committed-but-readback-unavailable'
  end
  return true,self.warning
end
return M
