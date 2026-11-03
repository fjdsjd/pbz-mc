"""Focused regression for streamed-out boats; production Lua, native doubles.

No game, save file, real input or native process is touched.
"""
from pathlib import Path
import json
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'build/lua-check'))
from lupa.lua54 import LuaRuntime

lua = LuaRuntime(unpack_returned_tuples=True)
lua.globals().root = ROOT.as_posix()
result = dict(lua.execute(r'''
package.path=root..'/src/?.lua;'..root..'/third_party/dkjson/?.lua;'..package.path
local checks=0
local function check(value,why)assert(value,why);checks=checks+1 end
local rules=require('rules.boat');local storage=require('storage.state')
local identity=require('host.pbz.object_identity')
local state=rules.new({x=0,y=0,z=100,yaw=0});local greatest=0
for i=1,2000 do
 local before=state.z;local next=rules.step(state,{}, {kind='air'})
 greatest=math.max(greatest,math.abs(next.z-before))
 check(math.abs(next.z-before)<=2000,'continuous unsupported fall stays within native movement guard')
 state.x,state.y,state.z,state.yaw=next.x,next.y,next.z,next.yaw
end
check(greatest==rules.terminal_fall_step and state.vz==-200,'100-second fall reaches a bounded terminal speed')
local now=0;local callback;local native_worlds=0;local discoveries=0;local log={}
local world={IsValid=function()return true end,GetAddress=function()return 1 end,GetFullName=function()return 'World /Game/Test' end}
local player={position={X=0,Y=0,Z=190},AttributeSetBase={Health={CurrentValue=100}},address=2}
function player:IsValid()return true end
function player:GetAddress()return self.address end
function player:GetFullName()return 'Player' end
function player:GetWorld()return world end
function player:K2_GetActorLocation()return self.position end
local binding={actor=player,actor_id=identity.capture(player),world_id=identity.capture(world),mc_status={}}
function binding:is_current()return true end
local game={GetTimeSeconds=function()return now end,IsGamePaused=function()return false end}
function StaticFindObject(path)
 if path:find('FactionUtils')then return {IsValid=function()return true end,GetFactionRelation=function()return 2 end}end
 return game
end
function FindAllOf()discoveries=discoveries+1;return {}end
function LoopInGameThreadAfterFrames(_,fn)callback=fn;return 1 end
function CancelDelayedAction()callback=nil end
local records=storage.object()
local function record(id,x,z)
 return {id=id,content_id=rules.id,world='/Game/Test',x=x or 0,y=0,z=z or 100,yaw=0}
end
records['a-old-extreme']=record('a-old-extreme',0,-29000000)
records['b-far']=record('b-far',50000)
records['c-good']=record('c-good',0)
local session={store={core={vehicles=records},generation=1},session={},campaign_id='test',epoch=1,mode='free',commits=0}
function session.store:checkout()return {data=self.core}end
function session.session:commit(_,candidate)
 session.commits=session.commits+1;session.store.core=candidate;return true
end
package.loaded['host.pbz.campaign_inventory']={ensure=function()return session end,current=function()return true end}
package.loaded['host.pbz.first_person_camera']={get=function()return nil end}
package.loaded['host.pbz.boat_passenger']={acquire=function(actor,kind)
 local lease={actor=actor,id=identity.capture(actor),capsuleHalfHeight=90}
 function lease:is_current()return not self.closed end
 function lease:pin(p)actor.position=p;return true end
 function lease:release()self.closed=true;return true end
 return lease
end}
package.loaded['host.pbz.boat_world']={new=function()
 native_worlds=native_worlds+1
 local w={world_id='/Game/Test',handles={},spawns=0,ground_calls=0,moves=0,validations=0,closed=0}
 function w:spawn(r)
  self.spawns=self.spawns+1
  local h={id=r.id,pose={x=r.x,y=r.y,z=r.z,yaw=r.yaw},floor=r.z};self.handles[r.id]=h;return h
 end
 function w:valid()self.validations=self.validations+1;return true end
 function w:characters_near_boats()discoveries=discoveries+1;return {}end
 function w:surface(h)
  self.ground_calls=self.ground_calls+1
  return h.air and {kind='air'} or {kind='land',ground_z=h.floor}
 end
 function w:move(h,frame)
  self.moves=self.moves+1
  if h.fail then error('injected-single-boat-move-failure')end
  local dx,dy,dz=frame.x-h.pose.x,frame.y-h.pose.y,frame.z-h.pose.z
  assert(dx*dx+dy*dy+dz*dz<=2000*2000,'boat-move-out-of-range')
  h.pose={x=frame.x,y=frame.y,z=frame.z,yaw=frame.yaw};return h.pose
 end
 function w:render()return true end
 function w:destroy(h)self.handles[h.id]=nil;return true end
 function w:close()self.closed=self.closed+1;return true end
 return w
end}
local M=require('host.pbz.boat_service')
local service=M.ensure(binding,'unused',function(s)log[#log+1]=s end);local native=service.world
local function tick(count)
 for _=1,count do now=now+.05;callback();assert(M.ensure(binding,'unused',function()end)==service)end
end
tick(10)
check(native.spawns==1 and service.boats['c-good']~=nil,'far queue heads do not block the nearby saved boat')
check(service.deferred['a-old-extreme'].reason=='distance'and not service.boats['a-old-extreme'],'extreme old Z retained without native spawn')
check(service.records['a-old-extreme'].z==-29000000 and session.store.core.vehicles['a-old-extreme'].z==-29000000,'legacy record is not clamped, relocated or deleted')
local good=service.boats['c-good'];player.position={X=100000,Y=0,Z=190};tick(1)
local ground,moves,validations,scan=native.ground_calls,native.moves,native.validations,discoveries
tick(620)
check(good.dormant_reason=='distance'and native.ground_calls==ground and native.moves==moves and native.validations==validations,'distant boat does no native support, movement or ownership polling for over 30 seconds')
check(discoveries==scan,'only-distant boats do not discover or capture native enemies')
check(native_worlds==1 and native.closed==0 and not service.failed and session.commits==0,'distant scene never rebuilds the service or flushes invalid poses')
player.position={X=0,Y=0,Z=190};tick(3)
check(not good.dormant_reason and native.ground_calls>ground,'entering wake radius resumes support and simulation')
player.position={X=50000,Y=0,Z=190};tick(25)
local far=service.boats['b-far']
check(far and not service.deferred['b-far'],'unspawned far record activates when player approaches')
check(service:capture(far,player,'player',now),'driver lease acquired')
player.position={X=-100000,Y=0,Z=190};service.input={forward=true};local start=far.state.x
tick(2)
check(service.driver==far and not far.dormant_reason and far.state.x>start,'player-driven boat never sleeps even while the player snapshot is distant')
local rider=far.state.riders[1].key;check(service:release(far,rider,'fixture',false),'driver fixture releases')
player.position={X=0,Y=0,Z=190};tick(3)
local badrecord=record('d-bad',100);service.records['d-bad']=badrecord
local handle=native:spawn(badrecord);handle.air=true;handle.fail=true
service.boats['d-bad']={handle=handle,state=rules.new(badrecord),leases={}}
service.dirty=false;service.moved_at=nil
local commits=session.commits;local prior=good.state.ticks;tick(50)
local bad=service.boats['d-bad']
check(bad.dormant_reason=='simulation-error'and bad.simulation_error:find('injected-single',1,true),'one bad boat enters explicit quarantine')
check(good.state.ticks>prior and not good.simulation_error,'other boats continue maintenance after a single-boat failure')
check(native_worlds==1 and native.closed==0 and not service.failed and M.get(binding)==service,'single-boat failure cannot close or recreate the global service')
check(session.commits==commits and service.records['d-bad'].z==100,'failed motion does not force-flush or change the retained pose')
return {passed=true,assertions=checks,fall_seconds=100,max_fall_step_cm=greatest,
 far_sleep_seconds=31,world_instances=native_worlds,native_runtime_verified=false,
 user_save_written=false,isolated_error=bad.simulation_error}
''').items())
print(json.dumps(result, ensure_ascii=False, indent=2))
