-- Command item operations use the existing unique-instance ownership rules.
local slots=require('rules.container_slots')
local definitions=require('content.items')
local state=require('storage.state')
local native=require('rules.native_slot_reference')
local M={}
function M.id(id)
  id=id:gsub('^minecraft:','pbzmc:')
  local definition=assert(definitions.get(id),'item-unavailable:'..id)
  assert(definition.kind~='balance','not-an-inventory-item');return id,definition
end
function M.give(containers,id,count,revision,profile)
  local definition;id,definition=M.id(id)
  assert(not definition.instance or count<=36,'too-many-equipment-instances')
  local transfer=require('rules.container_transfer')
  for i=1,definition.instance and count or 1 do
    local stack={content_id=id,count=definition.instance and 1 or count,metadata=state.object()}
    if definition.instance then stack.instance_id=string.format('command-%s-%d-%d',profile,revision,i)end
    local updated,remainder=transfer.offer(containers,stack,'player',definitions)
    assert(not remainder,'inventory-full');containers=updated
  end
  return containers,count
end
function M.clear(containers,id,maximum)
  if id then id=M.id(id)end
  local draft=slots.edit(containers);local count=0;local query=maximum==0
  local addresses=slots.player_slots();addresses[#addresses+1]='player/offhand'
  for _,slot in ipairs({'head','chest','legs','feet'})do addresses[#addresses+1]='player/armor/'..slot end
  for i=1,4 do addresses[#addresses+1]='craft/'..i end
  addresses[#addresses+1]='cursor'
  for _,address in ipairs(addresses)do
    local old=draft:get(address)
    if old and not native.is(old)and (not id or old.content_id==id)then
      local take=query and old.count or math.min(old.count,(maximum or math.huge)-count)
      if take>0 then
        count=count+take
        if not query then
          local next=take<old.count and state.clone(old)or nil
          if next then next.count=old.count-take end;draft:set(address,next)
        end
      end
    end
  end
  return not query and count>0 and draft.data or nil,count
end
function M.replace(containers,slot,id,count,revision,profile)
  local aliases={['weapon.mainhand']='player/hotbar/'..containers.player.selected,['weapon.offhand']='player/offhand',
    ['armor.head']='player/armor/head',['armor.chest']='player/armor/chest',['armor.legs']='player/armor/legs',['armor.feet']='player/armor/feet'}
  local address=aliases[slot]
  if not address then
    local family,n=slot:match('^(%a+)%.(%d+)$');n=tonumber(n)
    if family=='hotbar'and n<=8 then address='player/hotbar/'..(n+1)
    elseif family=='inventory'and n<=26 then address='player/main/'..(n+1)end
  end
  assert(address,'item-slot-unavailable:'..tostring(slot))
  assert(not native.is(slots.get(containers,address)),'cannot-delete-pbz-weapon-reference')
  local stack
  if id~='minecraft:air'and id~='pbzmc:air'then
    local definition;id,definition=M.id(id);assert(count<=definition.stack_limit,'item-stack-limit')
    stack={content_id=id,count=count,metadata=state.object()}
    if definition.instance then stack.instance_id=string.format('command-%s-%d-item',profile,revision)end
    assert(slots.accepts(address,stack,definitions),'item-in-wrong-slot')
  end
  local draft=slots.edit(containers);draft:set(address,stack);return draft.data,1
end
return M
