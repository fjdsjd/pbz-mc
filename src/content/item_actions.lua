-- Input/use categories from the pinned SwordCombat.Use; stable content IDs only.
-- Timing is owned by runtime.minecraft_actions, while world transactions stay in
-- the host adapter. No durability action is emitted in any mode.
local combat=require('content.combat_profiles')
local items=require('content.items')
local blocks=require('content.blocks')
local summons=require('content.summon_mobs')
local M={}
local uses={
  ['pbzmc:shield']='shield',['pbzmc:bow']='bow',['pbzmc:trident']='trident',
  ['pbzmc:golden_apple']='food',['pbzmc:enchanted_golden_apple']='food',['pbzmc:healing_bottle']='bottle',
  ['pbzmc:chorus_fruit']='food',['pbzmc:firework_rocket']='instant',
  ['pbzmc:wind_charge']='wind',['pbzmc:ender_pearl']='pearl',
  ['pbzmc:life_crystal']='growth',['pbzmc:bottle_capacity']='growth',['pbzmc:bottle_strength']='growth',
}
for _,id in ipairs({'boat','piston','sticky_piston','observer','end_rod','lever','redstone_dust',
  'redstone_block','sheep_machine','tnt','flint_and_steel','dirt','stone',
  'ender_chest'}) do uses['pbzmc:'..id]='instant' end
for id in pairs(uses) do assert(items.get(id),'unknown-action-content:'..id) end
function M.get(id)
  local profile=combat.get(id)
  local block=blocks.get(id)
  local definition=items.get(id)
  local potion=require('rules.potions').get(id)
  return {combat=profile,use=definition and definition.equipment_slot and 'equipment'
    or potion and (potion.form=='potion'and 'drink'or 'potion_throw') or id=='pbzmc:milk_bucket'and 'drink'
    or summons.egg(id) and 'summon' or profile.kind=='spear' and 'spear' or (block and block.available and 'instant') or uses[id],
    placeable=block and block.available==true or false,
    -- The user's added axes/shovels use their own target-conversion adapter.
    tool_use=profile.kind=='axe' or profile.kind=='shovel',
    offhand_wind=not id or profile.kind=='mace' or profile.kind=='sword' or profile.kind=='pickaxe'}
end
return M
