local slots=require('rules.container_slots')
local actions=require('rules.container_actions')
local encode=require('storage.canonical_json')
local M={}
function M.select(data,index)
  assert(type(index)=='number' and index%1==0 and index>=1 and index<=9,'invalid-hotbar-index')
  if data.player.selected==index then return data end
  local draft=slots.edit(data);draft:select(index);return draft.data
end
function M.scroll(data,steps)
  assert(type(steps)=='number' and steps%1==0 and math.abs(steps)<2^31,'invalid-hotbar-scroll')
  return M.select(data,((data.player.selected-1+steps)%9)+1)
end
function M.swap_offhand(data,definitions)
  return actions.swap(data,'player/hotbar/'..data.player.selected,'player/offhand',definitions)
end
function M.pick_existing(data,content_id,metadata,definitions)
  assert(definitions.get(content_id),'unknown-picked-content')
  local signature=encode(metadata)
  local function matches(value) return value and value.content_id==content_id and encode(value.metadata)==signature end
  for i=1,9 do
    if matches(data.player.hotbar[tostring(i)]) then return M.select(data,i),true end
  end
  for i=1,27 do
    if matches(data.player.main[tostring(i)]) then
      return actions.swap(data,'player/main/'..i,'player/hotbar/'..data.player.selected,definitions)
    end
  end
  return data,false -- Survival pick never invents an unavailable item.
end
function M.pick_creative(data,content_id,metadata,definitions)
  local found,matched=M.pick_existing(data,content_id,metadata,definitions)
  if matched or found~=data then return found end
  local catalogue=require('rules.block_catalogue')
  if not catalogue.infinite({content_id=content_id})then return data end
  -- Preserve PBZ references and finite equipment. Prefer an empty hotbar slot;
  -- replacing another infinite block is safe and does not duplicate an owner.
  local index=data.player.selected
  local held=data.player.hotbar[tostring(index)]
  if held and not catalogue.infinite(held)then
    index=nil
    for i=1,9 do if not data.player.hotbar[tostring(i)]then index=i;break end end
    if not index then for i=1,9 do if catalogue.infinite(data.player.hotbar[tostring(i)])then index=i;break end end end
  end
  if not index then return data end
  return M.select(catalogue.take(data,content_id,'player/hotbar/'..index,definitions),index)
end
return M
