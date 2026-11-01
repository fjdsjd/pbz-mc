local state=require('storage.state')
local slots=require('rules.container_slots')
local M={}
function M.apply(core)
  if core.pearl_unlocked then return core end
  local existing
  slots.visit(core.containers,function(address,item)if item.content_id=='pbzmc:ender_pearl' then existing=address end end)
  local address=existing
  if not address then for _,a in ipairs(slots.player_slots(true)) do if not slots.get(core.containers,a) then address=a;break end end end
  if not address then return core,'pearl-unlock-inventory-full' end
  local candidate=state.object();for k,v in pairs(core) do candidate[k]=v end
  if not existing then
    local draft=slots.edit(core.containers)
    draft:set(address,{content_id='pbzmc:ender_pearl',count=1,metadata=state.object()});candidate.containers=draft.data
  end
  candidate.pearl_unlocked=true;return candidate,address
end
return M
