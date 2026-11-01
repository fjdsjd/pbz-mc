-- UI intents return candidates. No native input, save writes or world spawning.
local slots=require('rules.container_slots')
local stacks=require('rules.item_stack')
local transfer=require('rules.container_transfer')
local M={}
function M.swap(data,a,b,definitions)
  local left,right=slots.get(data,a),slots.get(data,b)
  if a==b then return data,false end
  if left then stacks.validate(left,definitions) end
  if right then stacks.validate(right,definitions) end
  if not slots.accepts(a,right,definitions) or not slots.accepts(b,left,definitions) then return data,false end
  local draft=slots.edit(data);draft:set(a,right);draft:set(b,left);return draft.data,true
end
function M.click(data,address,button,definitions)
  assert(address~='cursor','cursor-is-not-click-target')
  assert(button=='left' or button=='right','invalid-mouse-button')
  local value=slots.get(data,address)
  local cursor=data.cursor
  if value then stacks.validate(value,definitions) end
  if cursor then stacks.validate(cursor,definitions) end
  if not cursor then
    if not value then return data,false end
    local n=button=='left' and value.count or math.ceil(value.count/2)
    local candidate,moved=transfer.move(data,address,{'cursor'},n,definitions)
    return candidate,moved>0
  end
  if not slots.accepts(address,cursor,definitions) then return data,false end
  if address=='trash' then
    return require('rules.inventory_trash').put(data,'cursor',definitions,button=='right' and 1 or nil)
  end
  if not value or stacks.compatible(cursor,value) then
    local candidate,moved=transfer.move(data,'cursor',{address},button=='right' and 1 or cursor.count,definitions)
    return candidate,moved>0
  end
  return M.swap(data,'cursor',address,definitions)
end
function M.gather(data,addresses,definitions)
  local cursor=data.cursor
  if not cursor then return data,0 end
  stacks.validate(cursor,definitions)
  local draft=slots.edit(data)
  local total=0
  local seen={}
  -- MC double-click takes partial stacks before full stacks, in screen order.
  for pass=1,2 do
    for _,address in ipairs(addresses) do
      slots.address(address)
      local value=draft:get(address)
      if address~='cursor' and address~='trash' and not seen[address] and value and stacks.compatible(cursor,value) and
          (pass==2 or value.count<stacks.limit(value,definitions)) then
        local n=math.min(value.count,stacks.limit(cursor,definitions)-draft.data.cursor.count)
        if n>0 then
          draft:set('cursor',stacks.copy(cursor,draft.data.cursor.count+n))
          draft:set(address,stacks.copy(value,value.count-n));total=total+n
        end
        seen[address]=true
      end
    end
  end
  return total>0 and draft.data or data,total
end
function M.drag(data,addresses,button,definitions)
  assert(button=='left' or button=='right','invalid-drag-button')
  local cursor=data.cursor
  if not cursor then return data,0 end
  stacks.validate(cursor,definitions)
  local eligible,seen={},{}
  for _,address in ipairs(addresses) do
    local value=slots.get(data,address)
    if not seen[address] and address~='cursor' and address~='trash' and slots.accepts(address,cursor,definitions) and
        (not value or (stacks.compatible(value,cursor) and value.count<stacks.limit(cursor,definitions))) then
      -- Cannot select more slots than the cursor can distribute at least one to.
      if #eligible<cursor.count then eligible[#eligible+1]=address end
    end
    seen[address]=true
  end
  if #eligible==0 then return data,0 end
  local share=button=='right' and 1 or math.floor(cursor.count/#eligible)
  local draft=slots.edit(data)
  local remaining=cursor.count
  for _,address in ipairs(eligible) do
    local value=draft:get(address)
    local n=math.min(share,stacks.limit(cursor,definitions)-(value and value.count or 0),remaining)
    draft:set(address,stacks.copy(cursor,(value and value.count or 0)+n));remaining=remaining-n
  end
  draft:set('cursor',stacks.copy(cursor,remaining))
  return draft.data,cursor.count-remaining
end
return M
