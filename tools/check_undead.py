"""Check summon supply, target selection, friendly fire and creeper fuses."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'build/lua-check'))
from lupa.lua54 import LuaRuntime

lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute("local r=...;package.path=r..'/src/?.lua;'..r..'/third_party/dkjson/?.lua;'..package.path", root.as_posix())
lua.execute("""
local undead=require('content.undead')
local mobs=require('content.summon_mobs')
local attacks=require('rules.summon_attacks')
local supply=require('rules.supply_catalogue')
local groups=require('content.catalogue_groups')
local actions=require('content.item_actions')
local slots=require('rules.container_slots')
local seen={}
for _,mob in ipairs(mobs.list()) do
  assert(not seen[mob.egg] and mobs.egg(mob.egg)==mob)
  assert(mob.attack=='passive' or mob.attack=='creeper' or attacks.contact(mob.attack) or attacks.projectile(mob.attack))
  assert(groups.supply_category(mob.egg)=='nature' and actions.get(mob.egg).use=='summon')
  local data=supply.take(slots.empty(),mob.egg,'player/hotbar/2')
  assert(slots.get(data,'player/hotbar/2').content_id==mob.egg)
  seen[mob.egg]=true
end
assert(#undead.list()==17 and not undead.egg('pbzmc:creeper_spawn_egg'))
assert(#mobs.list()==91 and mobs.egg('pbzmc:creeper_spawn_egg').attack=='creeper')
assert(mobs.egg('pbzmc:villager_spawn_egg').attack=='passive')
assert(attacks.fuse(0,.2,251,true)==0 and attacks.fuse(0,.25,250,true)==.25)
assert(attacks.fuse(.25,.25,599,true)==.5 and attacks.fuse(.5,.25,601,true)==.25)
assert(attacks.fuse(.5,.25,100,false)==.25 and attacks.fuse(.1,1,nil,false)==0)
assert(attacks.fuse(0,1.7,nil,false,true)==1.5)
local from,to={X=0,Y=0,Z=155},{X=1100,Y=20,Z=95}
local shot=assert(attacks.launch(from,to,{X=0,Y=0,Z=0},900,590))
local t=to.X/shot.X
assert(math.abs(shot.X^2+shot.Y^2+shot.Z^2-900^2)<.01)
assert(math.abs(shot.Z*t-.5*590*t*t+from.Z-to.Z)<.001)

-- Several enemies behind a wall must not starve the remaining visible one.
package.loaded['UEHelpers']={}
package.loaded['host.pbz.appearance']={valid=function(o) return o~=nil end}
local summons=require('host.pbz.undead_summons')
local function position(x) return {X=x,Y=0,Z=0} end
local function enemy(i,x)
  local a={visible=false,IsValid=function()return true end,GetAddress=function()return i end,
    GetFullName=function()return 'test-'..i end}
  return {actor=a,id=require('host.pbz.object_identity').capture(a),pos=position(x)}
end
local traces=0
local svc=setmetatable({candidates={},world={sight=function(_,a,b,actor)
  traces=traces+1;return actor.visible end}},summons)
for i=1,10 do svc.candidates[i]=enemy(i,40*i) end
local outside=enemy(11,undead.detection+1);outside.actor.visible=true
svc.candidates[11]=outside
local m={position=position(0)}
assert(svc:target(m,{})==nil and traces<=5)
svc.candidates[10].actor.visible=true
local found
for i=1,4 do
  traces=0;found=svc:target(m,{})
  assert(traces<=5)
  if found then break end
end
assert(found==svc.candidates[10]);svc.candidates[1].actor.visible=true
assert(svc:target(m,{})==svc.candidates[1])

-- A target that changes sides while a projectile is flying is protected.
local target=svc.candidates[1].actor
svc.combat={damage={eligible=function()return false end,
  hit=function()error('friendly impact submitted to PBZ')end}}
assert(not svc:hit(undead.list()[1],target,position(1),position(1),'arrow',1))

-- A queued final frame from a dismissed group must not advance its successor.
local next_handle,callbacks,ticks=0,{},0
function LoopInGameThreadAfterFrames(_,callback)
  next_handle=next_handle+1;callbacks[next_handle]=callback;return next_handle
end
function CancelDelayedAction(handle) assert(type(handle)=='number') end
svc.tick=function()ticks=ticks+1 end
svc:start();local old=callbacks[svc.loop];svc:stop_loop();svc:start()
old();assert(ticks==0);callbacks[svc.loop]();assert(ticks==1)
""")
print('91 catalogue entries and action profiles, creeper fuse transitions, bounded target search, faction changes and stale callbacks passed.')
