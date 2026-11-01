-- A movable UI reference, never a copy of a PBZ weapon. Only category and
-- native slot position persist; names/icons/equipment are resolved afresh.
local state=require('storage.state')
local M={content_id='pbz:slot_reference'}
local prefix='pbz-slot/'
local categories={main=true,shaqi=true}
local function integer(value)
  return type(value)=='number' and value%1==0 and value>=0 and value<=2147483647
end
local function identity(category,index)
  assert(categories[category] and integer(index),'invalid-native-slot-key')
  -- This bound is the native signed index representation, not a slot capacity.
  return prefix..category..'/'..string.format('%d',index)
end
local function exact(value,keys)
  assert(type(value)=='table' and state.json_kind(value)=='object','invalid-native-slot-record')
  for key in pairs(value) do assert(keys[key],'unknown-native-slot-field:'..tostring(key)) end
  for key in pairs(keys) do assert(value[key]~=nil,'missing-native-slot-field:'..key) end
end
function M.is(value) return type(value)=='table' and value.content_id==M.content_id end
function M.validate(value)
  exact(value,{content_id=true,count=true,instance_id=true,metadata=true})
  assert(value.content_id==M.content_id and value.count==1,'invalid-native-slot-reference')
  exact(value.metadata,{category=true,native_slot_index=true})
  assert(value.instance_id==identity(value.metadata.category,value.metadata.native_slot_index),'native-slot-identity-mismatch')
  state.validate_value(value);return true
end
function M.assert_unreserved(value)
  assert(type(value.instance_id)~='string' or value.instance_id:sub(1,#prefix)~=prefix,'reserved-native-slot-identity')
end
function M.new(category,index)
  local id=identity(category,index)
  return state.object({content_id=M.content_id,count=1,instance_id=id,
    metadata=state.object({category=category,native_slot_index=index})})
end
function M.accepts_area(area) return area=='main' or area=='hotbar' or area=='cursor' end
function M.resolve(value,snapshot,epoch)
  M.validate(value)
  if type(epoch)~='number' or epoch%1~=0 or epoch<0 or epoch>=2^53 or
      type(snapshot)~='table' or snapshot.epoch~=epoch or
      snapshot.source~='pbz-backpack-declared-v1' or snapshot.selection_scope~='backpack-declared' then
    return nil,'native-slot-snapshot-unavailable'
  end
  local category,index=value.metadata.category,value.metadata.native_slot_index
  local values=category=='main' and snapshot.main_weapons or snapshot.shaqi_weapons
  local equipment_id=type(values)=='table' and values[index+1] or nil
  if type(equipment_id)~='string' or equipment_id=='' or equipment_id:lower()=='none' then
    return nil,'native-slot-empty-or-unavailable'
  end
  -- This is only a display/request target. Neither cached current indices nor
  -- this declaration prove unlocked capacity or a completed combat switch.
  return {kind='pbz-slot',category=category,native_slot_index=index,equipment_id=equipment_id,
    epoch=epoch,selection_scope='backpack-declared',combat_commit_verified=false}
end
return M
