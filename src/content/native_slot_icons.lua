-- Every PBZ slot uses the original MC iron sword, independent of its contents.
-- Only the numbered reference and live localized name describe native gear.
local M={}
function M.get() return {icon='pbzmc:iron_sword'} end
-- Slot numbers belong to PBZ's equipment positions, not the current MC hotbar
-- position. Re-resolve their contents from the supplied authoritative snapshot.
function M.describe(value,snapshot,epoch)
  local refs=require('rules.native_slot_reference')
  refs.validate(value)
  local main=value.metadata.category=='main'
  local number=value.metadata.native_slot_index+1
  local result={number=number,badge=(main and 'P' or 'S')..number,icon='pbzmc:iron_sword',
    slot_name=(main and '主武器槽 ' or '煞器槽 ')..number,state='unavailable'}
  local resolved,why=refs.resolve(value,snapshot,epoch)
  if resolved then
    result.equipment_id=resolved.equipment_id
    local names=type(snapshot.weapon_names)=='table' and snapshot.weapon_names[value.metadata.category]
    local name=type(names)=='table' and names[number]
    if type(name)=='string' and name:match('%S') then result.equipment_name=name end
    result.state='equipped'
  elseif why=='native-slot-empty-or-unavailable' then
    local values=main and snapshot.main_weapons or snapshot.shaqi_weapons
    local id=type(values)=='table' and values[number]
    if type(id)=='string' and (id=='' or id:lower()=='none') then result.state='empty' end
  end
  local detail=result.equipment_name or (result.state=='empty' and '空槽' or result.state=='unavailable' and '未就绪')
  result.label=result.slot_name..(detail and '：'..detail or '')
  return result
end
return M
