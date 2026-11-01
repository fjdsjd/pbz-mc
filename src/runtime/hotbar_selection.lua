-- Selecting a slot changes no item ownership. Keep an O(1) memory overlay;
-- the next content transaction or savepoint folds it into the core.
local slots=require('rules.container_slots')
local native=require('rules.native_slot_reference')
local hotbar=require('rules.hotbar')
local M={}
function M.view(store)
  if store.selection_generation~=store.generation then
    store.selection_revision=(store.selection_revision or store.generation)+1
    store.selection_generation=store.generation
  end
  local core=store.core.containers;local index=store.runtime_selected or core.player.selected
  if store.selection_core~=core or store.selection_index~=index then
    store.selection_containers=hotbar.select(core,index);store.selection_core=core;store.selection_index=index
  end
  return store.selection_containers,store.selection_revision
end
function M.select(session,request,context,write,authorize)
  assert(not session.opened and not session.quarantined and not session.busy,'hotbar-context-unavailable')
  local store=session.store
  assert(not store.read_only and request.epoch==session.epoch and request.revision==store.generation,'stale-hotbar-intent')
  assert(context and context.kind=='game' and context.epoch==request.input_epoch
    and (context.weapon_group=='mc' or context.unified_hotbar),'hotbar-gameplay-unavailable')
  local data=M.view(store);local candidate
  if request.kind=='select_slot' then candidate=hotbar.select(data,request.index)
  elseif request.kind=='scroll_slots' then candidate=hotbar.scroll(data,request.steps)
  else error('unsupported-selection-intent') end
  if candidate==data then return true end
  local before=slots.get(data,'player/hotbar/'..data.player.selected)
  local after=slots.get(candidate,'player/hotbar/'..candidate.player.selected)
  if native.is(before) or native.is(after) then
    assert(authorize and authorize(before,after)==true,'native-equipment-coordinator-unavailable')
  end
  local ok,why=write(candidate.player.selected);assert(ok,why)
  store.runtime_selected=candidate.player.selected
  store.selection_revision=store.selection_revision+1
  M.view(store)
  return true
end
return M
