"""Intersecting terrain cells and occupancy safety; no inventory regression."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'build/lua-check'))
from lupa.lua54 import LuaRuntime

lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute("local r=...;package.path=r..'/src/?.lua;'..r..'/third_party/dkjson/?.lua;'..package.path", ROOT.as_posix())
lua.execute(r'''
local grid=require('rules.build_grid')
local origin={x=-27.315,y=284477.3,z=-32021.76}
local axes={'x','y','z'};local normals={{X=1,Y=0,Z=0},{X=-1,Y=0,Z=0},
 {X=0,Y=1,Z=0},{X=0,Y=-1,Z=0},{X=0,Y=0,Z=1},{X=0,Y=0,Z=-1},
 {X=.6,Y=0,Z=.8},{X=0,Y=-.8,Z=.6}}
local samples=0
for _,n in ipairs(normals) do for offset=-524,524,7 do
 local hit={X=origin.x+offset,Y=origin.y+offset*.37,Z=origin.z+offset*.91}
 local p=grid.native_surface(hit,n,origin)
 for i,key in ipairs(axes) do
  local value=({hit.X,hit.Y,hit.Z})[i]
  assert(math.abs(p[key]-value)<=50.000001,'surface must remain inside chosen cell')
  local units=(p[key]-origin[key])/100
  assert(math.abs(units-math.floor(units+.5))<1e-8,'global lattice changed')
 end
 samples=samples+1
end end
local zero={x=0,y=0,z=0}
for axis=1,3 do for _,sign in ipairs({-1,1}) do
 local hit={X=0,Y=0,Z=0};local n={X=0,Y=0,Z=0};local upper=({'X','Y','Z'})[axis]
 hit[upper]=50*sign;n[upper]=sign
 local p=grid.native_surface(hit,n,zero);assert(p[axes[axis]]==100*sign,'outward tie')
 n[upper]=-sign;p=grid.native_surface(hit,n,zero);assert(p[axes[axis]]==0,'inward tie')
 hit[upper]=49.999*sign;n[upper]=sign
 assert(grid.native_surface(hit,n,zero)[axes[axis]]==0,'must not prematurely climb a cell')
end end
local p=grid.native_surface({X=0,Y=0,Z=-52},{X=0,Y=0,Z=1},zero)
assert(p.z==-100 and p.z+50==-50,'legacy floor anchor must allow intersecting lower layer')
local first=grid.native_surface({X=19,Y=-81,Z=23},{X=0,Y=0,Z=1})
assert(first.x==19 and first.y==-81 and first.z==23,'first anchor must not float')
for _,n in ipairs(normals) do
 local p=grid.adjacent(zero,n,zero)
 assert(math.abs(p.x)+math.abs(p.y)+math.abs(p.z)==100,'MC face adjacency changed')
end

package.preload.UEHelpers=function() return {} end
StaticFindObject=function(path) return path end
local World=require('host.pbz.build_world');local defs=require('content.blocks')
local player_position={X=1000,Y=1000,Z=1000}
local capsule={GetScaledCapsuleRadius=function() return 30 end,GetScaledCapsuleHalfHeight=function() return 90 end}
local pawn={CapsuleComponent=capsule,K2_GetActorLocation=function() return player_position end}
local queried=0;local nearby={}
local w=setmetatable({pawn=pawn,world_id='test',registry=defs,by_actor={},is_current=function() return true end,
 overlap_components=function(_,point,half) queried=queried+1;assert(half.x>=49.49);return nearby end},World)
local counter=0
local function component(channel,mobility,pawn_response,visibility,is_pawn,mesh,skeletal)
 counter=counter+1;local id=counter
 local owner={IsValid=function() return true end,GetAddress=function() return id end,
  GetFullName=function() return 'actor-'..id end,IsA=function(_,class) return is_pawn and class=='/Script/Engine.Pawn' end}
 return {Mobility=mobility,GetFullName=function() return 'component-'..id end,GetOwner=function() return owner end,GetCollisionObjectType=function() return channel end,
  IsA=function(_,class) return class=='/Script/Engine.MeshComponent' and mesh or class=='/Script/Engine.SkeletalMeshComponent' and skeletal end,
  GetCollisionResponseToChannel=function(_,channel) return channel==2 and pawn_response or visibility end},owner
end
local terrain=component(0,0,2,2,false)
local fixed=component(1,0,2,2,false)
local water=component(31,2,1,2,false)
local trigger=component(21,2,1,0,false)
local dynamic=component(1,2,2,2,false)
local enemy=component(0,0,2,2,true) -- actor classification takes priority over map channel/mobility
local block,owner=component(0,0,2,2,false)
w.by_actor[owner:GetFullName()]={active=true,identity=require('host.pbz.object_identity').capture(owner)}
local record={id='candidate',content_id='pbzmc:dirt',world='test',x=0,y=0,z=0,yaw=0}
nearby={terrain,fixed,water,trigger};assert(w:can_place(record));assert(w.last_placement_check.terrain==2 and queried==1)
nearby={{get=function() return terrain end}};assert(w:can_place(record),'UE4SS output wrapper must unwrap')
nearby={terrain,block};local ok,reason=w:can_place(record);assert(not ok and reason=='mc-block','terrain must not mask MC occupancy')
nearby={terrain,enemy};ok,reason=w:can_place(record);assert(not ok and reason=='character','terrain must not mask characters')
nearby={terrain,dynamic};ok,reason=w:can_place(record);assert(not ok and reason=='dynamic-collider')
nearby={(component(1,2,2,2,false,true,false))};assert(w:can_place(record),'native generated geometry may embed')
nearby={(component(5,2,2,2,false,true,false))};assert(not w:can_place(record),'physics bodies still block')
nearby={(component(1,2,2,2,false,true,true))};assert(not w:can_place(record),'animated non-player actors still block')
nearby={terrain};player_position={X=0,Y=0,Z=0};local before=queried
ok,reason=w:can_place(record);assert(not ok and reason=='player' and queried==before,'player capsule rejected before native query')
player_position.Z=140;assert(w:can_place(record),'touching player feet is allowed')
player_position.Z=139.9;assert(not w:can_place(record),'penetrating player feet is blocked')
player_position={X=1000,Y=1000,Z=1000};record.yaw=90;assert(w:can_place(record))
local rows={}
for i=1,3 do
 local r={id='r'..i,content_id=record.content_id,world=record.world,x=i*100,y=0,z=0,yaw=i==2 and 45 or 0}
 rows[i]={after=r}
end
local opts={native_solid=true};nearby={water,trigger}
assert(w:piston_destinations_clear(rows),'nonblocking level volumes caused redundant narrow checks')
local old=queried
for _,row in ipairs(rows)do assert(w:can_place(row.after,nil,opts,true))end
assert(queried==old,'known-clear group repeated native queries')
player_position={X=200,Y=0,Z=0}
assert(not w:can_place(rows[2].after,nil,opts,true),'clear native overlap bypassed player capsule')
player_position.X=1000
for _,obstacle in ipairs({terrain,dynamic,enemy,block})do
 nearby={trigger,obstacle}
 assert(not w:piston_destinations_clear(rows),'solid blocker admitted by group optimization')
 assert(not w:can_place(rows[1].after,nil,opts,false),'exact fallback missed blocker')
end
w.is_current=function() return false end;assert(not pcall(w.can_place,w,record),'stale world must reject')
print('PASS: '..samples..' surface samples, six boundary directions, legacy/first grid anchors, MC adjacency; terrain + MC/character/dynamic safety, player capsule contact, stale world, one bounded native overlap query')
''')
lua.execute(r'''
local state=require('storage.state');local defs=require('content.blocks')
local data=state.empty()
data.buildings.blocked={id='blocked',content_id='pbzmc:dirt',world='restore',x=0,y=0,z=0,yaw=0}
data.buildings.ready={id='ready',content_id='pbzmc:dirt',world='restore',x=200,y=0,z=0,yaw=0}
local store={generation=0,load=function() return state.clone(data) end,
 commit=function(self,candidate) data=state.clone(candidate);self.generation=self.generation+1;return true end}
local occupied=true;local created={}
local host={world_id='restore',is_current=function() return true end,
 can_place=function(_,r) return not (occupied and r.id=='blocked'),'character' end,
 create=function(_,r) created[r.id]=true;return {rendered=true,colliding=true} end,
 destroy=function() return true end,set_active=function() return true end}
local s=require('runtime.build_session').attach(store,'free',host,defs)
assert(not s:place('pbzmc:dirt',{x=0,y=0,z=0,yaw=0}),'pending volume must stay reserved')
assert(s:restore_batch(1) and s.pending[1]=='ready','occupied head must rotate')
assert(s:restore_batch(1) and created.ready,'later saved blocks must restore')
assert(s:place('pbzmc:dirt',{x=100,y=0,z=0,yaw=0}),'a remote pending block must not disable placement')
assert(s:remove('ready','mined'),'a remote pending block must not disable mining')
assert(not s:restore_batch(1),'all-blocked cycle must request backoff')
occupied=false;assert(s:restore_batch(1) and #s.pending==0 and created.blocked)
assert(not s.reservations:overlap('pbzmc:dirt',{x=0,y=0,z=0,yaw=0}),'restored reservation must retire')
local query=require('host.pbz.build_placement').target
local target={session={pending={'elsewhere'}},store={current=function() return true end},world={
 is_current=function() return true end,line_trace=function(_,a,b) assert(b.Z==-500);return true,{ok=true} end,
 hit_handle=function() return {id='loaded'} end}}
local hit,h=query(target,function() return {X=0,Y=0,Z=0},{X=0,Y=0,Z=-1} end)
assert(hit.ok and h.id=='loaded','building target query cannot depend on global restoration')

local use_calls,mining=0,0;local result='pass'
local h={authorize=function() return true end,cancel=function() end,handlers={}}
for _,name in ipairs({'interact','tool_use','deflect','melee'}) do h.handlers[name]=function() return false end end
h.handlers.mine=function(_,r) if r.held then mining=mining+1;return true end;return false end
h.handlers.use=function() use_calls=use_calls+1;return result=='success',result end
local a=require('runtime.minecraft_actions').new(h)
local c={kind='game',weapon_group='mc',allow_actions=true,epoch=1,input_epoch=1,equipment_revision=1,mode='free',
 main={content_id='pbzmc:dirt',count=1,metadata={}},offhand={content_id='pbzmc:shield',instance_id='test-shield',count=1,metadata={}}}
local function event(kind,seq) return {kind=kind,seq=seq,source='1/1/1',owner_epoch=1,input_epoch=1,equipment_revision=1} end
local ok,why=a:step(0,c,{event('use_press',1)})
assert(ok and a:presentation(0,c).shield_active and use_calls==1,require('dkjson').encode({ok=ok,why=why,calls=use_calls,use=a.using}))
result='success';local ok,why=a:step(.2,c,{})
assert(ok and use_calls==2 and a:presentation(.2,c).shield_active,require('dkjson').encode({ok=ok,why=why,calls=use_calls,use=a.using,last=a.last_use,category=require('content.item_actions').get('pbzmc:dirt')}))
assert(a:step(.3,c,{}) and use_calls==2,'guard retry must respect four-tick delay')
result='fail';assert(a:step(.4,c,{}) and use_calls==3 and a:presentation(.4,c).shield_active)
assert(a:step(.5,c,{event('use_release',2)}) and not a:presentation(.5,c).shield_active)
assert(a:step(.6,c,{event('attack_press',3)}) and mining>0,'normal mining must resume after guard release')
-- Fresh placement failure does not invent a new shield, preserving PASS/FAIL.
local fresh=require('runtime.minecraft_actions').new(h)
assert(fresh:step(1,c,{event('use_press',4)}) and not fresh:presentation(1,c).shield_active)
print('PASS: occupied restoration head deferred; other blocks restore/place/mine; pending space reserved and retired; held shield retries placement without resetting defence or PASS/FAIL')
''')
