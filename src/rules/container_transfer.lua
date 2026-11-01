-- Candidate-only item movement. The caller commits it with any world changes.
local stacks=require('rules.item_stack')
local slots=require('rules.container_slots')
local native_slot=require('rules.native_slot_reference')
local M={}
local function amount(n)
  assert(type(n)=='number' and n%1==0 and n>=0 and n<2^53,'invalid-transfer-count');return n
end
function M.into(draft,value,addresses,definitions)
  local remaining=value.count
  local seen={}
  for _,address in ipairs(addresses) do slots.address(address);assert(not seen[address],'duplicate-target-slot');seen[address]=true end
  -- Merge into compatible stacks everywhere in the destination before using holes.
  for pass=1,2 do
    for _,address in ipairs(addresses) do
      if remaining==0 then break end
      local current=draft:get(address)
      if slots.accepts(address,value,definitions) and
          ((pass==1 and current and stacks.compatible(current,value)) or (pass==2 and not current)) then
        local n=math.min(remaining,stacks.limit(value,definitions)-(current and current.count or 0))
        if n>0 then draft:set(address,stacks.copy(current or value,(current and current.count or 0)+n));remaining=remaining-n end
      end
    end
  end
  return stacks.copy(value,remaining),value.count-remaining
end
local function into_ender(draft,value,definitions,options)
  if native_slot.is(value) then return stacks.copy(value),0 end
  local remaining=value.count
  local limit=stacks.limit(value,definitions)
  local pages=slots.pages(draft.data)
  local holes={}
  local needed=math.ceil(value.count/limit)
  -- Deliberately merge across ALL allocated pages before considering any empty slot.
  for _,page in ipairs(pages) do
    local values=draft.data.ender[page]
    for i=1,27 do
      local current=values[tostring(i)]
      -- Read the sparse page directly. Parsing 54,000 addresses and allocating
      -- temporary target lists was measurable at 2,000 pages; writes still use
      -- the shared slot boundary. Keep just enough holes for this offer.
      if not current then
        if #holes<needed then holes[#holes+1]='ender/'..page..'/'..i end
      elseif current.count<limit and stacks.compatible(current,value) then
        local n=math.min(remaining,limit-current.count)
        draft:set('ender/'..page..'/'..i,stacks.copy(current,current.count+n));remaining=remaining-n
        if remaining==0 then return nil,value.count end
      end
    end
  end
  for _,address in ipairs(holes) do
    local n=math.min(remaining,limit)
    draft:set(address,stacks.copy(value,n));remaining=remaining-n
    if remaining==0 then return nil,value.count end
  end
  local page=1
  while remaining>0 do
    if options and options.new_ender_page then page=options.new_ender_page(draft.data.ender)
    else while draft.data.ender[tostring(page)] do page=page+1 end end
    assert(not draft.data.ender[tostring(page)],'allocated-ender-page-not-empty')
    local rest=M.into(draft,stacks.copy(value,remaining),slots.page_slots(page),definitions)
    remaining=rest and rest.count or 0
    page=page+1
  end
  return nil,value.count
end
local function insert(draft,value,target,definitions,options)
  if target=='ender' then return into_ender(draft,value,definitions,options) end
  if target=='player' then target=slots.player_slots(true) end
  assert(type(target)=='table','invalid-transfer-target')
  return M.into(draft,value,target,definitions)
end
function M.move(data,source,target,count,definitions,options)
  local value=slots.get(data,source)
  if not value then return data,0 end
  stacks.validate(value,definitions)
  count=math.min(amount(count or value.count),value.count)
  if count==0 then return data,0 end
  if target=='ender' then assert(not source:match('^ender/'),'same-container-transfer') end
  if target=='player' then target=slots.player_slots(true) end
  if type(target)=='table' then
    local filtered={};for _,address in ipairs(target) do if address~=source then filtered[#filtered+1]=address end end
    target=filtered
  end
  local draft=slots.edit(data)
  local _,moved=insert(draft,stacks.copy(value,count),target,definitions,options)
  if moved==0 then return data,0 end
  draft:set(source,stacks.copy(value,value.count-moved))
  return draft.data,moved
end
-- External offers are for a coordinated pickup/reward transaction, never Give.
-- The returned remainder remains with the external owner until joint commit.
function M.offer(data,value,target,definitions,options)
  stacks.validate(value,definitions,{batch=true})
  assert(not native_slot.is(value),'native-slot-external-offer-forbidden')
  if value.instance_id then
    slots.visit(data,function(_,owned) assert(owned.instance_id~=value.instance_id,'duplicate-item-instance') end)
  end
  local draft=slots.edit(data)
  local remainder,moved=insert(draft,value,target,definitions,options)
  return moved>0 and draft.data or data,remainder,moved
end
function M.extract(data,source,count,definitions)
  local value=slots.get(data,source)
  if not value then return data,nil end
  stacks.validate(value,definitions)
  assert(not native_slot.is(value),'native-slot-extraction-forbidden')
  count=math.min(amount(count or value.count),value.count)
  if count==0 then return data,nil end
  local draft=slots.edit(data);draft:set(source,stacks.copy(value,value.count-count))
  return draft.data,stacks.copy(value,count)
end
function M.shift(data,source,context,definitions,options)
  assert(context=='inventory' or context=='ender','invalid-container-context')
  local value=slots.get(data,source)
  if not value then return data,0 end
  if context=='ender' then
    return M.move(data,source,source:match('^ender/') and 'player' or 'ender',nil,definitions,options)
  end
  assert(not source:match('^ender/'),'ender-not-open')
  local definition=native_slot.is(value) and {} or assert(definitions.get(value.content_id),'unknown-stack-content')
  local preferred=definition.equipment_slot and 'player/armor/'..definition.equipment_slot or definition.preferred_slot
  if preferred and preferred~=source then
    local target=preferred
    if not slots.get(data,target) then return M.move(data,source,{target},nil,definitions) end
  end
  local target={}
  if source:match('^player/main/') then
    for i=1,9 do target[#target+1]='player/hotbar/'..i end
  elseif source:match('^player/hotbar/') then
    for i=1,27 do target[#target+1]='player/main/'..i end
  else target=slots.player_slots() end
  return M.move(data,source,target,nil,definitions)
end
return M
