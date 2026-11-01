-- Turns foreground pointer edges into container intents. The caller commits
-- each intent through the shared rules/session before the next snapshot.
local ui=require('presentation.item_ui')
local M={};M.__index=M
local function down(bits,bit) return ((bits or 0)&(1<<bit))~=0 end
local function addresses(layout)
  local result={}
  for address in pairs(layout.slots) do if address~='trash' then result[#result+1]=address end end
  table.sort(result,function(a,b)
    local x,y=layout.slots[a],layout.slots[b]
    return x.y==y.y and x.x<y.x or x.y<y.y
  end)
  return result
end
function M.new() return setmetatable({armed=false,wheel=0},M) end
function M:feedback(pointer,data,layout,definitions)
  local result={dragged={}}
  if not pointer.focused or not pointer.inside then result.signature='';return result end
  result.hovered=ui.hover(layout,pointer.x,pointer.y)
  local gesture=self.gesture
  if gesture and not gesture.ignore and not gesture.pickup and data.cursor and #gesture.targets>1 then
    result.preview=require('rules.container_actions').drag(data,gesture.targets,gesture.button,definitions)
    local slots=require('rules.container_slots')
    for _,address in ipairs(gesture.targets) do
      if slots.get(result.preview,address)~=slots.get(data,address) then result.dragged[#result.dragged+1]=address end
    end
    if #result.dragged>0 then
      local share=gesture.button=='right' and 1 or math.floor(data.cursor.count/#result.dragged)
      local stacks=require('rules.item_stack')
      result.count_colors={}
      for _,address in ipairs(result.dragged) do
        local old=slots.get(data,address)
        if (old and old.count or 0)+share>stacks.limit(data.cursor,definitions) then
          result.count_colors[address]={R=1,G=1,B=0,A=1}
        end
      end
    end
  end
  result.signature=(result.hovered or '')..'/'..table.concat(result.dragged,',')
  return result
end
function M:update(pointer,data,layout)
  local requests={}
  self.wheel=self.wheel or 0 -- Existing controller survives a live module refresh.
  if not pointer.focused or pointer.overflow or self.epoch~=pointer.epoch then
    self.epoch=pointer.epoch
    self.armed=false;self.gesture=nil;self.previous=nil;self.last=nil;self.wheel=0;self.wheel_seq=nil
    if not pointer.focused or pointer.overflow then return requests end
  end
  local old=self.previous or pointer;self.previous=pointer
  local function emit(value) requests[#requests+1]=value end
  -- Ignore the opener's held key, but allow a fresh B/Esc edge even while a
  -- gameplay mouse button is still down. Item gestures remain disarmed.
  for _,bit in ipairs({0,1}) do
    if down(pointer.keys,bit) and not down(old.keys,bit) then
      self.gesture=nil;emit({kind='close'});return requests
    end
  end
  if not self.armed then
    if (pointer.buttons or 0)==0 and (pointer.keys or 0)==0 then self.armed=true end
    return requests
  end
  local address=pointer.inside and ui.hit(layout,pointer.x,pointer.y) or nil
  local catalogue=pointer.inside and ui.catalogue_hit(layout,pointer.x,pointer.y) or nil
  local in_catalogue=pointer.inside and ui.catalogue_contains(layout,pointer.x,pointer.y)
  local control=in_catalogue and ui.catalogue_control(layout,pointer.x,pointer.y)
  local delta=pointer.wheel_delta or 0
  assert(type(delta)=='number' and delta%1==0 and math.abs(delta)<=32768,'invalid-inventory-wheel')
  local fresh=pointer.seq==nil or pointer.seq~=self.wheel_seq;self.wheel_seq=pointer.seq
  if in_catalogue and not self.gesture and (pointer.buttons or 0)==0 then
    if fresh then self.wheel=self.wheel+delta end
    local steps=self.wheel>=0 and math.floor(self.wheel/120)or math.ceil(self.wheel/120)
    self.wheel=self.wheel-steps*120
    if steps~=0 then emit({kind='catalogue_page',steps=-steps})end
  else self.wheel=0 end
  if catalogue and not self.gesture then
    for i=1,9 do
      if down(pointer.keys,i+3) and not down(old.keys,i+3) then
        emit({kind='catalogue_take',content_id=catalogue,index=i})
      end
    end
  end
  if address and not self.gesture then
    for i=1,9 do
      if down(pointer.keys,i+3) and not down(old.keys,i+3) then emit({kind='hotbar_swap',address=address,index=i}) end
    end
    if down(pointer.keys,2) and not down(old.keys,2) then emit({kind='offhand_swap',address=address}) end
  end
  if down(pointer.keys,3) and not down(old.keys,3) then
    local target=data.cursor and 'cursor' or address
    if target then emit({kind='drop',address=target,count=not pointer.ctrl and 1 or nil}) end
  end
  for bit=0,1 do
    local held,was=down(pointer.buttons,bit),down(old.buttons,bit)
    local button=bit==0 and 'left' or 'right'
    if held and not was and not self.gesture then
      local gesture={button=button,bit=bit,origin=address,targets={},seen={},pickup=not data.cursor}
      self.gesture=gesture
      if control then
        if bit==0 then emit(control)end
        gesture.ignore=true;self.last=nil
      elseif catalogue then
        -- The catalogue is an item source, not a delete/replace target.
        -- Holding any stack preserves it until placed in a real container.
        if not data.cursor then emit({kind='catalogue_take',content_id=catalogue})end
        gesture.ignore=true;self.last=nil
      elseif in_catalogue then
        gesture.ignore=true;self.last=nil
      elseif bit==0 and pointer.ctrl and address and address~='trash' then
        emit({kind='trash',address=address});gesture.ignore=true;self.last=nil
      elseif pointer.shift and address then
        emit({kind='shift',address=address});gesture.ignore=true;self.last=nil
      elseif address=='trash' then
        -- An explicit click may replace trash, but a drag crossing it must not.
        emit({kind='click',address=address,button=button});gesture.ignore=true;self.last=nil
      elseif bit==0 and data.cursor and self.last and self.last.address==address and address
          and pointer.time_ms>=self.last.time and pointer.time_ms-self.last.time<=250 then
        emit({kind='gather',addresses=addresses(layout)});gesture.ignore=true;self.last=nil
      elseif gesture.pickup and address then
        emit({kind='click',address=address,button=button})
      end
    end
    local gesture=self.gesture
    if gesture and gesture.bit==bit and not gesture.ignore then
      if held and not gesture.pickup and address and address~='trash' and not gesture.seen[address] then
        gesture.seen[address]=true;gesture.targets[#gesture.targets+1]=address
      end
      if not held and was then
        if gesture.pickup then
          -- The press already picked up the stack. Releasing at another slot
          -- must not implicitly place it or consume the following rapid click.
        elseif #gesture.targets>1 then
          emit({kind='drag',addresses=gesture.targets,button=button})
        elseif #gesture.targets==1 then
          -- A queued release may arrive with the pointer already moved toward
          -- the next click. Preserve the slot selected while actually held.
          emit({kind='click',address=gesture.targets[1],button=button})
        elseif not address and pointer.inside and not in_catalogue then
          local r=layout.inventory
          if pointer.x<r.x or pointer.y<r.y or pointer.x>=r.x+r.w or pointer.y>=r.y+r.h then
            emit({kind='drop',address='cursor',count=button=='right' and 1 or nil})
          end
        end
        local clicked=gesture.pickup and gesture.origin or (#gesture.targets==1 and gesture.targets[1] or nil)
        self.last=clicked and {address=clicked,time=pointer.time_ms} or nil
      end
    end
    if gesture and gesture.bit==bit and not held and was then self.gesture=nil end
  end
  return requests
end
return M
