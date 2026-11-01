-- Presentation categories are independent of item ownership and block behavior.
-- Bedrock's construction/equipment/nature/items groups are split for this mod's
-- redstone and armour catalogues; only implemented content is listed.
local M={
 groups={
  {id='construction',label='建筑',skin='construction'},
  {id='redstone',label='红石',icon='pbzmc:redstone_dust'},
  {id='nature',label='自然与流体',skin='nature'},
  {id='equipment',label='工具与武器',skin='equipment'},
  {id='armor',label='护甲',icon='pbzmc:iron_chestplate'},
  {id='items',label='物品与食物',skin='items'},
 },
 equipment={'pbzmc:bow','pbzmc:shield','pbzmc:flint_and_steel'},
 supplies={'pbzmc:arrow','pbzmc:golden_apple','pbzmc:enchanted_golden_apple',
  'pbzmc:chorus_fruit','pbzmc:ender_pearl','pbzmc:totem_of_undying','pbzmc:boat','pbzmc:firework_rocket'},
}
local classified={}
for _,name in ipairs({'tnt','lever','redstone_dust','redstone_block','redstone_torch',
 'repeater','comparator','observer','piston','sticky_piston','slime_block','honey_block'})do
 classified['pbzmc:'..name]='redstone'
end
for _,name in ipairs({'dirt','stone','oak_log','stripped_oak_log','obsidian','water_bucket','lava_bucket','bucket'})do
 classified['pbzmc:'..name]='nature'
end
function M.block_category(id)return classified[id]or'construction'end
function M.supply_category(id)return id=='pbzmc:arrow'and'equipment'or'items'end
return M
