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
add('tnt','tnt/tnt',0,nil,'grass',false,{construction_render=true,explosion={reaction='chain',radius=800}})
add('dirt','dirt',.5,'shovel','gravel',false,{construction_render=true})
add('stone','stone',1.5,'pickaxe','stone',true,{explosion={reaction='remove',radius=220}})
add('oak_log','building-blocks/oak_log',2,'axe','wood',false,{axis=true,default_axis='y'})
add('stripped_oak_log','building-blocks/stripped_oak_log',2,'axe','wood',false,{axis=true,default_axis='y'})
add('oak_planks','building-blocks/oak_planks',2,'axe','wood')
add('cobblestone','building-blocks/cobblestone',2,'pickaxe','stone',true,{explosion={reaction='remove',radius=220}})
add('glass','building-blocks/glass',.3,nil,'glass',false,{opaque_cube=false,conductor=false,cull_same='glass'})
add('spawner','building-blocks/spawner',5,'pickaxe','stone',true,
  {construction_render=true,opaque_cube=false,conductor=false,push_reaction='block',explosion={reaction='remove',radius=220}})

for _,row in ipairs(require('content.mechanisms'))do
  assert(not entries[row.id],'duplicate-block:'..row.id);entries[row.id]=row
  if row.item_id then entries[row.item_id]=row end
  if row.available then ids[#ids+1]=row.item_id or row.id end
end
local vanilla=require('content.construction_registry')
local building_order={}
local families={
  DoorBlock='door',TrapDoorBlock='trapdoor',FenceGateBlock='gate',FenceBlock='fence',
  WallBlock='wall',IronBarsBlock='pane',StainedGlassPaneBlock='pane',StairBlock='stairs',
  SlabBlock='slab',ButtonBlock='button',PressurePlateBlock='plate',WeightedPressurePlateBlock='plate',
  CopperBulbBlock='bulb',ConcretePowderBlock='powder',WoolCarpetBlock='carpet',
  WeatheringCopperStairBlock='stairs',WeatheringCopperSlabBlock='slab',WeatheringCopperBarsBlock='pane',
  WeatheringCopperDoorBlock='door',WeatheringCopperTrapDoorBlock='trapdoor',WeatheringCopperBulbBlock='bulb'}
local reactions={push_pull='normal',popped='destroy',immoveable='block',push='push_only'}
for _,r in ipairs(vanilla.rows)do
  local name,class,profile,hardness,resistance,correct,tools,tier,push,sound=table.unpack(r)
  local id='pbzmc:'..name;building_order[#building_order+1]=id
  -- Keep the existing world model and interactions while applying the same
  -- source of mining and impact-sound data to previously shipped blocks.
  if entries[id] then
    local previous=entries[id]
    previous.requires_correct_tool=correct
    previous.construction_sound=sound
    -- Render old solid cubes through the same compact atlas as new buildings.
    -- Their IDs, collision, interactions and saved grid stay unchanged.
    if not previous.mechanism then previous.construction_render=true end
  else
    local p=vanilla.profiles[profile];local kind=families[class];local tags={}
    for _,tool in ipairs(tools)do tags['minecraft:mineable/'..tool]=true end
    local manual=not name:find('iron_',1,true) -- Copper and wood doors accept hand use.
    local glass=name:find('glass',1,true)~=nil
    add(name,'construction/'..name,hardness,tools[1],sound,correct,{
      construction=true,family=kind,mechanism=kind=='door' and 'door' or nil,
      defaults=p.defaults,axis=p.defaults.axis~=nil,collision=p.solid,full_cube=p.full,opaque_cube=p.opaque,
      conductor=p.conductor,light=p.light>0 and p.light or nil,cull_same=glass and id or nil,
      manual=manual,mineable_tags=tags,harvest_tags=tier~='' and {['minecraft:needs_'..tier..'_tool']=true}or nil,
      push_reaction=assert(reactions[push],push),blast_resistance=resistance,
      explosion={reaction=resistance>=1200 and 'none' or 'remove',radius=resistance>=1200 and 0 or resistance>=6 and 220 or 500}
    })
  end
end
for name,mode in pairs({command_block='impulse',repeating_command_block='repeat',chain_command_block='chain'})do
  add(name,'construction/'..name,-1,'pickaxe','stone',true,{
    construction=true,command_block=mode,mechanism='command',category='redstone',
    push_reaction='block',blast_resistance=3600000,explosion={reaction='none',radius=0},
    defaults={facing='north',conditional=false,auto=mode=='chain',track_output=true,command='',success_count=0}})
end
table.sort(ids)
return {get=function(id)return entries[id]end,catalogue=function()return ids end,construction=building_order}
