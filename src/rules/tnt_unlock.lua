-- Independent one-time starter unlocks. Container values and unlock flags
-- enter one copy-on-write candidate; native savepoints alone persist it.
local state=require('storage.state')
local slots=require('rules.container_slots')
local M={}
local entries={{key='tnt',id='pbzmc:tnt',marker='tnt_unlocked'},
  {key='flint',id='pbzmc:flint_and_steel',marker='flint_unlocked',instance=true}}
function M.apply(core,campaign_id)
  assert(type(campaign_id)=='string' and #campaign_id>0,'invalid-tnt-unlock-campaign')
  local candidate=core;local draft;local result={}
  for _,entry in ipairs(entries)do
    if candidate[entry.marker] then result[entry.key]={status='unlocked'}
    else
      local existing
      slots.visit(candidate.containers,function(address,item)
        if item.content_id==entry.id then existing=existing or address end
      end)
      local address=existing
      if not address then
        for _,slot in ipairs(slots.player_slots(true))do
          if not slots.get(candidate.containers,slot) then address=slot;break end
        end
      end
      if not address then result[entry.key]={status='inventory-full'}
      else
        if candidate==core then
          candidate=state.object();for key,value in pairs(core)do candidate[key]=value end
        end
        if not existing then
          if not draft then draft=slots.edit(candidate.containers) end
          local item={content_id=entry.id,count=1,metadata=state.object()}
          if entry.instance then item.instance_id='flint-unlock-'..campaign_id end
          draft:set(address,item);candidate.containers=draft.data
        end
        candidate[entry.marker]=true
        result[entry.key]={status=existing and 'existing' or 'granted',address=address}
      end
    end
  end
  return candidate,result
end
return M
