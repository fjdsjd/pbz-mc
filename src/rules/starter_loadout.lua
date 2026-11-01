-- First registration only. Native equipment remains a reference to a real slot.
local state=require('storage.state')
local slots=require('rules.container_slots')
local definitions=require('content.items')
local M={}
function M.create(core,campaign_id,snapshot)
  assert(type(campaign_id)=='string' and #campaign_id>0,'starter-campaign-required')
  local occupied=false;slots.visit(core.containers,function() occupied=true end)
  assert(not occupied and not core.starter_loadout_version,'starter-new-profile-required')
  local next=state.object();for key,value in pairs(core)do next[key]=value end
  local edit=slots.edit(core.containers)
  local items={'wooden_sword','golden_apple','enchanted_golden_apple','ender_pearl','dirt','tnt','flint_and_steel'}
  local function item(name)
    local id='pbzmc:'..name;local value={content_id=id,count=1,metadata=state.object()}
    if assert(definitions.get(id)).instance then value.instance_id='starter-'..campaign_id..'-'..name end
    return value
  end
  for i,name in ipairs(items)do edit:set('player/hotbar/'..(i+1),item(name))end
  edit:set('player/offhand',item('shield'))
  local reference
  if snapshot and snapshot.source=='pbz-backpack-declared-v1' and snapshot.selection_scope=='backpack-declared' then
    for i,id in ipairs(snapshot.main_weapons or {})do
      if type(id)=='string' and id~='' and id:lower()~='none' then
        reference=require('rules.native_slot_reference').new('main',i-1);break
      end
    end
  end
  if reference then edit:set('player/hotbar/1',reference)end
  next.containers=edit.data
  -- If the native backpack is not ready yet, leave slot 1 available for its
  -- normal reconciliation instead of inventing a weapon or taking slot 9.
  next.containers.player.selected=reference and 1 or 2
  next.starter_loadout_version=1
  for _,flag in ipairs({'shield_unlocked','recovery_items_unlocked','pearl_unlocked',
    'boat_unlocked','chorus_unlocked','tnt_unlocked','flint_unlocked'})do next[flag]=true end
  slots.validate(next.containers,definitions)
  return next
end
return M
