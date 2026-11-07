"""Deterministic combustion rules plus real memory-transaction host fixtures."""
from pathlib import Path
import json,sys
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'build/lua-check'))
from lupa.lua54 import LuaRuntime
lua=LuaRuntime(unpack_returned_tuples=True)
lua.globals().root=ROOT.as_posix()
lua.execute("package.path=root..'/src/?.lua;'..root..'/third_party/dkjson/?.lua;'..package.path")
rules=lua.execute(r'''
local F=require('rules.fire_network');local T=require('rules.tnt');local count=0
local function check(v,why)count=count+1;assert(v,why)end
local function equal(a,b,s)check(a==b,s or tostring(a)..' ~= '..tostring(b))end
local function env(random)
 local e={cells={},removed={},primed={},visual={},created=0}
 function e.put(x,y,z,id,props)e.cells[F.key(x,y,z)]={content_id=id,id=F.key(x,y,z),properties=props,x=x,y=y,z=z}end
 function e.read(x,y,z)return e.cells[F.key(x,y,z)]end
 e.n=F.new({read=e.read,sturdy=function(c)return c and c.content_id~='pbzmc:water'and c.content_id~='pbzmc:lava'end,
  blocks_lava=function(c)return require('content.fire_reference').lava_blockers[c.content_id]end,
  ignite=function(f,life)e.created=e.created+1;e.visual[f.key]={life=life};return true,f.key end,
  extinguish=function(id)e.visual[id]=nil;return true end,
  burn=function(rows)
   if e.reject then return false end
   for _,r in ipairs(rows)do
    if r.cell.content_id=='pbzmc:tnt'then e.primed[#e.primed+1]=r.cell.id else e.removed[#e.removed+1]=r.cell.id end
    e.cells[r.cell.id]=nil
   end
   return true
  end}, {random=random or function()return 0 end})
 return e,e.n
end
local a,b,c=F.fuel({content_id='pbzmc:oak_planks'});equal(a,5);equal(b,20);check(c,'planks ignited by lava')
a,b,c=F.fuel({content_id='pbzmc:oak_log'});equal(a,5);equal(b,5);check(c,'log lava flag')
a,b=F.fuel({content_id='pbzmc:tnt'});equal(a,15);equal(b,100)
for _,id in ipairs({'stone','crimson_planks','warped_planks','glass'})do
 a,b=F.fuel({content_id='pbzmc:'..id});equal(a,0,id);equal(b,0,id)
end
a,b,c=F.fuel({content_id='pbzmc:oak_stairs',properties={waterlogged=true}});equal(a,0);equal(b,0);equal(c,false)
local e,n=env();e.put(0,0,-1,'pbzmc:stone');check(n:ignite(0,0,0),'supported fire')
local entry=n.fires['0,0,0'];equal(e.visual[entry.key].life,8)
n:advance(20);check(n:ignite(0,0,0),'duplicate succeeds');equal(n.fires[entry.key],entry);equal(e.created,1)
equal(n:advance(29).events,0,'original thirty tick delay');equal(n:advance(30).events,1)
local s=T.new_fire({x=0,y=0,z=0});local out=T.advance_fire(s,9)
check(s.expired and out.damage_ticks==0 and out.smoke_ticks==0,'hitch expires flame without damage/smoke catch-up')
e,n=env();e.put(0,0,-1,'pbzmc:stone');e.put(1,0,0,'pbzmc:oak_planks');e.put(-1,0,0,'pbzmc:tnt');e.put(0,1,0,'pbzmc:crimson_planks')
check(n:ignite(0,0,0),'fuel ignition');equal(e.visual['0,0,0'].life,60)
n:advance(30,1);equal(#e.primed,1,'fire activates TNT');equal(#e.removed,1,'wood burns away');check(e.read(0,1,0),'nether wood survives')
check(#n.heap==n.count+n.lava_count,'one scheduled event per live entry')
e,n=env();e.put(0,0,-1,'pbzmc:stone');e.put(1,0,0,'pbzmc:oak_planks');check(n:ignite(0,0,0))
e.reject=true;n:advance(30,1);check(e.read(1,0,0),'failed host burn leaves wood');e.reject=false;n:advance(60,1);check(not e.read(1,0,0),'retry burns')
e,n=env(function(bound)return bound==3 and 1 or 0 end)
e.put(0,0,0,'pbzmc:lava');e.put(1,0,1,'pbzmc:oak_planks');n:changed(0,0,0)
equal(n.lava_count,1);n:advance(1,1);check(n.fires['0,0,1'],'lava rising air next to wood ignites')
e.put(0,0,1,'pbzmc:water');n:changed(0,0,1);equal(n.count,0,'water extinguishes and cancels event')
e.cells['0,0,0']=nil;n:changed(0,0,0);equal(n.lava_count,0);equal(#n.heap,0,'removed lava cannot re-ignite')
e,n=env();e.put(0,0,0,'pbzmc:lava');e.put(-1,-1,0,'pbzmc:oak_log');n:changed(0,0,0);n:advance(1,1)
check(n.fires['-1,-1,1'],'lava zero-pass starts above neighboring wood')
e,n=env(function(bound)return bound==3 and 1 or 0 end)
e.put(0,0,0,'pbzmc:lava');e.put(0,0,1,'pbzmc:stone');e.put(1,0,2,'pbzmc:oak_planks');n:changed(0,0,0);n:advance(1,1);equal(n.count,0,'solid interrupts lava walk')
e,n=env();e.put(1,0,0,'pbzmc:oak_planks');check(n:ignite(0,0,0),'side fuel supports flame')
e.cells['1,0,0']=nil;n:changed(1,0,0);equal(n.count,0,'last side fuel removal extinguishes')
e,n=env();for i=1,512 do e.put(i*10,0,0,'pbzmc:lava');n:changed(i*10,0,0)end
for i=1,32 do e.put(i*10,0,-2,'pbzmc:stone');check(n:ignite(i*10,0,-1))end
check(not n:ignite(0,0,0,{surface=true}),'hard flame budget');equal(#n.heap,544)
local work=n:advance(100000,2);equal(work.events,2,'large stall remains bounded');check(work.reads<800,'local read budget');check(#n.heap<=544)
local reads=n.reads;equal(n:advance(100000,0).events,0);equal(n.reads,reads,'no work no reads')
for id,cell in pairs(e.cells)do if cell.content_id=='pbzmc:lava'then e.cells[id]=nil;n:changed(cell.x,cell.y,cell.z)end end
equal(n.lava_count,0);check(#n.heap<=32,'cancelled lava has no stale heap growth')
return count
''')
# Reuse the service fixture's native doubles and real build-session transactions.
fixture=(ROOT/'tools/check_tnt_service.py').read_text()
raw=fixture.split("raw=lua.execute(r'''",1)[1].split("''')",1)[0]
extra=r'''
run('low FPS fire work remains bounded and fair',function()
 local e,s=env();local seen={};local total=0;local smoke=0
 function e.damage:burn(_,id)seen[id:match('^(fire/%d+)')]=true;total=total+1;return {}end
 function e.fx:smoke()smoke=smoke+1 end
 for i=1,32 do check(s:add_fire({x=i*200,y=0,z=0},60),'fire creation')end
 s.last_time=0
 for i=1,16 do
  local before,before_smoke=total,smoke;e.now=i*.5;s:tick()
  check(total-before<=4 and smoke-before_smoke<=4,'per-frame emission bound')
 end
 check(count(seen)==32,'all fire cells receive damage work under 2 FPS')
 e.now=70;s:tick();check(not next(s.fires),'hitch still expires every flame')
end)
run('environment burns commit atomically and fire TNT has full fuse',function()
 local e,s=env();local F=require('rules.fire_network');local origin={x=0,y=0,z=48}
 local mech={index={}}
 function mech:cell(r)return {x=math.floor(r.x/100+.5),y=math.floor(r.y/100+.5),z=math.floor((r.z-48)/100+.5)}end
 function mech:position(x,y,z)return {x=x*100,y=y*100,z=z*100+48}end
 function mech:read(x,y,z)
  for _,r in pairs(e.session.data.buildings)do local p=self:cell(r);if p.x==x and p.y==y and p.z==z then return r end end
  if z<0 then return {native_terrain=true}end
 end
 e.build.mechanisms=mech
 function e.build:cancel()self.mining=nil;self.progress=0 end
 s.fire_environment=require('host.pbz.fire_environment').new(s);local env=s.fire_environment
 env.network.random=function()return 0 end
 e.session.on_change=function(changes)env:changed(changes)end
 e.add('wood','pbzmc:oak_planks',100);e.add('tnt','pbzmc:tnt',-100)
 check(env:ignite(origin,true),'host fire creation')
 e.fail_commit=true;env:tick(1.5)
 check(e.session.data.buildings.wood and e.session.data.buildings.tnt and next(env.pending),'failed burn retains all fuel')
 e.fail_commit=false;env:tick(.05);e.session:poll_cleanup();env:tick(.05)
 check(not e.session.data.buildings.wood and s.primed.tnt,'successful retry burns wood and primes TNT')
 check(s.primed.tnt.state.fuse==4,'fire uses full original fuse, not explosion-chain fuse')
 check(env.burned==1 and env.primed==1,'one environmental ownership change each')
 check(#env.network.heap<=env.network.count+env.network.lava_count,'no stale environment timers')
end)
'''
raw=raw.replace('if current_env then Service.close()end\nreturn',extra+'\nif current_env then Service.close()end\nreturn')
result=lua.execute(raw)
failures=[dict(v.items())for _,v in result['failures'].items()]
print(json.dumps(dict(passed=not failures,rule_checks=rules,host_checks=result['checks'],host_scenarios=result['scenarios'],failures=failures),indent=2))
sys.exit(bool(failures))
