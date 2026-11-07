"""Exercise cage configuration, persistence, budgets and shared summon limits."""
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'build/lua-check'))
from lupa.lua54 import LuaRuntime

lua = LuaRuntime(unpack_returned_tuples=True)
lua.globals().root = root.as_posix()
lua.execute("package.path=root..'/src/?.lua;'..root..'/third_party/dkjson/?.lua;'..package.path")
lua.execute(r"""
local controller=require('host.pbz.mob_spawners')
local timing=require('rules.mob_spawner')
local state=require('storage.state')
local defs=require('content.summon_mobs')
local registry=require('content.blocks')
local id='pbzmc:spawner'
assert(registry.get(id).infinite and registry.get(id).push_reaction=='block')
assert(require('content.catalogue_groups').block_category(id)=='nature')
assert(require('content.item_actions').get(id).use=='instant')
local location={X=0,Y=0,Z=0}
local created,retired,acquired,attempts,reads=0,0,0,0,0
local actor={K2_GetActorLocation=function() reads=reads+1;return location end}
local build={binding={actor=actor},session={},log=function()end}
local group={mobs={},world={models={}},ignored=function()return {}end}
package.loaded['host.pbz.tnt_service']={get=function()end}
local blocked=false
function group.world:cage_position(def,block)
  attempts=attempts+1
  if not blocked then return {X=block.x,Y=block.y,Z=block.z} end
end
function group.world.models:preview()
  created=created+1;local index=created;local alive=true
  return {actor={IsValid=function()return alive end,GetAddress=function()return index end,
    GetFullName=function()return 'preview' end,K2_SetActorRotation=function()end,
    K2_DestroyActor=function()assert(alive);alive=false;retired=retired+1 end},id={address=index,name='preview'}}
end
function group:spawn(def,p) self.mobs[#self.mobs+1]={def=def,position=p};return true end
local svc=controller.new(build,function()acquired=acquired+1;return group end)
local block={id='a',world='test',content_id=id,x=0,y=0,z=0,yaw=0}
local aim_id='a';function build:target()return {},{id=aim_id}end
local commits=0;local reject=false
function build.session:batch(rows)
  if reject then return false,'save conflict' end
  assert(rows[1].before==block);commits=commits+1;block=rows[1].after;svc:changed(rows);return true
end
local now=0;local function step(n)
  for i=1,n do now=now+.11;local before=#group.mobs;svc:tick(now);assert(#group.mobs<=before+1) end
end
svc:changed({{after=block}});step(12)
assert(svc.count==1 and acquired==0 and reads==0 and #group.mobs==0)
aim_id='other';assert(svc:use_egg(defs.list()[1],function()end)==nil);aim_id='a'
for _,def in ipairs(defs.list()) do
  assert(svc:use_egg(def));assert(svc.cages.a.def==def and #group.mobs==0)
  local stable=state.decode(require('dkjson').encode({a=block}))
  assert(state.validate_buildings(stable) and stable.a.properties.spawn_egg==def.egg)
end
assert(not pcall(require('rules.block_properties').validate,{spawn_egg='pbzmc:garbage'}))
local def=defs.egg('pbzmc:zombie_spawn_egg');local cow=defs.egg('pbzmc:cow_spawn_egg')
assert(svc:use_egg(def));local old=commits;assert(svc:use_egg(def) and commits==old)
reject=true;assert(svc:use_egg(cow)==false and svc.cages.a.def==def);reject=false
location.X=1600.01;step(100);assert(#group.mobs==0 and created==0)
location.X=1600;step(18);assert(#group.mobs==4 and created==1)
local row=svc.cages.a;assert(row.remaining>9 and row.remaining<=39.95 and svc.spawned==4)
local left=row.remaining;location.X=1601;step(600);assert(row.remaining==left and retired==1)
location.X=0;step(2);row.remaining=0;step(6)
assert(#group.mobs==6);local saved=state.decode(require('dkjson').encode({a=block}))
assert(svc:use_egg(cow));step(16);assert(#group.mobs==10 and group.mobs[10].def==cow)
row=svc.cages.a;row.remaining=0;step(8);assert(#group.mobs==defs.limit)
assert(svc:use_egg(def));step(50);assert(#group.mobs==defs.limit)
svc:changed({{before=block}});local count=#group.mobs;step(500)
assert(#svc.armed==0 and svc.count==0 and created==retired and #group.mobs==count)
block=saved.a;svc:changed({{after=block,restored=true}})
assert(svc.cages.a.def==def);group.mobs={};blocked=true;local old_attempts=attempts;step(40)
assert(#group.mobs==0 and attempts>old_attempts and attempts-old_attempts<22)
blocked=false;step(30);assert(#group.mobs==4)
local position=group.world.cage_position
function group.world:cage_position() error('native collision query unavailable') end
local recovering=svc.cages.a;recovering.remaining=0;step(1)
assert(recovering.error and recovering.retry and #group.mobs==4)
group.world.cage_position=position;step(25)
assert(not recovering.error and #group.mobs>4)
for i=1,32 do
  local b={id='c'..i,world='test',content_id=id,properties={spawn_egg=def.egg},x=i*75,y=0,z=0,yaw=0}
  svc:changed({{after=b,restored=true}})
end
step(100);assert(created-retired<=6 and #group.mobs<=defs.limit)
svc:close();assert(created==retired and #svc.armed==0)
package.loaded['host.pbz.undead_world']={}
package.loaded['host.pbz.undead_models']={}
package.loaded['host.pbz.appearance']={valid=function()return true end}
local shared=setmetatable({binding={is_current=function()return true end,actor={AttributeSetBase={Health={CurrentValue=1}}}},
  mobs={},serial=0,report={spawned=0},combat={log=function()end},world={},start=function()end},
  {__index=require('host.pbz.undead_summons')})
shared.world.create=function()return nil end
assert(not shared:spawn(def,{}) and #shared.mobs==0)
shared.world.create=function()error('invalid model')end
assert(not shared:spawn(def,{}) and shared.report.spawn_error:find('invalid model',1,true))
shared.world.create=function()return {def=def}end
assert(shared:spawn(def,{}) and #shared.mobs==1 and shared.report.spawned==1)
for i=1,1000 do
  local p=timing.sample(block,math.random);assert(math.abs(p.X)<=400 and math.abs(p.Y)<=400 and math.abs(p.Z+50)<=100)
  local t=timing.delay(math.random);assert(t>=10 and t<40)
end
print('PASS: '..#defs.list()..' egg configurations and save round-trips, empty and distant sleep, four attempts, shared local/global caps, blocked terrain, preview cleanup, multiple cages')
""")
