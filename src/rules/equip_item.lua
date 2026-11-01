-- MC 1.21.1 Equipment.equipAndSwap, with unique PBZ equipment instances.
-- Candidate-only transaction. The active hand and its armor slot exchange
-- complete stacks; no inventory hole, item creation, count debit or durability.
local slots=require('rules.container_slots')
local stacks=require('rules.item_stack')
local native_slot=require('rules.native_slot_reference')
local canonical=require('storage.canonical_json')
local default_definitions=require('content.items')
local armor_slots={head=true,chest=true,legs=true,feet=true}
local M={}

local function receipt(result,reason,source,target,value,old)
  return {result=result,reason=reason,changed=result=='success',source=source,target=target,
    content_id=value and value.content_id,instance_id=value and value.instance_id,
    displaced_content_id=old and old.content_id,displaced_instance_id=old and old.instance_id}
end

function M.target(value,definitions)
  if not value then return nil end
  definitions=definitions or default_definitions
  stacks.validate(value,definitions)
  if native_slot.is(value)then return nil end
  local definition=assert(definitions.get(value.content_id),'equip-content-unavailable')
  local slot=definition.equipment_slot
  if not slot then return nil end
  assert(armor_slots[slot] and definition.instance==true and definition.stack_limit==1,'invalid-equip-definition')
  -- Content definition metadata owns the slot. Untrusted per-stack metadata
  -- cannot redirect a helmet to the chest or turn a block into armor.
  return 'player/armor/'..slot
end

function M.apply(data,source,definitions,options)
  definitions=definitions or default_definitions;options=options or {}
  assert(type(options)=='table','invalid-equip-options')
  for _,key in ipairs({'can_use_slot','prevent_armor_change'})do
    assert(options[key]==nil or type(options[key])=='boolean','invalid-equip-option:'..key)
  end
  local area,index=slots.address(source)
  local held=area=='offhand' or area=='hotbar' and type(data)=='table' and type(data.player)=='table'
    and tonumber(index)==data.player.selected
  if not held then return data,receipt('pass','not-held-slot',source) end
  local value=slots.get(data,source)
  if not value then return data,receipt('pass','empty-hand',source) end
  local target=M.target(value,definitions)
  if not target then return data,receipt('pass','not-equippable-armor',source,nil,value) end
  if options.can_use_slot==false then return data,receipt('pass','equipment-slot-unavailable',source,target,value) end

  -- Validate unique ownership before copying either side. Unknown unrelated
  -- archived items remain untouched, but both exchanged values must be known.
  slots.validate(data,definitions)
  local old=slots.get(data,target)
  if old then
    stacks.validate(old,definitions)
    assert(slots.accepts(target,old,definitions),'equipped-item-in-wrong-slot')
    if options.prevent_armor_change then
      return data,receipt('fail','armor-change-prevented',source,target,value,old)
    end
    -- Vanilla compares count/item/components, not an inventory instance ID.
    -- Equivalent pristine copies therefore FAIL; differing components can swap.
    if value.content_id==old.content_id and value.count==old.count
      and canonical(value.metadata)==canonical(old.metadata)then
      return data,receipt('fail','same-item-and-components',source,target,value,old)
    end
  end
  assert(slots.accepts(target,value,definitions) and slots.accepts(source,old,definitions),'equip-slot-rejected')
  local draft=slots.edit(data)
  draft:set(source,old)
  draft:set(target,value)
  slots.validate(draft.data,definitions)
  return draft.data,receipt('success',old and 'swapped' or 'equipped',source,target,value,old)
end

return M
