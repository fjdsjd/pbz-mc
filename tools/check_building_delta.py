"""Production building-delta transactions and facade, with memory-only IO.

No live save, input, game process, or inventory/death gameplay regression.
"""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'build/lua-check'))
from lupa.lua54 import LuaRuntime

lua = LuaRuntime(unpack_returned_tuples=True)
lua.globals().root = ROOT.as_posix()
source = (ROOT / 'src/host/pbz/campaign_inventory.lua').read_text('utf-8')
lua.globals().production = source[source.index('function M.build_store(binding)'):source.index('function M.open(binding,lease)')]
lua.execute(r'''
package.path=root..'/src/?.lua;'..root..'/third_party/dkjson/?.lua;'..package.path
local State=require('storage.state');local Player=require('storage.player_state')
local Session=require('storage.session_store');local Durable=require('storage.player_store')
local Definitions=require('content.items');local Inventory=require('runtime.inventory_session')
local function eq(a,b,why)assert(a==b,(why or '')..' expected '..tostring(b)..' got '..tostring(a))end
local function record(id,x,props,world)
 return {id=id,content_id='pbzmc:redstone',world=world or 'map',x=x or 0,y=0,z=0,yaw=0,properties=props or {power=0}}
end
local function fresh(count)
 local core=Player.empty();core.building_grids=State.object({map={x=0,y=0,z=0}})
 core.containers.player.main['1']={content_id='pbzmc:arrow',count=16,metadata=State.object()}
 core.containers.cursor={content_id='pbzmc:golden_apple',count=2,metadata=State.object()}
 core.vehicles=State.object();core.mc_status=require('rules.status_effects').empty()
 for i=1,count or 0 do local id='b'..i;core.buildings[id]=record(id,i*100)end
 local durable={loaded=true,core=core,head={pages=State.object()},generation=20,read_only=false,definitions=Definitions,
  commit=function()error('unexpected durable commit')end}
 return Session.new(durable)
end
local function ticket(s)
 return {owner=s,generation=s.generation,core=s.core,buildings=s.core.buildings,building_grids=s.core.building_grids}
end
local function snapshot(s)
 return {core=s.core,generation=s.generation,dirty=s.dirty,commits=s.commits,head=s.head,
  pending=s.pending_pages,cache=s.page_cache,selected=s.runtime_selected}
end
local function unchanged(s,b)
 eq(s.core,b.core,'failed transaction changed core');eq(s.generation,b.generation);eq(s.dirty,b.dirty);eq(s.commits,b.commits)
 eq(s.head,b.head);eq(s.pending_pages,b.pending);eq(s.page_cache,b.cache);eq(s.runtime_selected,b.selected)
end
local s=fresh(512);s.runtime_selected=7;s.selection_revision=100
s.pending_pages['1']={['1']={content_id='pbzmc:arrow',count=5,metadata={}}}
s.page_cache.keep={sentinel=true}
local prior=snapshot(s);local after=State.clone(s.core.buildings.b1);after.properties.power=15
local original_clone=State.clone;local original_validate=State.validate_buildings
local protected={[s.core]=true,[s.core.buildings]=true,[s.core.containers]=true,[s.pending_pages]=true,[s.page_cache]=true,[s.head]=true}
local clone_count,validated=0,0
State.clone=function(value)
 assert(not protected[value],'delta deep-copied an unchanged core/map/container/page branch')
 clone_count=clone_count+1;return original_clone(value)
end
State.validate_buildings=function(buildings)
 local count=0;for _ in pairs(buildings)do count=count+1 end
 assert(count<=1,'delta validated the entire world');validated=validated+count;return original_validate(buildings)
end
local old_checkout,old_ownership=s.checkout,s.validate_ownership
s.checkout=function()error('delta requested an inventory checkout')end
s.validate_ownership=function()error('delta repeated item ownership validation')end
local t=ticket(s);assert(s:commit_buildings(t,{{before=s.core.buildings.b1,after=after}},s.core.building_grids))
eq(validated,1);assert(clone_count<30);eq(s.generation,21);eq(s.commits,1);assert(s.dirty and t.consumed)
eq(s.core.containers,prior.core.containers);eq(s.core.world_items,prior.core.world_items)
eq(s.core.vehicles,prior.core.vehicles);eq(s.core.mc_status,prior.core.mc_status)
eq(s.core.buildings.b2,prior.core.buildings.b2,'unchanged record not shared')
eq(prior.core.buildings.b1.properties.power,0,'updating a page changed its predecessor')
local detached=State.clone(s.core.buildings)
assert(next(detached) and require('storage.canonical_json')(detached)==require('storage.canonical_json')(s.core.buildings))
local detached_count=0;for _ in pairs(detached)do detached_count=detached_count+1 end;eq(detached_count,512)
eq(s.core.building_grids,prior.core.building_grids);eq(s.pending_pages,prior.pending);eq(s.page_cache,prior.cache);eq(s.head,prior.head)
eq(s.runtime_selected,7);eq(s.selection_revision,100);eq(s.core.containers.player.selected,1)
after.properties.power=1;after.x=50000
eq(s.core.buildings.b1.properties.power,15,'external properties alias');eq(s.core.buildings.b1.x,100,'external record alias')
assert(not s:commit_buildings(t,{{before=s.core.buildings.b2,after=record('b2',200)}}),'consumed ticket reused')
s.checkout=old_checkout;s.validate_ownership=old_ownership;State.clone=original_clone;State.validate_buildings=original_validate

local function reject(changes,grids,mutate_ticket)
 local before=snapshot(s);local t=ticket(s);if mutate_ticket then mutate_ticket(t)end
 local ok,why=s:commit_buildings(t,changes,grids)
 assert(not ok and type(why)=='string','invalid transaction accepted');unchanged(s,before);assert(not t.consumed)
end
local a=State.clone(s.core.buildings.b1);a.properties.power=6
reject({{before=s.core.buildings.b1,after=a}},nil,function(t)t.owner=fresh()end)
reject({{before=s.core.buildings.b1,after=a}},nil,function(t)t.generation=t.generation-1 end)
reject({{before=s.core.buildings.b1,after=a}},nil,function(t)t.core=State.clone(t.core)end)
reject({{before=s.core.buildings.b1,after=a}},nil,function(t)t.buildings=State.clone(t.buildings)end)
reject({});reject({[2]={after=record('new')}})
reject({{before=s.core.buildings.b1,after=a},{before=s.core.buildings.b1,after=a}})
local stale=State.clone(s.core.buildings.b1);stale.properties.power=4
reject({{before=stale,after=a}})
reject({{after=record('b1')}}) -- existing ID cannot be overwritten as insertion
reject({{before=s.core.buildings.b1,after=record('different')}})
reject({{before=s.core.buildings.b1,after=false}})
local bad=State.clone(a);bad.native_handle=123456;reject({{before=s.core.buildings.b1,after=bad}})
bad=State.clone(a);bad.properties.power=16;reject({{before=s.core.buildings.b1,after=bad}})
bad=State.clone(a);bad.x=0/0;reject({{before=s.core.buildings.b1,after=bad}})
bad=State.clone(a);bad.properties=setmetatable({power=1},{__tojson=function()return '0'end});reject({{before=s.core.buildings.b1,after=bad}})
bad=State.clone(a);bad.world='other';reject({{before=s.core.buildings.b1,after=bad}})
bad=State.clone(a);bad.properties.bad=bad;reject({{before=s.core.buildings.b1,after=bad}})
-- A later bad member must not publish the earlier valid member.
reject({{before=s.core.buildings.b1,after=a},{before=s.core.buildings.b2,after=bad}})
reject({{before=s.core.buildings.b1,after=a}},{map={x=100,y=0,z=0}})
reject({{before=s.core.buildings.b1,after=a}},{})
reject({{before=s.core.buildings.b1,after=a}},{map={x=0,y=0,z=0},unrelated={x=0,y=0,z=0}})
s.read_only=true;reject({{before=s.core.buildings.b1,after=a}});s.read_only=nil
local old_generation=s.generation;s.generation=2^53-1;reject({{before=s.core.buildings.b1,after=a}});s.generation=old_generation

-- Mixed add/move/delete and a new world's grid commit once. New grid values
-- are owned copies; unchanged origins and all inventory state remain shared.
local moved=State.clone(s.core.buildings.b3);moved.x=1300
local new=record('new',0,nil,'new-map');local grids=State.clone(s.core.building_grids);grids['new-map']={x=0,y=0,z=0}
local generation=s.generation
assert(s:commit_buildings(ticket(s),{{before=s.core.buildings.b2},{before=s.core.buildings.b3,after=moved},{after=new}},grids))
eq(s.generation,generation+1);assert(not s.core.buildings.b2);eq(s.core.buildings.b3.x,1300);assert(s.core.buildings.new)
grids['new-map'].x=500;eq(s.core.building_grids['new-map'].x,0)
local full=fresh(8192);local untouched=snapshot(full)
assert(not full:commit_buildings(ticket(full),{{after=record('overflow')}}));unchanged(full,untouched)
assert(full:commit_buildings(ticket(full),{{before=full.core.buildings.b1},{after=record('replacement')}}))

-- Actual production build_store facade with actual InventorySession/store.
local binding={};local scene,ender=true,true
local active={binding=binding,store=fresh(256)}
local host={is_current=function()return scene end,ender_access=function()return ender end,
 authorize_selection=function()error('world delta invoked equipment switching')end}
active.session=Inventory.new(active.store,host,'map')
local M={ensure=function()return active end,current=function(b)return scene and b==binding end}
local finishes,finish_error=0,false
local function finish()finishes=finishes+1;if finish_error then error('post-commit report failed')end end
local env=setmetatable({M=M,active=active,state=State,finish=finish},{__index=_G})
assert(load(production,'production-build-store','t',env))()
local facade=M.build_store(binding);local view=facade:load()
local function delta(id,power)
 local before=view.buildings[id];local after=State.clone(before);after.properties.power=power
 local candidate={schema=1,inventory=view.inventory,buildings={},building_grids=view.building_grids}
 for key,value in pairs(view.buildings)do candidate.buildings[key]=value end
 candidate.buildings[id]=after
 return candidate,{{before=before,after=after}}
end
active.store.runtime_selected=8
local direct_checkout=active.store.checkout;local direct_ownership=active.store.validate_ownership
active.store.checkout=function()error('facade delta checked out full inventory')end
active.store.validate_ownership=function()error('facade delta validated inventory')end
local equal=Session.same_building;local comparisons=0
Session.same_building=function(a,b)comparisons=comparisons+1;return equal(a,b)end
local candidate,changes=delta('b1',3);local cached_containers=active.store.core.containers
assert(facade:commit(candidate,changes));view=candidate;eq(active.store.core.containers,cached_containers);eq(active.store.runtime_selected,8)
assert(comparisons<=2,'unchanged core pointer triggered full building comparisons')
candidate,changes=delta('b2',4);active.session.opened=true
assert(not facade:commit(candidate,changes));assert(facade:environmental(function()return facade:commit(candidate,changes)end));view=candidate
eq(active.store.core.containers.cursor.count,2);eq(active.store.runtime_selected,8);assert(not facade.environment)
candidate,changes=delta('b3',5);local fence=snapshot(active.store)
active.session.busy=true;assert(not facade:environmental(function()return facade:commit(candidate,changes)end));unchanged(active.store,fence);active.session.busy=false
active.session.quarantined=true;assert(not facade:environmental(function()return facade:commit(candidate,changes)end));active.session.quarantined=false
active.restart_frozen=true;assert(not facade:environmental(function()return facade:commit(candidate,changes)end));active.restart_frozen=false
active.session.context='ender';ender=false
assert(not facade:environmental(function()return facade:commit(candidate,changes)end));unchanged(active.store,fence)
ender=true;active.session.context='inventory';active.session.opened=false
local real_current=host.is_current
host.is_current=function()active.session.epoch=active.session.epoch+1;return true end
assert(not facade:commit(candidate,changes));unchanged(active.store,fence);host.is_current=real_current

-- An ordinary item transaction deep-clones buildings. The facade falls back
-- once to stable comparison, while retaining that transaction's new cursor.
active.store.checkout=direct_checkout;active.store.validate_ownership=direct_ownership
local inventory=active.store:checkout({});inventory.data.containers.cursor.count=3
assert(active.store:commit(inventory,inventory.data));local cloned_core=active.store.core
comparisons=0;assert(facade:commit(candidate,changes));view=candidate
assert(comparisons>=256);eq(active.store.core.containers,cloned_core.containers);eq(active.store.core.containers.cursor.count,3)
comparisons=0;candidate,changes=delta('b4',6);assert(facade:commit(candidate,changes));view=candidate
assert(comparisons<=2,'clone fallback did not refresh pointer cache')
Session.same_building=equal

-- Undeclared/mismatched changed candidate and concurrent building writers
-- reject without partial publication; old snapshots remain detached.
candidate,changes=delta('b5',7);candidate.buildings.b5=State.clone(candidate.buildings.b5);candidate.buildings.b5.properties.power=9
fence=snapshot(active.store);assert(not facade:commit(candidate,changes));unchanged(active.store,fence)
local independent=record('concurrent',40000)
assert(active.store:commit_buildings(ticket(active.store),{{after=independent}}))
candidate,changes=delta('b5',7);fence=snapshot(active.store)
assert(not facade:commit(candidate,changes));unchanged(active.store,fence)

-- A reporting failure after commit must report success so native geometry is
-- not rolled back. Calling the legacy path remains supported separately.
facade=M.build_store(binding);view=facade:load();candidate,changes=delta('b1',8)
finish_error=true;local saved,warning=facade:commit(candidate,changes);finish_error=false
assert(saved and tostring(warning):find('post%-commit report failed'));eq(active.store.core.buildings.b1.properties.power,8)
view=candidate;local plain=State.clone(view);plain.buildings.b2.properties.power=9
assert(facade:commit(plain));eq(active.store.core.buildings.b2.properties.power,9)
active.store.core.buildings.b2.properties.power=10
assert(not facade:commit(plain),'legacy direct mutation fence was weakened')

-- Connected demolition keeps one atomic action above the 128-row delta
-- ceiling. Exercise the real removal rule, production facade and session
-- store at both sides of that boundary; no durable store call is permitted.
local function removal_boundary(size,fail)
 local group_store=fresh(size)
 for _,r in pairs(group_store.core.buildings)do r.content_id='pbzmc:dirt';r.properties=nil end
 local group_binding={};local group_host={is_current=function()return true end}
 local group_active={store=group_store,binding=group_binding}
 group_active.session=Inventory.new(group_store,group_host,'map')
 local module={ensure=function()return group_active end,current=function(b)return b==group_binding end}
 local environment=setmetatable({M=module,active=group_active,state=State,finish=function()end},{__index=_G})
 assert(load(production,'production-removal-facade','t',environment))()
 local backend=module.build_store(group_binding);local data=backend:load()
 local runtime={data=data,handles={},pending={},world='map',generation=1}
 for id in pairs(data.buildings)do runtime.handles[id]={id=id,active=true}end
 local native_calls=0
 function group_host:set_active(handle,enabled)handle.active=enabled;native_calls=native_calls+1;return true end
 local paths={delta=0,full=0};local delta_commit,full_commit=group_store.commit_buildings,group_store.commit
 group_store.commit_buildings=function(self,...)
  paths.delta=paths.delta+1;if fail then return false,'injected-group-commit-failure'end
  return delta_commit(self,...)
 end
 group_store.commit=function(self,...)
  paths.full=paths.full+1;if fail then return false,'injected-group-commit-failure'end
  return full_commit(self,...)
 end
 local before=snapshot(group_store);local prior_data=runtime.data
 local ids=require('rules.connected_blocks').find(data.buildings,runtime.handles,'b1');eq(#ids,size)
 local yes,why=require('rules.remove_buildings')(runtime,ids,group_host,backend)
 eq(paths.delta,size<=128 and 1 or 0,'delta boundary');eq(paths.full,size>128 and 1 or 0,'full commit boundary')
 if fail then
  assert(not yes and tostring(why):find('injected%-group%-commit%-failure'));unchanged(group_store,before)
  eq(runtime.data,prior_data);eq(native_calls,size*2)
  for id in pairs(data.buildings)do assert(runtime.handles[id].active,'failed atomic group did not reactivate '..id)end
  assert(not runtime.quarantined and not runtime.pending_group)
 else
  assert(yes,tostring(why));eq(why,size);eq(group_store.commits,1);eq(group_store.generation,before.generation+1)
  eq(next(group_store.core.buildings),nil);eq(next(runtime.data.buildings),nil);eq(next(runtime.handles),nil)
  eq(#runtime.pending_group,size);eq(native_calls,size);eq(runtime.group_action,'destroy')
  eq(group_store.core.containers.cursor.count,2);eq(group_store.core.containers.player.main['1'].count,16)
 end
 eq(group_store.flushes,0,'demolition wrote a savepoint')
end
for _,size in ipairs({1,128,129})do removal_boundary(size,false);removal_boundary(size,true)end
print('connected demolition: real remove/facade/session_store 1,128,129; one commit; rollback all; zero flush')

-- The unchanged real flush path persists the delta only at an explicit
-- savepoint, including the pending ender page and runtime selected slot.
local files,writes={},0
local fs={read=function(p)return files[p]end,write=function(p,value)writes=writes+1;files[p]=value end,
 rename=function(a,b)assert(files[a]and not files[b]);files[b]=files[a];files[a]=nil end,
 remove=function(p)files[p]=nil end}
local scope={campaign_id='592f4a22-7fe0-412b-ae11-e87fbba5a832',player_id='local-primary',mode='free'}
local durable=Durable.open('delta-fixture',scope,Definitions,fs);assert(durable:load());local live=Session.new(durable)
local it=live:checkout({['1']=true});it.data.containers.ender['1']={['1']={content_id='pbzmc:arrow',count=12,metadata={}}}
assert(live:commit(it,it.data));live.runtime_selected=9
assert(live:commit_buildings(ticket(live),{{after=record('saved',0)}},{map={x=0,y=0,z=0}}))
eq(writes,0,'gameplay delta wrote disk');assert(live:flush());assert(writes>0)
local restored=Durable.open('delta-fixture',scope,Definitions,fs);assert(restored:load())
assert(restored.core.buildings.saved);eq(restored.core.containers.player.selected,9)
eq(restored:checkout({['1']=true}).data.containers.ender['1']['1'].count,12)

-- Cost evidence is relative within the same Lua runtime, not claimed PBZ FPS.
-- The delta must never call clone/validate with the 4096-block map, and only
-- one modified record is validated per update irrespective of total count.
local perf=fresh(4096);local old=State.validate_buildings;local validations=0
State.validate_buildings=function(map)
 local n=0;for _ in pairs(map)do n=n+1 end;eq(n,1,'performance path full validation');validations=validations+1;return old(map)
end
local began=os.clock()
for i=1,100 do local before=perf.core.buildings.b1;local next=State.clone(before);next.properties.power=i%16
 assert(perf:commit_buildings(ticket(perf),{{before=before,after=next}},perf.core.building_grids))end
local elapsed=(os.clock()-began)*1000;State.validate_buildings=old;eq(validations,100)
print(string.format('building-delta: 4096 records / 100 one-record updates = %.3f ms total (Lua CPU)',elapsed))
local legacy=fresh(4096);began=os.clock()
for i=1,10 do
 local t=legacy:checkout({});t.data.buildings.b1.properties.power=i%16
 assert(legacy:commit(t,t.data))
end
local legacy_elapsed=(os.clock()-began)*1000
print(string.format('full checkout+commit baseline: 4096 records / 10 updates = %.3f ms total (Lua CPU)',legacy_elapsed))
''')
print('PASS building delta: no inventory checkout/full validation/IO, owned changed-record copies, '
      'selection/pages/status preservation, atomic failures/capacity/grids, facade clone fallback/gates, savepoint flush')
