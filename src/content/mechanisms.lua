-- Block behavior metadata; original model state resolution is a host concern.
local rows={}
local function add(name,kind,hardness,tool,sound,extra)
  local id='pbzmc:'..name
  local row={id=id,model='mechanism-blocks/'..name,mechanism=kind,half={x=50,y=50,z=50},
    group='block',limit=1024,available=true,infinite=true,category='building',full_cube=false,opaque_cube=false,
    hardness=hardness,tool=tool,sound_group=sound,requires_correct_tool=false,
    mineable_tags=tool and {['minecraft:mineable/'..tool]=true} or {},source_version='1.21.1',
    explosion={reaction='remove',radius=500},push_reaction='destroy'}
  for k,v in pairs(extra or {})do row[k]=v end;rows[#rows+1]=row
end
add('oak_door','door',3,'axe','wood',{defaults={facing='north',half='lower',hinge='left',open=false,powered=false},manual=true})
add('iron_door','door',5,'pickaxe','metal',{defaults={facing='north',half='lower',hinge='left',open=false,powered=false}})
add('end_rod','end_rod',0,nil,'wood',{defaults={facing='up'},light=14,collision=true,push_reaction='normal'})
add('lever','lever',.5,nil,'stone',{defaults={facing='north',face='floor',powered=false},collision=false})
add('redstone_dust','wire',0,nil,'stone',{defaults={east='none',west='none',north='none',south='none',power=0},collision=false})
add('redstone_block','source',5,'pickaxe','metal',{full_cube=true,opaque_cube=true,conductor=true,push_reaction='normal',signal=15,explosion={reaction='remove',radius=220}})
add('redstone_torch','torch',0,nil,'wood',{defaults={lit=true,face='floor',facing='north'},collision=false,light=7})
add('repeater','repeater',0,nil,'stone',{defaults={facing='north',delay=1,locked=false,powered=false},collision=false})
add('comparator','comparator',0,nil,'stone',{defaults={facing='north',mode='compare',powered=false,output=0},collision=false})
add('observer','observer',3,'pickaxe','stone',{defaults={facing='south',powered=false},full_cube=true,opaque_cube=true,push_reaction='normal'})
add('piston','piston',1.5,'pickaxe','stone',{defaults={facing='north',extended=false},push_reaction='normal'})
add('sticky_piston','sticky_piston',1.5,'pickaxe','stone',{defaults={facing='north',extended=false},push_reaction='normal'})
add('slime_block','slime_block',0,nil,'slime',{full_cube=true,opaque_cube=false,conductor=false,push_reaction='normal',sticky='slime'})
add('honey_block','honey_block',0,nil,'honey',{full_cube=false,opaque_cube=false,conductor=false,push_reaction='normal',sticky='honey'})
add('piston_head','piston_head',1.5,'pickaxe','stone',{defaults={facing='north',type='normal',short=false},available=false,push_reaction='block'})
add('water','fluid',100,nil,'none',{item_id='pbzmc:water_bucket',defaults={level=0,falling=false},group='fluid',limit=1024,
  collision=false,fluid='water',replaceable=true,explosion={reaction='none',radius=0},push_reaction='destroy'})
add('lava','fluid',100,nil,'none',{item_id='pbzmc:lava_bucket',defaults={level=0,falling=false},group='fluid',limit=1024,
  collision=false,fluid='lava',replaceable=true,light=15,explosion={reaction='none',radius=0},push_reaction='destroy'})
add('obsidian','solid',50,'pickaxe','stone',{full_cube=true,opaque_cube=true,conductor=true,push_reaction='block',
  requires_correct_tool=true,harvest_tags={['minecraft:needs_diamond_tool']=true},explosion={reaction='none',radius=0}})
add('bucket','bucket',0,nil,'none',{utility=true,collision=false})
return rows
