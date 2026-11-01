-- The starter boat and marker become visible in the same in-memory candidate;
-- the existing native savepoint transaction owns persistence.
local state=require('storage.state')
local slots=require('rules.container_slots')
local M={}
function M.apply(core)
  if core.boat_unlocked then return core end
  local existing
  slots.visit(core.containers,function(address,item)
    if item.content_id=='pbzmc:boat' then existing=existing or address end
  end)
  local address=existing
  if not address then
    for _,slot in ipairs(slots.player_slots(true)) do
      if not slots.get(core.containers,slot) then address=slot;break end
    end
  end
  if not address then return core,'boat-unlock-inventory-full' end
  local candidate=state.object();for key,value in pairs(core) do candidate[key]=value end
  if not existing then
    local draft=slots.edit(core.containers)
    draft:set(address,{content_id='pbzmc:boat',count=1,metadata=state.object()})
    candidate.containers=draft.data
  end
  candidate.boat_unlocked=true
  return candidate,address
end
return M
