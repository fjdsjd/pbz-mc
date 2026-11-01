-- Placed MC objects only; this registry never authorizes mining native terrain.
-- Hardness, effective tags and sound groups: original Minecraft Java 26.3.
-- World size/infinite supply are PBZ policies, independent of harvest drops.
local entries,ids={},{}
local function add(name,model,hardness,tool,sound,correct,extra)
  local id='pbzmc:'..name
  local row={id=id,model=model,half={x=50,y=50,z=50},group='block',limit=1024,
    available=true,infinite=true,category='building',full_cube=true,opaque_cube=true,
    hardness=hardness,tool=tool,sound_group=sound,requires_correct_tool=correct or false,
    -- Wukong baseline: ordinary placed blocks break within 5 m. Stone-family
    -- blocks use its stronger 2.2 m threshold; TNT chains within 8 m.
    explosion={reaction='remove',radius=500},
    conductor=true,push_reaction='normal',
    mineable_tags=tool and {['minecraft:mineable/'..tool]=true} or {},source_version='26.3'}
  for key,value in pairs(extra or {})do row[key]=value end
  entries[id]=row;ids[#ids+1]=id
end
-- Preserve old model identities and saved grids for the already shipped cubes.
add('tnt','tnt/tnt',0,nil,'grass',false,{explosion={reaction='chain',radius=800}})
add('dirt','dirt',.5,'shovel','gravel')
add('stone','stone',1.5,'pickaxe','stone',true,{explosion={reaction='remove',radius=220}})
add('oak_log','building-blocks/oak_log',2,'axe','wood',false,{axis=true,default_axis='y'})
add('stripped_oak_log','building-blocks/stripped_oak_log',2,'axe','wood',false,{axis=true,default_axis='y'})
add('oak_planks','building-blocks/oak_planks',2,'axe','wood')
add('cobblestone','building-blocks/cobblestone',2,'pickaxe','stone',true,{explosion={reaction='remove',radius=220}})
add('glass','building-blocks/glass',.3,nil,'glass',false,{opaque_cube=false,conductor=false,cull_same='glass'})

for _,row in ipairs(require('content.mechanisms'))do
  assert(not entries[row.id],'duplicate-block:'..row.id);entries[row.id]=row
  if row.item_id then entries[row.item_id]=row end
  if row.available then ids[#ids+1]=row.item_id or row.id end
end
table.sort(ids)
return {get=function(id)return entries[id]end,catalogue=function()return ids end}
