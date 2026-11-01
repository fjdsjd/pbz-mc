-- A recoverable last stack, with explicit replacement/close destruction.
-- Trash owns the complete item just like a slot; it is never a copied preview.
local slots=require('rules.container_slots')
local stacks=require('rules.item_stack')
local native=require('rules.native_slot_reference')
local M={}
function M.put(data,source,definitions,count)
  slots.address(source)
  if source=='trash' then return data,false,'already-in-trash' end
  local value=slots.get(data,source)
  if not value then return data,false,'empty-source' end
  -- These references are required entrances to PBZ equipment, not MC items.
  if native.is(value) then return data,false,'native-slot-protected' end
  stacks.validate(value,definitions)
  count=count or value.count
  assert(type(count)=='number' and count%1==0 and count>0 and count<=value.count,'invalid-trash-count')
  local draft=slots.edit(data)
  draft:set('trash',stacks.copy(value,count))
  draft:set(source,stacks.copy(value,value.count-count))
  return draft.data,true
end
function M.clear(data)
  if not data.trash then return data,false end
  local draft=slots.edit(data);draft:set('trash',nil);return draft.data,true
end
return M
