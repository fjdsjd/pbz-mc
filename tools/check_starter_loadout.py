"""Exercise new-profile equipment without modifying an installed game or save."""
from pathlib import Path
import sys

ROOT=Path(__file__).resolve().parents[1]
if (ROOT/'build/lua-check').is_dir():sys.path.insert(0,str(ROOT/'build/lua-check'))
from lupa.lua54 import LuaRuntime

lua=LuaRuntime(unpack_returned_tuples=True)
lua.globals().source_root=ROOT.as_posix()
lua.execute("package.path=source_root..'/src/?.lua;'..source_root..'/third_party/dkjson/?.lua;'..package.path")
lua.execute('''
local state=require('storage.state')
local slots=require('rules.container_slots')
local definitions=require('content.items')
local starter=require('rules.starter_loadout')
local empty=require('storage.player_state').empty()
local snapshot={epoch=1,source='pbz-backpack-declared-v1',selection_scope='backpack-declared',
  main_weapons={'None','native-equipment-id'},shaqi_weapons={}}
local core=starter.create(empty,'campaign-test',snapshot)
local native=slots.get(core.containers,'player/hotbar/1')
assert(native.content_id=='pbz:slot_reference' and native.metadata.native_slot_index==1)
for i,id in ipairs({'wooden_sword','golden_apple','enchanted_golden_apple','ender_pearl','dirt','tnt','flint_and_steel'})do
  local item=slots.get(core.containers,'player/hotbar/'..(i+1))
  assert(item.content_id=='pbzmc:'..id and item.count==1)
end
assert(slots.get(core.containers,'player/offhand').content_id=='pbzmc:shield')
assert(not slots.get(core.containers,'player/hotbar/9'))
assert(core.containers.player.selected==1 and not empty.starter_loadout_version)
slots.visit(empty.containers,function()error('input mutated')end)
assert(not pcall(starter.create,core,'campaign-test',snapshot))
for _,flag in ipairs({'shield_unlocked','recovery_items_unlocked','pearl_unlocked','boat_unlocked',
  'chorus_unlocked','tnt_unlocked','flint_unlocked'})do assert(core[flag])end
local delayed=starter.create(empty,'delayed')
assert(delayed.containers.player.selected==2 and not slots.get(delayed.containers,'player/hotbar/1'))
local reconciled=require('rules.native_slot_inventory').refresh(delayed.containers,snapshot,1,definitions,
  {defer_additions=true,skip_selected_empty=true})
assert(slots.get(reconciled,'player/hotbar/1').metadata.native_slot_index==1)
assert(slots.get(reconciled,'player/hotbar/2').content_id=='pbzmc:wooden_sword')
assert(not slots.get(reconciled,'player/hotbar/9'))
''')
print('PASS: starter order, one apple each, offhand shield, real native slot, deferred equipment, existing-profile guard')
