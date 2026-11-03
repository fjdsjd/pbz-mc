-- Private to committed in-memory cores. Game-facing checkouts and saves get
-- ordinary, detached JSON objects through state.clone. Small maps stay flat.
local state=require('storage.state')
local M={}
local page_count,flat_limit=64,256
local function bucket(id)
  local h=2166136261
  for i=1,#id do h=((h ~ id:byte(i))*16777619) & 0xffffffff end
  return ((h ~ (h>>16)) & (page_count-1))+1
end
local function lookup(map,id)
  if type(id)~='string'then return nil end
  local page=getmetatable(map).pages[bucket(id)]
  return page and page[id]
end
local function each(map)
  local pages=getmetatable(map).pages
  local i,page,key=0
  return function()
    while true do
      if page then
        local value
        key,value=next(page,key)
        if key then return key,value end
      end
      i=i+1
      if i>page_count then return end
      page=pages[i];key=nil
    end
  end
end
local function readonly()error('committed-building-map-is-read-only')end
local function publish(pages,count)
  return setmetatable({},{__jsontype='object',__index=lookup,__pairs=each,__newindex=readonly,pages=pages,count=count})
end
function M.updated(map,updates,delta)
  local meta=getmetatable(map)
  if not meta or meta.__index~=lookup then
    local flat=state.object();local count=delta
    for id,record in pairs(map)do flat[id]=record;count=count+1 end
    assert(count>=0 and count<=8192,'excessive-building-records')
    for id,record in pairs(updates)do flat[id]=record or nil end
    if count<=flat_limit then return flat end
    local pages={}
    for id,record in pairs(flat)do
      local i=bucket(id)
      if not pages[i]then pages[i]={}end
      pages[i][id]=record
    end
    return publish(pages,count)
  end
  local count=meta.count+delta
  assert(count>=0 and count<=8192,'excessive-building-records')
  local pages={};table.move(meta.pages,1,page_count,1,pages)
  local copied={}
  for id,record in pairs(updates)do
    local i=bucket(id)
    if not copied[i]then
      local page={}
      if pages[i]then for k,v in pairs(pages[i])do page[k]=v end end
      pages[i]=page;copied[i]=true
    end
    pages[i][id]=record or nil
  end
  return publish(pages,count)
end
return M
