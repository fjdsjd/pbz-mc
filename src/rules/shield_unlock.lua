-- One starter shield; item and unlock flag share the savepoint memory transaction.
local state=require('storage.state')
local slots=require('rules.container_slots')
local M={}
function M.apply(core,campaign_id)
  if core.shield_unlocked then return core end
  local existing
  slots.visit(core.containers,function(address,value)
    if value.content_id=='pbzmc:shield' then existing=address end
  end)
  local destination
  if not existing then
    if not slots.get(core.containers,'player/offhand') then destination='player/offhand' end
    if not destination then
      for _,address in ipairs(slots.player_slots(true)) do
        if not slots.get(core.containers,address) then destination=address;break end
      end
    end
    if not destination then return core,'shield-unlock-inventory-full' end
  end
  local candidate=state.object();for k,v in pairs(core) do candidate[k]=v end
  candidate.shield_unlocked=true
  if destination then
    local draft=slots.edit(core.containers)
    draft:set(destination,{content_id='pbzmc:shield',count=1,metadata=state.object(),
      instance_id='shield-unlock-'..campaign_id})
    candidate.containers=draft.data
  end
  return candidate,destination or existing
end
return M
