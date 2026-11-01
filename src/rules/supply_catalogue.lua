-- Supplies remain finite stacks. Taking a stack never replaces owned items,
-- changes cooldowns or writes a save checkpoint.
local slots=require('rules.container_slots')
local state=require('storage.state')
local definitions=require('content.items')
local ids=require('content.catalogue_groups').supplies
local available={};local M={}
for _,id in ipairs(ids)do
 local row=assert(definitions.get(id),'supply-definition-required:'..id)
 assert(not available[id]and not row.instance and not row.kind,'invalid-supply-catalogue:'..id)
 available[id]=true
end
function M.list()return ids end
function M.available(id)return available[id]==true end
function M.take(data,id,address)
 assert(M.available(id),'catalogue-content-unavailable')
 address=address or'cursor'
 assert(address=='cursor'or address:match('^player/hotbar/[1-9]$'),'catalogue-target-invalid')
 if slots.get(data,address)then return data,'catalogue-target-occupied'end
 local draft=slots.edit(data)
 draft:set(address,{content_id=id,count=1,metadata=state.object()})
 slots.validate(draft.data,definitions)
 return draft.data
end
return M
