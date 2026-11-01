-- Small owner registry for appearance lifecycle. Policies supply an authorized
-- player identity; the registry never scans or replaces arbitrary NPC classes.
local M={};M.__index=M
function M.new(host)
  return setmetatable({host=host,entries={},closed=false},M)
end
function M:observe(actor,reason)
  assert(not self.closed,'appearance-registry-closed')
  local key=self.host:key(actor)
  local existing=self.entries[key]
  if existing and existing.binding and self.host:current(existing.binding) then return existing.binding end
  local entry=existing or {actor=actor}
  self.entries[key]=entry -- retain authorized identity if creation needs retry
  if entry.binding then self.host:release(entry.binding);entry.binding=nil end
  local binding=self.host:bind(actor,reason)
  entry.binding=binding
  return binding
end
function M:forget(actor)
  local key=self.host:key(actor)
  local entry=self.entries[key]
  if not entry then return end
  if entry.binding then self.host:release(entry.binding) end
  self.entries[key]=nil
end
function M:tick()
  if self.closed then return end
  local failures={}
  for key,entry in pairs(self.entries) do
    local ok,why=pcall(function()
      if not self.host:alive(entry.actor) then
        if entry.binding then self.host:release(entry.binding) end
        self.entries[key]=nil
      elseif not entry.binding or not self.host:current(entry.binding) then
        -- Release/rebind synchronously in one game-thread callback, before render.
        if entry.binding then self.host:release(entry.binding);entry.binding=nil end
        entry.binding=self.host:bind(entry.actor,'mesh-reconstruction')
      else self.host:update(entry.binding) end
    end)
    if not ok then failures[#failures+1]=tostring(why) end
  end
  return #failures==0,table.concat(failures,'; ')
end
function M:close()
  self.closed=true
  local failures={}
  for key,entry in pairs(self.entries) do
    local ok,err=true,nil
    if entry.binding then ok,err=pcall(self.host.release,self.host,entry.binding) end
    if ok then self.entries[key]=nil else failures[#failures+1]=tostring(err) end
  end
  return #failures==0,table.concat(failures,'; ')
end
return M
