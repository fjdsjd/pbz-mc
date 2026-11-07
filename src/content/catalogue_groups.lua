-- Presentation categories are independent of item ownership and block behavior.
-- Bedrock's construction/equipment/nature/items groups are split for this mod's
-- redstone and armour catalogues; only implemented content is listed.
local M={
 groups={
  {id='construction',label='建筑',skin='construction'},
  {id='redstone',label='红石',icon='pbzmc:redstone_dust'},
  {id='nature',label='自然',skin='nature'},
  {id='equipment',label='工具与武器',skin='equipment'},
  {id='armor',label='护甲',icon='pbzmc:iron_chestplate'},
  {id='items',label='物品与食物',skin='items'},
  {id='potions',label='药水',icon='pbzmc:potion_healing'},
 },
 equipment={'pbzmc:bow','pbzmc:shield','pbzmc:flint_and_steel'},
 supplies={'pbzmc:arrow','pbzmc:golden_apple','pbzmc:enchanted_golden_apple',
  'pbzmc:chorus_fruit','pbzmc:ender_pearl','pbzmc:totem_of_undying','pbzmc:boat','pbzmc:firework_rocket','pbzmc:wind_charge'},
}
local classified={}
local potions=require('rules.potions')
local potion_ids={}
for id,potion in pairs(potions.all())do if potion.available then potion_ids[#potion_ids+1]=id end end
table.sort(potion_ids)
for _,id in ipairs(potion_ids)do M.supplies[#M.supplies+1]=id end
M.supplies[#M.supplies+1]='pbzmc:milk_bucket'
local summons=require('content.summon_mobs')
for _,mob in ipairs(summons.list()) do M.supplies[#M.supplies+1]=mob.egg end
for _,name in ipairs({'tnt','lever','redstone_dust','redstone_block','redstone_torch',
 'repeater','comparator','observer','piston','sticky_piston','slime_block','honey_block',
 'command_block','repeating_command_block','chain_command_block'})do
 classified['pbzmc:'..name]='redstone'
end
for _,name in ipairs({'dirt','stone','oak_log','stripped_oak_log','obsidian','spawner','water_bucket','lava_bucket','bucket'})do
 classified['pbzmc:'..name]='nature'
end
function M.block_category(id)return classified[id]or'construction'end
function M.supply_category(id)
 if potions.get(id)or id=='pbzmc:milk_bucket'then return 'potions'end
 if summons.egg(id) then return 'nature' end
 return (id=='pbzmc:arrow' or id=='pbzmc:wind_charge') and 'equipment' or 'items'
end
return M
