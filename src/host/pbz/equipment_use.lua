-- Immediate same-hand equipment exchange, in the existing RAM transaction.
-- No hidden spare slot, world drop, durability write, save or input reset.
local M={}
function M.use(binding,record)
 local campaign=require('host.pbz.campaign_inventory')
 if not binding:is_current()or not campaign.current(binding)then return false,'fail'end
 local s=campaign.ensure(binding)
 if s.restart_frozen or s.session.busy then return false,'fail'end
 -- Number/wheel selection is an O(1) overlay until a content transaction or
 -- savepoint folds it into core. Use that same view as the HUD/action owner;
 -- core.player.selected can still point at an entirely different old item.
 local data=require('runtime.hotbar_selection').view(s.store)
 local address=record.hand=='offhand'and 'player/offhand'or record.hand=='main'and 'player/hotbar/'..data.player.selected
 if not address then return false,'fail'end
 local current=require('rules.container_slots').get(data,address)
 local expected=record.equipment and record.equipment[record.hand]
 if not current or not expected or require('storage.canonical_json')(current)~=require('storage.canonical_json')(expected)then return false,'fail'end
 local ticket=s.store:checkout({})
 local next,outcome=require('rules.equip_item').apply(ticket.data.containers,address)
 if next==ticket.data.containers then return false,outcome.result end
 local candidate=require('storage.state').object();for key,value in pairs(ticket.data)do candidate[key]=value end
 candidate.containers=next
 local ok,why=s.session:commit(ticket,candidate)
 if not ok then binding.log('MC equipment use rejected: '..tostring(why));return false,'fail'end
 M.last={item=expected.content_id,hand=record.hand,action_id=record.action_id,revision=s.store.generation,
  source=address,target=outcome.target,displaced_item=outcome.displaced_content_id}
 return true,'success'
end
return M
