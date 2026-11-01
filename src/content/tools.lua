-- Original Java 26.3 tool materials and tags. No wear, repair or durability data.
-- Native combat progression remains in combat_profiles; attack_damage here is
-- the original Java total (player base 1 plus the tool attribute modifier).
local definitions=require('content.items')
local M={};local entries,list={},{}
local names={'wooden','stone','copper','iron','golden','diamond','netherite'}
local speeds={2,4,5,6,12,8,9}
local tiers={0,1,1,2,0,3,4}
local bonus={0,1,1,2,0,3,4}
local axes={7,9,9,9,7,9,10}
local axe_modifiers={-3.2,-3.2,-3.2,-3.1,-3,-3,-3}
local tier_tags={'minecraft:needs_stone_tool','minecraft:needs_iron_tool','minecraft:needs_diamond_tool'}
local function float(value)return (string.unpack('<f',string.pack('<f',value)))end
for i,material in ipairs(names)do
  local denied={}
  for level,tag in ipairs(tier_tags)do if tiers[i]<level then denied[tag]=true end end
  for _,kind in ipairs({'pickaxe','shovel','axe'})do
    local id='pbzmc:'..material..'_'..kind
    local item=assert(definitions.get(id),'tool-content-unavailable:'..id)
    assert(item.tool_kind==kind and item.instance and item.stack_limit==1,'tool-definition-mismatch:'..id)
    local damage=kind=='axe' and axes[i] or (kind=='shovel' and 2.5 or 2)+bonus[i]
    local modifier=kind=='axe' and axe_modifiers[i] or kind=='shovel' and -3 or -2.8
    local row={id=id,kind=kind,material=material,mining_speed=speeds[i],tier=tiers[i],
      mineable_tag='minecraft:mineable/'..kind,incorrect_for_drops=denied,
      attack_damage=damage,attack_speed=4+float(modifier),source_version='26.3'}
    entries[id]=row;list[#list+1]=row
  end
end
function M.get(id)return entries[id]end
function M.catalogue()return list end
return M
