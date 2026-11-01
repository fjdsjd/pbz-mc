-- Sparse JSON objects represent real slots, not extra backpack capacity.
-- States and returned slot values are immutable; edits use copy-on-write drafts.
local state=require('storage.state')
local stack=require('rules.item_stack')
local json=require('dkjson')
local native_slot=require('rules.native_slot_reference')
local M={}
local armor={head=true,chest=true,legs=true,feet=true}
local function object(v)
  return type(v)=='table' and v~=json.null and (not getmetatable(v) or getmetatable(v).__jsontype=='object')
end
local function index(s,limit)
  if type(s)~='string' or not s:match('^[1-9][0-9]*$') then return false end
  local n=tonumber(s)
  return n and n<2^53 and (not limit or n<=limit)
end
local function shallow(value)
  local result=state.object();for k,v in pairs(value) do result[k]=v end;return result
end
function M.address(address)
  assert(type(address)=='string','invalid-slot-address')
  if address=='cursor' or address=='trash' then return address end
  if address=='player/offhand' then return 'offhand' end
  local area,key=address:match('^player/(%a+)/([^/]+)$')
  if (area=='main' and index(key,27)) or (area=='hotbar' and index(key,9)) or
      (area=='armor' and armor[key]) then return area,key end
  key=address:match('^craft/([^/]+)$')
  if index(key,4) then return 'craft',key end
  local page,slot=address:match('^ender/([^/]+)/([^/]+)$')
  if index(page) and index(slot,27) then return 'ender',slot,page end
  error('invalid-slot-address:'..address)
end
function M.empty()
  return state.object({schema=1,player=state.object({main=state.object(),hotbar=state.object(),
    armor=state.object(),selected=1}),craft=state.object(),ender=state.object()})
end
function M.get(data,address)
  local area,key,page=M.address(address)
  if area=='cursor' or area=='trash' then return data[area] end
  if area=='offhand' then return data.player.offhand end
  if area=='craft' then return data.craft[key] end
  if area=='ender' then return data.ender[page] and data.ender[page][key] end
  return data.player[area][key]
end
function M.accepts(address,value,definitions)
  local area,key=M.address(address)
  if not value then return true end
  if native_slot.is(value) then native_slot.validate(value);return native_slot.accepts_area(area) end
  local definition=definitions.get(value.content_id)
  if not definition or definition.kind=='balance' then return false end
  return area~='armor' or definition.equipment_slot==key
end
function M.player_slots(hotbar_first)
  local result={}
  for _,area in ipairs(hotbar_first and {'hotbar','main'} or {'main','hotbar'}) do
    for i=1,area=='main' and 27 or 9 do result[#result+1]='player/'..area..'/'..i end
  end
  return result
end
function M.page_slots(page)
  page=tostring(page);assert(index(page),'invalid-ender-page')
  local result={};for i=1,27 do result[i]='ender/'..page..'/'..i end;return result
end
function M.pages(data)
  local result={};for page in pairs(data.ender) do result[#result+1]=page end
  table.sort(result,function(a,b) return #a<#b or (#a==#b and a<b) end);return result
end
function M.visit(data,fn)
  for _,area in ipairs({'main','hotbar','armor'}) do
    for key,value in pairs(data.player[area]) do fn('player/'..area..'/'..key,value) end
  end
  if data.player.offhand then fn('player/offhand',data.player.offhand) end
  if data.cursor then fn('cursor',data.cursor) end
  if data.trash then fn('trash',data.trash) end
  for key,value in pairs(data.craft) do fn('craft/'..key,value) end
  for page,values in pairs(data.ender) do
    for key,value in pairs(values) do fn('ender/'..page..'/'..key,value) end
  end
end
function M.validate(data,definitions)
  assert(object(data) and data.schema==1,'unsupported-container-schema')
  assert(object(data.player) and object(data.craft) and object(data.ender),'invalid-containers')
  for _,area in ipairs({'main','hotbar','armor'}) do
    assert(object(data.player[area]),'invalid-player-slots')
    for key in pairs(data.player[area]) do
      assert(type(key)=='string','non-string-slot-key');M.address('player/'..area..'/'..key)
    end
  end
  assert(type(data.player.selected)=='number' and data.player.selected%1==0 and
    data.player.selected>=1 and data.player.selected<=9,'invalid-hotbar-selection')
  for key in pairs(data.craft) do assert(type(key)=='string' and index(key,4),'invalid-craft-slot') end
  for page,values in pairs(data.ender) do
    assert(index(page) and object(values),'invalid-ender-page')
    for key in pairs(values) do assert(type(key)=='string' and index(key,27),'invalid-ender-slot') end
  end
  local instances={}
  M.visit(data,function(address,value)
    M.address(address);stack.validate(value,definitions,{unknown=true})
    local definition=definitions.get(value.content_id)
    assert((not definition and not native_slot.is(value)) or M.accepts(address,value,definitions),'item-in-wrong-slot')
    if value.instance_id then
      assert(not instances[value.instance_id],'duplicate-item-instance')
      instances[value.instance_id]=true
    end
  end)
  state.validate_value(data);return true
end
function M.edit(data)
  local draft={data=shallow(data),copied={}}
  function draft:get(address) return M.get(self.data,address) end
  function draft:select(index)
    assert(type(index)=='number' and index%1==0 and index>=1 and index<=9,'invalid-hotbar-index')
    if not self.copied.player then self.data.player=shallow(self.data.player);self.copied.player=true end
    self.data.player.selected=index
  end
  function draft:set(address,value)
    local area,key,page=M.address(address)
    local target=self.data
    if area=='cursor' or area=='trash' then target[area]=stack.copy(value);return end
    if area=='main' or area=='hotbar' or area=='armor' or area=='offhand' then
      if not self.copied.player then target.player=shallow(target.player);self.copied.player=true end
      target=target.player
      if area=='offhand' then target.offhand=stack.copy(value);return end
    end
    if not self.copied[area] then target[area]=shallow(target[area]);self.copied[area]=true end
    target=target[area]
    if area=='ender' then
      if not self.copied['page/'..page] then target[page]=shallow(target[page] or {});self.copied['page/'..page]=true end
      target[page][key]=stack.copy(value)
      -- Empty pages are views, not allocated storage. Clearing the last slot releases one.
      if next(target[page])==nil then target[page]=nil;self.copied['page/'..page]=nil end
    else target[key]=stack.copy(value) end
  end
  return draft
end
return M
