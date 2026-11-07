"""Production TNT service with real rules/transactions and isolated PBZ doubles."""
from pathlib import Path
import hashlib
import json
import sys

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'build/lua-check'))
from lupa.lua54 import LuaRuntime
lua=LuaRuntime(unpack_returned_tuples=True)
lua.globals().root=ROOT.as_posix()
lua.execute("package.path=root..'/src/?.lua;'..root..'/third_party/dkjson/?.lua;'..package.path")
raw=lua.execute(r'''
local T=require('rules.tnt');local State=require('storage.state')
local Session=require('runtime.build_session');local remove=require('rules.remove_buildings')
local encode=require('storage.canonical_json');local checks,scenarios=0,0;local failures={}
local function check(ok,why)checks=checks+1;assert(ok,why)end
local function near(a,b,why)check(math.abs(a-b)<1e-7,why or ('not near '..tostring(a)..' / '..tostring(b)))end
local function count(t)local n=0;for _ in pairs(t)do n=n+1 end;return n end
local function run(name,fn)
 scenarios=scenarios+1;local ok,why=pcall(fn)
 if not ok then failures[#failures+1]={scenario=name,error=tostring(why)}end
end
local current_env
local game={GetTimeSeconds=function()return current_env.now end,IsGamePaused=function()return current_env.paused end}
StaticFindObject=function(path)if path:find('GameplayStatics',1,true)then return game end;return path end
LoopInGameThreadAfterFrames=function(frames,fn)current_env.callback=fn;current_env.loop_frames=frames;return 1 end
CancelDelayedAction=function()current_env.cancelled=current_env.cancelled+1 end
package.loaded['host.pbz.campaign_inventory']={current=function(binding)return binding.env.campaign_current end}
package.loaded['host.pbz.building_service']={get=function(binding)return binding.env.build end}
package.loaded['host.pbz.tnt_world']={new=function(binding)return binding.env.world end}
package.loaded['host.pbz.tnt_effects']={new=function(world)return world.env.fx end}
package.loaded['host.pbz.tnt_sounds']={new=function()return current_env.audio end}
package.loaded['host.pbz.tnt_damage']={ready=function()return true end,new=function(binding)return binding.env.damage end}
local Service=require('host.pbz.tnt_service')
local function event(e,s)e.events[#e.events+1]=s end
local function env()
 if current_env then Service.close()end
 local e={now=0,paused=false,current=true,campaign_current=true,store_current=true,cancelled=0,
   events={},spawns={},destroyed={},damages={},burns={},reports={},memory_commits=0,commit_attempts=0,
   explosion_calls={},burn_calls={},reservation_removals={}}
 current_env=e
 e.binding={env=e,actor={},is_current=function()return e.current end}
 e.world={env=e}
 function e.world:spawn(kind,state)
  event(e,'prepare:'..kind)
  if e.fail_prepare then error('injected-prepare')end
  local h={kind=kind,state=state,index=#e.spawns+1};e.spawns[#e.spawns+1]=h;return h
 end
 function e.world:destroy(h)
  event(e,'transient-destroy')
  if e.fail_destroy then error('injected-destroy')end
  h.destroyed=true;e.destroyed[#e.destroyed+1]=h;return true
 end
 function e.world:trace(a,b,r)
  if b.z<48 then return {x=b.x,y=b.y,z=48,nx=0,ny=0,nz=1}end
 end
 function e.world:render()
  if e.fail_render then error('injected-render')end
 end
 function e.world:close()
  e.world_closed=(e.world_closed or 0)+1
  for _,h in ipairs(e.spawns)do h.destroyed=true end
 end
 e.native={world_id='map',is_current=function()return e.current end}
 function e.native:set_active(h,on)
  event(e,(on and 'activate:'or 'deactivate:')..h.id);h.active=on
  if not on and e.fail_hide==h.id or on and e.fail_restore==h.id then return false end
  return true
 end
 function e.native:destroy(h)
  event(e,'persistent-destroy:'..h.id)
  if e.fail_cleanup_destroy then return false end
  h.destroyed=true;return true
 end
 function e.native:line_trace()return e.trace_hit~=nil,e.trace_hit end
 function e.native:hit_handle(hit)return hit and hit.handle end
 function e.native:hit_actor()return e.hit_actor end
 e.session=setmetatable({data=State.empty(),world='map',generation=1,handles={},pending={},host=e.native},Session)
 e.session.reservations={remove=function(_,id)e.reservation_removals[#e.reservation_removals+1]=id end}
 e.store={current=function()return e.store_current end}
 function e.store:environmental(callback)
  if e.fail_environment then error('injected-environment')end
  if self.environment then return false,'environment-busy'end
  self.environment=true;local r=table.pack(pcall(callback));self.environment=nil
  if not r[1]then return false,tostring(r[2])end
  return table.unpack(r,2,r.n)
 end
 function e.store:commit(candidate)
  event(e,'commit');e.commit_attempts=e.commit_attempts+1
  if e.on_commit then e.on_commit(candidate)end
  if e.fail_commit then return false,'injected-commit'end
  e.memory_commits=e.memory_commits+1;e.last_commit=candidate;return true
 end
 e.build={session=e.session,store=e.store,world=e.native,progress=.4}
 function e.build:target()return e.hit,e.hit_handle end
 e.fx={particles={}}
 function e.fx:explosion(p)
  event(e,'fx:explosion');if e.fail_explosion_fx then error('injected-explosion-fx')end
 end
 function e.fx:smoke(p)if e.fail_smoke then error('injected-smoke')end end
 function e.fx:tick(dt)if e.fail_fx_tick then error('injected-fx-tick')end end
 e.audio={played=0,counts={}}
 function e.audio:play(kind)
  if e.fail_sound then error('injected-sound')end
  self.played=self.played+1;self.counts[kind]=(self.counts[kind]or 0)+1
 end
 e.damage={}
 function e.damage:tnt_exposure(_,state)return e.cover or 1 end
 function e.damage:explode(p,source,id,power,underwater)
  e.underwater=underwater
  check(type(p.X)=='number' and type(p.Y)=='number' and type(p.Z)=='number','damage boundary requires uppercase UE vector')
  check(power==4 and source==nil,'service forwards original explosion power')
  event(e,'damage:'..id);e.damages[#e.damages+1]=id;e.explosion_calls[id]=(e.explosion_calls[id]or 0)+1
  return {accepted=true}
 end
 function e.damage:burn(p,id)
  check(type(p.X)=='number' and type(p.Z)=='number','fire damage requires uppercase UE vector')
  e.burns[#e.burns+1]=id;e.burn_calls[id]=(e.burn_calls[id]or 0)+1
  return {accepted=true}
 end
 function e.damage:close()e.damage_closed=(e.damage_closed or 0)+1 end
 local function log(message)
  if e.fail_report then error('injected-report')end
  e.reports[#e.reports+1]=message
 end
 e.service=assert(Service.ensure(e.binding,'unused-test-directory',log))
 function e.step(dt)e.now=e.now+dt;e.callback()end
 function e.add(id,kind,x,pending,world)
  e.session.data.buildings[id]={id=id,content_id=kind or 'pbzmc:tnt',x=x or 0,y=0,z=48,yaw=0,world=world or 'map'}
  if pending then e.session.pending[#e.session.pending+1]=id
  else e.session.handles[id]={id=id,active=true}end
  e.session:notify({{after=e.session.data.buildings[id]}})
 end
 e.step(0)
 return e,e.service
end
local aim=function()return {X=0,Y=0,Z=45},{X=1,Y=0,Z=0}end
local function fire(e,s)
 e.hit={ImpactPoint={X=200,Y=0,Z=0},ImpactNormal={Z=1}}
 local ok,result=s:ignite(aim);check(ok and result=='success','flint creates surface fire')
 local id,f=next(s.fires);return id,f
end

run('prime preparation and commit rollback',function()
 local e,s=env();e.add('a');e.build.mining='a';local original=e.session.data;local cube=e.session.handles.a
 e.fail_prepare=true;local primed=s:prime('a',4)
 check(not primed and e.session.data==original and cube.active and e.commit_attempts==0,'failed transient preparation leaves persistent cube untouched')
 e.fail_prepare=false;e.fail_commit=true;e.events={}
 primed=s:prime('a',4)
 check(not primed and e.session.data==original and cube.active and not cube.destroyed,'failed memory transaction restores original colliding cube')
 check(e.events[1]=='prepare:tnt' and e.events[2]=='deactivate:a' and e.events[3]=='commit' and e.events[4]=='activate:a','prepare precedes reversible hide and commit')
 check(e.spawns[1].destroyed and count(s.primed)==0 and s.primes==0,'failed transient is cleaned and never gains timer ownership')
 check(e.build.mining=='a' and e.build.progress==.4,'failed prime retains mining target')
 e.fail_commit=false;check(s:prime('a',4),'retry succeeds')
 check(not e.session.data.buildings.a and not e.session.handles.a and s.primed.a,'successful prime removes persistent ownership exactly once')
 check(e.memory_commits==1 and e.build.mining==nil and e.build.progress==0,'successful prime is one memory transaction')
 local attempts=e.commit_attempts;local state=s.primed.a.state
 check(not s:prime('a',.5) and e.commit_attempts==attempts and s.primed.a.state==state,'repeat prime never removes or resets twice')
 check(e.session:poll_cleanup() and cube.destroyed,'post-commit cleanup destroys hidden persistent handle')
end)

run('allow_pending transaction rollback and commit boundary',function()
 local e=env();e.add('live','pbzmc:tnt',0);e.add('pending','pbzmc:dirt',100,true);e.add('keep','pbzmc:stone',800,true)
 local original=e.session.data;local pending=e.session.pending;local cube=e.session.handles.live
 e.on_commit=function(candidate)
  check(e.session.data==original and e.session.pending==pending and #pending==2,'pending queue and data remain original during commit')
  check(#e.reservation_removals==0 and not candidate.buildings.live and not candidate.buildings.pending and candidate.buildings.keep,'reservations remain until successful commit')
 end
 e.fail_commit=true;local ok=remove(e.session,{'live','pending'},e.native,e.store,true)
 check(not ok and e.session.data==original and e.session.pending==pending and #pending==2,'pending queue survives rejected commit')
 check(cube.active and not cube.destroyed and e.session.handles.live==cube and #e.reservation_removals==0,'live cube and reservations roll back together')
 e.fail_commit=false;check(remove(e.session,{'live','pending'},e.native,e.store,true),'mixed restored/pending removal succeeds')
 check(#e.session.pending==1 and e.session.pending[1]=='keep' and #e.reservation_removals==1 and e.reservation_removals[1]=='pending','only committed removed pending IDs release reservation')
 check(not e.session.handles.live and e.session:poll_cleanup() and cube.destroyed,'live handle is destroyed only after ownership commit')
 e=env();e.add('pending',nil,0,true)
 check(not remove(e.session,{'pending'},e.native,e.store,false),'pending removal still requires explicit capability')
 check(not remove(e.session,{'pending','pending'},e.native,e.store,true) and e.commit_attempts==0 and #e.session.pending==1,'duplicate group IDs do not alter pending ownership')
end)

run('prime pending TNT and rollback quarantine',function()
 local e,s=env();e.add('pending',nil,0,true)
 check(s:prime('pending',4) and #e.session.pending==0 and #e.reservation_removals==1,'unrestored saved TNT can become one transient without phantom restore')
 check(e.session:poll_cleanup() and not e.session.quarantined,'empty pending-handle group exits quarantine')
 e,s=env();e.add('a');local cube=e.session.handles.a;e.fail_commit=true;e.fail_restore='a'
 check(not s:prime('a',4) and e.session.quarantined and e.session.pending_group[1]==cube,'failed rollback retains cleanup quarantine')
 check(not s:prime('a',4),'quarantined failed rollback blocks a second prepared transient')
 e.fail_restore=nil;e.fail_commit=false;check(s:prime('a',4),'cleanup retry reactivates before a fresh prime')
end)

run('chain queue four attempts per tick and fuse identity',function()
 local e,s=env();for i=1,9 do local id='c'..i;e.add(id,nil,i*20,true);s.chain[id]=1.75 end
 e.step(.05);check(s.primes==4 and count(s.chain)==5,'one tick primes at most four chained TNTs')
 e.step(.05);check(s.primes==8 and count(s.chain)==1,'remaining chain work persists across ticks')
 e.step(.05);check(s.primes==9 and count(s.chain)==0,'chain work finishes without loss')
 for id,p in pairs(s.primed)do near(p.state.fuse,1.75,'queued fuse remains unchanged');check(not s:prime(id,.5),'active chain cannot be restarted')end
 e,s=env();for i=1,6 do local id='c'..i;e.add(id,nil,i*20,true);s.chain[id]=1 end
 e.fail_commit=true;e.step(.05)
 check(e.commit_attempts==4 and count(s.chain)==6 and s.primes==0,'failed chain transactions remain queued with four-attempt budget')
 e.fail_commit=false;e.step(.05);check(s.primes==4 and count(s.chain)==2,'chain retry commits only pending items')
 e,s=env();e.add('future',nil,100,true);local entity={state={x=0,y=0,z=48},handle={},action_id='source-one'}
 s:explode('source-one',entity);local original=s.chain.future
 s:explode('source-two',{state=entity.state,handle={},action_id='source-two'})
 check(original and s.chain.future==original,'two surrounding blasts do not reroll queued chain fuse')
end)

run('wet and dry cannon, cover, current and unchanged fuse',function()
 for _,case in ipairs({{wet=true,cover=1},{wet=true,cover=0},{wet=false,cover=1}})do
  local e,s=env();e.cover=case.cover;local samples=0
  e.binding.mc_fluid_sampler={
   water_at=function(_,x,y,z)near(z,5.125,'MC blast height');return case.wet end,
   tnt_current=function()samples=samples+1;return {x=0,y=1,z=0}end}
  e.add('load',nil,180);e.add('charge');e.add('wall','pbzmc:dirt',75)
  e.add('unlit',nil,260);check(s:prime('load',3));check(s:prime('charge',0))
  local shot=s.primed.load.state;shot.vx=0;shot.vy=0;shot.vz=0
  local commits=e.memory_commits;e.step(.05)
  check(e.underwater==case.wet and #e.damages==1,'entity blast survives wet block policy')
  check((shot.vx>100)==(case.cover==1),'blast impulse uses cover')
  near(shot.vy,28,'current is additive');near(shot.age,.05);near(shot.fuse,3)
  check(samples==1,'current only sampled on active physics tick')
  check((e.session.data.buildings.wall~=nil)==case.wet,'wet blast preserves the wall')
  check((s.chain.unlit==nil)==case.wet,'wet blast never primes stable TNT')
  if case.wet then check(e.memory_commits==commits,'wet blast made no building transaction')end
  local x=shot.x;e.step(.05)
  check((shot.x>x+1)==(case.cover==1),'next tick moves the launched primed entity')
 end
end)
run('eight explosion budget retains all overdue TNT',function()
 local e,s=env();for i=1,21 do local id='t'..i;e.add(id,nil,i*1000);check(s:prime(id,0),'test TNT primes')end
 e.step(.05);check(#e.damages==8 and count(s.primed)==13,'first tick dispatches eight blasts')
 e.step(.05);check(#e.damages==16 and count(s.primed)==5,'already exploded pure states survive until next dispatch budget')
 e.step(.05);check(#e.damages==21 and count(s.primed)==0,'all deferred blasts eventually dispatch')
 e.step(.05);check(#e.damages==21 and s.explosions==21,'later tick cannot replay retired blast')
 for _,calls in pairs(e.explosion_calls)do check(calls==1,'each action ID dispatches damage once')end
end)

run('failed chained preparation retains queue and other active timers',function()
 local e,s=env();e.add('live');e.add('future',nil,1000,true)
 check(s:prime('live',.2));s.chain.future=1.75;e.fail_prepare=true
 e.step(.1)
 check(not s.closed and s.primed.live and s.chain.future==1.75 and e.session.data.buildings.future,'failed chain preparation preserves queue and active fuse')
 e.step(.1)
 check(not s.closed and #e.damages==1 and not s.primed.live and s.chain.future==1.75,'another active TNT still explodes once while preparation fails')
 check(e.memory_commits==1 and #e.spawns==1,'failed preparation never mutates persistent pending TNT')
 e.fail_prepare=false;e.step(.1)
 check(s.primed.future and not s.chain.future and not e.session.data.buildings.future,'later successful preparation consumes queued ownership once')
 near(s.primed.future.state.fuse,1.75,'retry keeps original queued fuse')
end)

run('all registered blocks use real demolition transactions and leave other worlds/ranges intact',function()
 local e,s=env();local ids={}
 for _,name in ipairs({'dirt','stone','oak_log','stripped_oak_log','oak_planks','cobblestone','glass'})do
  local id='in-'..name;ids[#ids+1]=id;e.add(id,'pbzmc:'..name,100)
  e.add('far-'..name,'pbzmc:'..name,900)
  e.add('other-'..name,'pbzmc:'..name,100,false,'other-map')
 end
 e.add('pending','pbzmc:glass',120,true);e.add('chain','pbzmc:tnt',300);e.add('source')
 check(s:prime('source',0));e.fail_commit=true;e.step(.05)
 for _,id in ipairs(ids)do check(s.demolish[id] and e.session.data.buildings[id] and e.session.handles[id].active,'failed batch preserves '..id)end
 check(s.demolish.pending and #e.damages==1,'pending restoration shares retry, damage emitted once')
 e.fail_commit=false;e.step(.05)
 for _,id in ipairs(ids)do
  local name=id:sub(4)
  check(not e.session.data.buildings[id] and not e.session.handles[id],'successful batch removes record and collision handle for '..name)
  check(e.session.data.buildings['far-'..name] and e.session.data.buildings['other-'..name],'distance and world isolation preserved for '..name)
 end
 check(not e.session.data.buildings.pending and s.removed==8 and #e.damages==1,'all eight removals commit once without replaying blast')
 check(s.primed.chain and not e.session.data.buildings.chain,'neighboring TNT is primed, not silently demolished')
end)

run('demolition failure retries without replaying blast',function()
 local e,s=env();e.add('source');e.add('dirt','pbzmc:dirt',100);e.add('pending','pbzmc:dirt',150,true);e.add('stone','pbzmc:stone',400)
 check(s:prime('source',0));e.fail_commit=true;e.step(.05)
 check(#e.damages==1 and s.demolish.dirt and s.demolish.pending and e.session.data.buildings.dirt,'failed demolition remains queued but damage still dispatches once')
 check(e.session.handles.dirt.active and e.session.pending[1]=='pending','failed demolition preserves collision and pending queue')
 e.fail_commit=false;e.step(.05)
 check(not e.session.data.buildings.dirt and not e.session.data.buildings.pending and e.session.data.buildings.stone,'retry removes only in-range destructible MC blocks')
 check(count(s.demolish)==0 and s.removed==2 and #e.damages==1,'retry commits removal without replaying damage')
end)

run('FX sound report failures cannot swallow damage or fuse',function()
 local e,s=env();e.add('source');check(s:prime('source',.1))
 e.fail_explosion_fx=true;e.fail_smoke=true;e.fail_render=true;e.fail_fx_tick=true;e.fail_sound=true;e.fail_report=true;e.fail_destroy=true
 e.step(.05);check(not s.closed and s.primed.source,'cosmetic failure leaves live timer running')
 e.step(.05);check(not s.closed and #e.damages==1 and not s.primed.source,'cosmetic and report failures do not swallow explosion damage')
 e.step(.05);check(#e.damages==1,'cosmetic retries never replay damage')
end)

run('unexpected demolition failure cannot swallow claimed explosion',function()
 local e,s=env();e.add('source');e.add('dirt','pbzmc:dirt',100);check(s:prime('source',0))
 e.session:poll_cleanup();e.fail_environment=true;local entity=s.primed.source
 local ok=pcall(s.explode,s,'source',entity)
 check(ok and #e.damages==1 and not s.primed.source,'unexpected environmental exception must not discard claimed blast damage')
 check(s.demolish.dirt and e.session.data.buildings.dirt,'failed world change remains queued intact')
end)

run('surface fire can be extinguished and does not duplicate',function()
 local e,s=env();local id,f=fire(e,s);local ok,result=s:ignite(aim)
 check(ok and result=='consume' and count(s.fires)==1 and #e.spawns==1,'duplicate nearby ignition reuses existing fire')
 e.hit=nil;check(s:extinguish(aim) and count(s.fires)==0 and f.handle.destroyed,'left-attack service entry extinguishes targeted fire')
 check(s.extinguished==1 and not s:extinguish(aim),'same extinguished fire cannot be removed twice')
 e.step(1);check(#e.burns==0,'extinguished fire has no future damage')
 e,s=env();id,f=fire(e,s);e.hit={ImpactPoint={X=50,Y=0,Z=45},ImpactNormal={Z=1}}
 check(not s:extinguish(aim) and s.fires[id],'solid nearer surface blocks extinguishing through terrain')
end)

run('eight second fire lifecycle has unique bounded damage',function()
 local e,s=env();local id,f=fire(e,s)
 for i=1,80 do e.step(.1)end
 check(count(s.fires)==0 and f.handle.destroyed and #e.burns==16,'fire expires after eight active seconds and original half-second damage ticks')
 for _,calls in pairs(e.burn_calls)do check(calls==1,'fire tick IDs cannot replay')end
 e.step(.1);check(#e.burns==16,'expired fire does not keep applying damage')
end)

run('weapon selection and container state do not own timers',function()
 local e,s=env();e.add('source');check(s:prime('source',4));local id,f=fire(e,s)
 for i=1,40 do
  e.binding.weapon_group=i%2==0 and 'pbz'or 'mc';e.container_open=i%3==0;e.step(.1)
 end
 check(#e.damages==1 and count(s.primed)==0 and not s.closed,'fuse completes through repeated MC PBZ and container changes')
 check(f.state.age>3.99 and #e.burns==9,'fire continues independently of selected weapon and UI')
end)

run('pause stalls and lifecycle boundaries',function()
 local e,s=env();e.add('source');check(s:prime('source',4));local id,f=fire(e,s)
 e.step(.1);local age=s.primed.source.state.age;local fire_age=f.state.age;local damage=#e.burns
 e.paused=true;e.step(20);near(s.primed.source.state.age,age,'pause freezes fuse');near(f.state.age,fire_age,'pause freezes fire')
 check(#e.burns==damage,'pause emits no fire damage')
 e.paused=false;e.step(.05);near(s.primed.source.state.age,age+.05,'resume does not catch up paused time')
 local before=s.primed.source.state.age;e.step(120);near(s.primed.source.state.age,before+.1,'long stall has bounded point-one-second update')
 e.current=false;e.step(.05)
 check(s.closed and Service.get(e.binding)==nil and e.cancelled==1 and e.damage_closed==1 and e.world_closed==1,'identity change closes timer and transient ownership')
 local total=#e.damages+#e.burns;e.step(10);check(#e.damages+#e.burns==total,'stale callback produces no gameplay effects')
 check(not s:prime('source',4),'stale service cannot accept new ignition')
end)
if current_env then Service.close()end
return {checks=checks,scenarios=scenarios,failures=failures,passed=#failures==0,native_runtime_verified=false}
''')
result={key:value for key,value in raw.items() if key!='failures'}
result['failures']=[dict(value.items()) for _,value in raw['failures'].items()]
result['source_sha256']={p.relative_to(ROOT).as_posix():hashlib.sha256(p.read_bytes()).hexdigest()
    for p in (ROOT/'src/host/pbz/tnt_service.lua',ROOT/'src/rules/tnt.lua',ROOT/'src/rules/remove_buildings.lua')}
print(json.dumps(result,ensure_ascii=False,indent=2))
sys.exit(0 if result['passed'] else 1)
