-- Minecraft 26.3 ArmorMaterials, with 1.21.1 parity for non-copper pieces.
-- No durability, repair costs, enum ordinals or host pointers are content data.
local M={slots={'head','chest','legs','feet'}}
local suffixes={'helmet','chestplate','leggings','boots'}
local materials={
  {id='leather',points={1,3,2,1}},
  {id='copper',points={2,4,3,1}},
  {id='chainmail',points={2,5,4,1}},
  {id='iron',points={2,6,5,2}},
  {id='golden',points={2,5,3,1}},
  {id='diamond',points={3,8,6,3},toughness=2},
  {id='netherite',points={3,8,6,3},toughness=3,knockback_resistance=.1},
}
local entries,ordered={},{}
for _,material in ipairs(materials)do
  for index,slot in ipairs(M.slots)do
    local id='pbzmc:'..material.id..'_'..suffixes[index]
    local definition={id=id,slot=slot,equipment_slot=slot,material=material.id,points=material.points[index],
      toughness=material.toughness or 0,knockback_resistance=material.knockback_resistance or 0,
      model_layer=slot=='legs' and 'inner' or 'outer',source_version='26.3'}
    entries[id]=definition;ordered[#ordered+1]=definition
  end
end
local turtle={id='pbzmc:turtle_helmet',slot='head',equipment_slot='head',material='turtle',points=2,
  toughness=0,knockback_resistance=0,model_layer='outer',source_version='26.3'}
entries[turtle.id]=turtle;ordered[#ordered+1]=turtle
local elytra={id='pbzmc:elytra',slot='chest',equipment_slot='chest',material='elytra',points=0,
  toughness=0,knockback_resistance=0,model_layer='elytra',source_version='1.21.1'}
entries[elytra.id]=elytra;ordered[#ordered+1]=elytra
function M.get(id)return entries[id]end
function M.catalogue()return ordered end
function M.all()return entries end
return M
