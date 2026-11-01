-- Infinite supply is a policy, never Infinity/large counts or replenishment.
local blocks=require('content.blocks')
local slots=require('rules.container_slots')
local state=require('storage.state')
local M={}
function M.infinite(stack)
  local definition=stack and blocks.get(stack.content_id)
  return definition and definition.available and definition.infinite or false
end
function M.take(data,id,address,definitions)
  assert(M.infinite({content_id=id}),'catalogue-content-unavailable')
  address=address or 'cursor'
  assert(address=='cursor' or address:match('^player/hotbar/[1-9]$'),'catalogue-target-invalid')
  local old=slots.get(data,address)
  if address=='cursor' and old then return data,'catalogue-target-occupied' end
  if old and not M.infinite(old) then return data,'catalogue-target-occupied' end
  if old and old.content_id==id and old.count==1 then return data end
  local draft=slots.edit(data)
  draft:set(address,{content_id=id,count=1,metadata=state.object()})
  slots.validate(draft.data,definitions)
  return draft.data
end
function M.clear(data,address)
  if not M.infinite(slots.get(data,address)) then return data end
  local draft=slots.edit(data);draft:set(address,nil);return draft.data
end
return M
