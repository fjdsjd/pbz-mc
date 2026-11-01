-- Actual free-mode starter items, committed once with the campaign inventory.
local state=require('storage.state')
local slots=require('rules.container_slots')
local M={}
function M.apply(core)
 if core.recovery_items_unlocked then return core end
 local next=state.object();for k,v in pairs(core) do next[k]=v end
 local draft=slots.edit(core.containers)
 for _,id in ipairs({'golden_apple','enchanted_golden_apple','totem_of_undying'}) do
  local exists=false
  slots.visit(draft.data,function(_,s)if s.content_id=='pbzmc:'..id then exists=true end end)
  if not exists then
   local address
   for _,a in ipairs(slots.player_slots(true)) do if not slots.get(draft.data,a) then address=a;break end end
   if not address then return core end
   draft:set(address,{content_id='pbzmc:'..id,count=id=='totem_of_undying' and 1 or 8,metadata=state.object()})
  end
 end
 next.containers=draft.data;next.recovery_items_unlocked=true;return next
end
return M
