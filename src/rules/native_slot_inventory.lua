-- Reconcile movable PBZ slot references against a fresh declared-equipment
-- snapshot. This never creates, removes or changes a native PBZ weapon.
local slots=require('rules.container_slots')
local native=require('rules.native_slot_reference')
local M={}
-- options.categories is an optional {main=true,shaqi=true} set for additions
-- only. Existing references still reconcile against the complete snapshot.
-- defer_additions keeps unavailable additions pending instead of failing a
-- full inventory. Neither option changes the caller's configuration or items.
function M.refresh(containers,snapshot,epoch,definitions,options)
  assert(type(epoch)=='number' and epoch>=0 and epoch<2^53 and epoch%1==0
    and type(snapshot)=='table' and snapshot.epoch==epoch
    and snapshot.source=='pbz-backpack-declared-v1' and snapshot.selection_scope=='backpack-declared'
    and type(snapshot.main_weapons)=='table' and type(snapshot.shaqi_weapons)=='table',
    'native-slot-refresh-snapshot-required')
  assert(options==nil or type(options)=='table','native-slot-refresh-invalid-options')
  options=options or {}
  for key in pairs(options) do
    assert(key=='categories' or key=='defer_additions' or key=='skip_selected_empty','native-slot-refresh-unknown-option')
  end
  assert(options.defer_additions==nil or type(options.defer_additions)=='boolean',
    'native-slot-refresh-invalid-defer-option')
  assert(options.skip_selected_empty==nil or type(options.skip_selected_empty)=='boolean',
    'native-slot-refresh-invalid-selected-option')
  local categories=options.categories
  assert(categories==nil or type(categories)=='table','native-slot-refresh-invalid-categories')
  if categories then
    for category,enabled in pairs(categories) do
      assert((category=='main' or category=='shaqi') and type(enabled)=='boolean',
        'native-slot-refresh-invalid-category')
    end
  end
  slots.validate(containers,definitions)
  local expected,ordered,total={},{},0
  for _,group in ipairs({{'main',snapshot.main_weapons},{'shaqi',snapshot.shaqi_weapons}}) do
    for i,id in ipairs(group[2]) do
      assert(type(id)=='string','native-slot-refresh-invalid-equipment-name')
      if id~='' and id:lower()~='none' then
        local reference=native.new(group[1],i-1)
        expected[reference.instance_id]=reference;total=total+1
        if not categories or categories[group[1]]==true then ordered[#ordered+1]=reference end
      end
    end
  end
  local addresses={}
  for i=1,9 do addresses[#addresses+1]='player/hotbar/'..i end
  for i=1,27 do addresses[#addresses+1]='player/main/'..i end
  addresses[#addresses+1]='cursor'
  local edit=slots.edit(containers);local seen,removed,added,pending={},0,0,0
  for _,address in ipairs(addresses) do
    local value=slots.get(containers,address)
    if native.is(value) then
      assert(not seen[value.instance_id],'native-slot-refresh-duplicate-reference')
      seen[value.instance_id]=true
      if not expected[value.instance_id] then edit:set(address,nil);removed=removed+1 end
    end
  end
  for _,reference in ipairs(ordered) do
    if not seen[reference.instance_id] then
      local destination
      for _,address in ipairs(addresses) do
        if address~='cursor' and not slots.get(edit.data,address)
          and not (options.skip_selected_empty and address=='player/hotbar/'..containers.player.selected)
          then destination=address;break end
      end
      if destination then edit:set(destination,reference);added=added+1
      else
        assert(options.defer_additions,'native-slot-refresh-no-space')
        pending=pending+1
      end
    end
  end
  slots.validate(edit.data,definitions)
  return (added>0 or removed>0) and edit.data or containers,
    {added=added,removed=removed,total=total,pending=pending}
end
return M
