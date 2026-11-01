-- Closed-container item controls. Inventory has its own slot gestures; it must
-- never feed wheel/number events into this context after the UI closes.
local M={};M.__index=M
local function down(value,bit) return ((value or 0)&(1<<bit))~=0 end
function M.new() return setmetatable({armed=false,wheel=0},M) end
function M:update(pointer,context)
  local output={}
  local stamp=tostring(context.kind)..'/'..tostring(context.weapon_group)..'/'..tostring(context.unified_hotbar)..'/'..tostring(context.epoch)..'/'..tostring(pointer.epoch)
  if not pointer.focused or context.kind~='game' or pointer.overflow or self.context~=stamp then
    self.context=stamp;self.previous=nil;self.armed=false;self.wheel=0
    if not pointer.focused or context.kind~='game' or pointer.overflow then return output end
  end
  if not self.armed then
    if ((pointer.keys or 0)&0x1fff)==0 and (pointer.buttons or 0)==0 then self.armed=true end
    self.previous=pointer;return output
  end
  local old=self.previous or pointer;self.previous=pointer
  local function pressed(bit) return down(pointer.keys,bit) and not down(old.keys,bit) end
  if pressed(22) then return {{kind='open_command'}} end
  if pressed(0) then return {{kind='open_inventory'}} end
  if context.weapon_group~='mc' and not context.unified_hotbar then self.wheel=0;return output end
  for i=1,9 do if pressed(i+3) then output[#output+1]={kind='select_slot',index=i} end end
  -- Native combat keeps its F/Q/middle actions. Only the confirmed MC source
  -- owns item swap/drop/pick; both sources can navigate the mixed hotbar.
  if context.weapon_group=='mc' then
    if pressed(2) then output[#output+1]={kind='swap_selected_offhand'} end
    if pressed(3) then output[#output+1]={kind='drop_selected',count=not pointer.ctrl and 1 or nil} end
    if down(pointer.buttons,2) and not down(old.buttons,2) then output[#output+1]={kind='pick_existing'} end
  end
  local delta=pointer.wheel_delta or 0
  assert(type(delta)=='number' and delta%1==0 and math.abs(delta)<=32768,'invalid-wheel-event')
  self.wheel=self.wheel+delta
  local notches=self.wheel>=0 and math.floor(self.wheel/120) or math.ceil(self.wheel/120)
  self.wheel=self.wheel-notches*120
  if notches~=0 then output[#output+1]={kind='scroll_slots',steps=-notches} end
  return output
end
return M
