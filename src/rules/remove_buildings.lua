-- One durable commit for a connected group, with reversible native hiding.
local state=require('storage.state')
local function copy(value)local out={};for k,v in pairs(value or {})do out[k]=v end;return out end
return function(session,ids,host,store,allow_pending)
  if session.expand_removals then ids=session.expand_removals(ids)end
  if session.quarantined or session.busy or session.closed then return false,'session-unavailable' end
  if #ids==0 or #ids>1024 then return false,'invalid-building-group' end
  local candidate=copy(session.data);candidate.buildings=copy(session.data.buildings)
  local handles,seen,changes={},{},{}
  for _,id in ipairs(ids) do
    local r,h=candidate.buildings[id],session.handles[id]
    local pending=false
    if not h and allow_pending then for _,queued in ipairs(session.pending)do if queued==id then pending=true;break end end end
    if seen[id] or not r or not h and not pending or r.world~=session.world then return false,'invalid-building-group-member' end
    seen[id]=true;if h then handles[#handles+1]=h end;candidate.buildings[id]=nil
    changes[#changes+1]={before=session.data.buildings[id]}
  end
  session.busy=true;local attempted={};local generation=session.generation
  local ok,why=pcall(function()
    for _,h in ipairs(handles) do
      attempted[#attempted+1]=h;assert(host:set_active(h,false),'group-deactivate-failed')
    end
    assert(session.generation==generation and host:is_current(),'scene-changed')
    -- The delta store caps one lightweight ticket at 128 entries. A larger
    -- connected demolition is still one atomic action, never a truncated
    -- list or an endlessly rejected delta; use its existing full commit.
    local saved,err=store:commit(candidate,#changes<=128 and changes or nil);assert(saved,err or 'durable-commit-failed')
  end)
  if not ok then
    local pending={}
    for _,h in ipairs(attempted) do
      local restored,active=pcall(host.set_active,host,h,true)
      if not restored or active~=true then pending[#pending+1]=h end
    end
    if #pending>0 then session.pending_group=pending;session.group_action='activate';session.quarantined=true end
    session.busy=false;return false,tostring(why)
  end
  session.data=candidate
  for _,id in ipairs(ids) do session.handles[id]=nil end
  if allow_pending then
    for i=#session.pending,1,-1 do if seen[session.pending[i]]then
      if session.reservations then session.reservations:remove(session.pending[i])end
      table.remove(session.pending,i)
    end end
  end
  session.pending_group=handles;session.group_action='destroy';session.quarantined=true;session.busy=false
  if session.notify then session:notify(changes)end
  return true,#ids
end
