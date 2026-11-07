"""Targeted TNT physics, fuse, blast, fire and starter-unlock checks (no game IO)."""
from pathlib import Path
import hashlib
import json
import sys

ROOT=Path(__file__).resolve().parents[1]
SOURCE=ROOT/'research/upstream/wukong-steve/src/SteveTransformation/MinecraftWorld.cs'
source=SOURCE.read_text(encoding='utf-8')
for fragment in (
    'new FVector(-Math.Sin(angle)*4,-Math.Cos(angle)*4,400)',
    'e.TrailAge-=.05;e.Velocity.Z-=80',
    'point,destination,48',
    'e.Velocity.X*=.7f;e.Velocity.Y*=.7f;e.Velocity.Z*= -.5f',
    'point=destination;e.Velocity*=.98',
    '1-(left+.05)/.5',
    'Math.Ceiling(left*20)/5%2',
    'Prime(other,.5+random.NextDouble()*1.5)',
    'other.Model=="stone"?220:500',
    'Math.Max(.2f,5*exposure*exposure)',
    'offset+new FVector(0,0,70)',
    'e.NextDamage=e.Age+.5',
    'Damage.Hit(player,unit,.18f',
):
    assert fragment in source, f'Pinned upstream TNT contract changed: {fragment}'
sys.path.insert(0,str(ROOT/'build/lua-check'))
from lupa.lua54 import LuaRuntime
lua=LuaRuntime(unpack_returned_tuples=True)
lua.globals().root=ROOT.as_posix()
lua.execute("package.path=root..'/src/?.lua;'..root..'/third_party/dkjson/?.lua;'..package.path")
result=dict(lua.execute(r'''
local T=require('rules.tnt');local checks=0
local function check(ok,why)assert(ok,why);checks=checks+1 end
local function near(a,b,why)check(math.abs(a-b)<1e-7,why or ('not near: '..tostring(a)..' / '..tostring(b)))end
local function new(fuse,random01)
 local s=T.new({x=10,y=20,z=100});assert(T.prime(s,fuse,random01));return s
end
check(T.fuse_seconds==4 and T.tick_seconds==.05 and T.sweep_radius==48,'four-second fuse and 20 Hz sweep')
local s=T.new({x=0,y=0,z=0});local idle=T.advance(s,100)
check(not idle.exploded and idle.steps==0 and s.age==0,'unlit buildings do not age or move')
check(T.prime(s),'first ignition accepted');near(s.vx,0);near(s.vy,-4);near(s.vz,400)
local frame=T.advance(s,.049);check(frame.steps==0 and #frame.smoke==0,'subtick waits for one complete physics step')
frame=T.advance(s,.001);check(frame.steps==1 and #frame.smoke==1,'subtick accumulates at twenty Hz')
near(s.x,0);near(s.y,-.2);near(s.z,16);near(s.vy,-3.92);near(s.vz,313.6)
near(frame.smoke[1].z,66,'smoke is fifty centimetres above resolved body')
local age,ticks,fuse,vx=s.age,s.ticks,s.fuse,s.vx
check(not T.prime(s,.5,.25),'repeat ignition is idempotent')
check(s.age==age and s.ticks==ticks and s.fuse==fuse and s.vx==vx,'repeat ignition cannot retime or kick again')
s=new(4,.25);near(s.vx,-4);near(s.vy,0,'quarter-turn ignition uses original horizontal magnitude')

local function run(parts,sweep)
 local s=new();local exploded,smoke=0,0
 for _,dt in ipairs(parts)do local f=T.advance(s,dt,sweep);exploded=exploded+(f.exploded and 1 or 0);smoke=smoke+#f.smoke end
 return s,exploded,smoke
end
local base,events,smoke=run({4})
check(base.ticks==80 and base.exploded and events==1 and smoke==80,'whole-fuse frame advances exactly eighty ticks and one explosion')
for _,fps in ipairs({20,30,60,144})do
 local parts={};for i=1,4*fps do parts[#parts+1]=1/fps end
 local other,count,particles=run(parts)
 for _,axis in ipairs({'x','y','z','vx','vy','vz','age'})do near(other[axis],base[axis],'frame-rate invariant '..axis)end
 check(other.ticks==80 and count==1 and particles==80,'frame-rate invariant events')
end
local long,count=run({.017,.183,.7,100});near(long.z,base.z,'long frame stops movement at fuse, not after explosion')
check(long.ticks==80 and count==1,'long frame has bounded fuse work')
local retired=T.advance(long,100)
check(not retired.exploded and retired.steps==0 and #retired.smoke==0,'retired TNT cannot replay blast, movement or particles')
check(not T.prime(long),'retired TNT cannot restart')
s=new(.525);frame=T.advance(s,2)
check(frame.exploded and s.ticks==10,'fractional chain fuse ends before an extra whole physics step');near(s.age,.525)
s=new(0);frame=T.advance(s,0);check(frame.exploded and frame.steps==0,'zero fuse detonates without post-fuse movement')

local function ground(from,to,radius)
 check(radius==48,'sweep radius is upstream sphere size')
 if to.z<=48 then return {x=to.x,y=to.y,z=48,nx=0,ny=0,nz=1} end
end
s=new();s.z=48;s.vx=10;s.vy=20;s.vz=-100
frame=T.advance(s,.05,ground)
near(s.x,10.5);near(s.y,21);near(s.z,48);near(s.vx,6.86);near(s.vy,13.72);near(s.vz,88.2,'ground collision applies bounce then drag')
s=new();s.vx=100;s.vy=20;s.vz=80
frame=T.advance(s,.05,function(from,to)return {x=12,y=to.y,z=to.z,nx=-1,ny=0,nz=0}end)
near(s.x,12);near(s.vx,-98);near(s.vy,19.6);near(s.vz,0,'side wall reflects velocity rather than applying ground friction')
local flat={};for i=1,80 do flat[i]=.05 end
local function floor_sweep(from,to)
 if to.z<=48 then return {x=to.x,y=to.y,z=48,nx=0,ny=0,nz=1}end
end
local a=run({4},floor_sweep);local b=run(flat,floor_sweep)
near(a.x,b.x);near(a.y,b.y);near(a.z,b.z);near(a.vz,b.vz,'bounces remain frame-rate independent')
s=new();local snapshot={x=s.x,y=s.y,z=s.z,vx=s.vx,vy=s.vy,vz=s.vz,age=s.age,ticks=s.ticks}
local calls=0
check(not pcall(T.advance,s,.1,function(from,to)
 calls=calls+1;if calls==2 then return {x=to.x,y=to.y,z=to.z,nx=0,ny=0,nz=0}end
end),'invalid collision normal rejects update')
for key,value in pairs(snapshot)do check(s[key]==value,'failed multi-step sweep leaves state unchanged: '..key)end

near(T.chain_fuse(0),.5);near(T.chain_fuse(.5),1.25)
check(T.chain_fuse(.999999)<2,'chain fuse is upper-exclusive two seconds')
check(T.block_effect('pbzmc:tnt',799.999,false)=='chain','inside eight blocks chains unlit TNT')
check(T.block_effect('pbzmc:tnt',800,false)==nil and T.block_effect('pbzmc:tnt',0,true)==nil,'chain boundary excludes radius and already primed TNT')
s=new(T.chain_fuse(.5));T.advance(s,.2);local original=s.fuse
check(not T.prime(s,T.chain_fuse(0)) and s.fuse==original,'a second explosion cannot shorten or reset an active chain fuse')
check(T.block_effect('pbzmc:dirt',499.99)=='remove' and T.block_effect('pbzmc:dirt',500)==nil,'dirt uses strict five-block threshold')
check(T.block_effect('pbzmc:stone',219.99)=='remove' and T.block_effect('pbzmc:stone',220)==nil,'stone uses strict 2.2-block threshold')
local blocks=require('content.blocks');local expected={tnt={800,'chain'},dirt={500,'remove'},stone={220,'remove'},
 oak_log={500,'remove'},stripped_oak_log={500,'remove'},oak_planks={500,'remove'},cobblestone={220,'remove'},glass={500,'remove'}}
for _,kind in ipairs({'oak_door','iron_door','end_rod','lever','redstone_dust','redstone_torch','repeater',
 'comparator','observer','piston','sticky_piston','slime_block','honey_block','bucket'})do expected[kind]={500,'remove'}end
expected.redstone_block={220,'remove'}
for _,id in ipairs(blocks.catalogue())do
 if id=='pbzmc:water_bucket' or id=='pbzmc:lava_bucket' or id=='pbzmc:obsidian' then
  check(T.block_effect(id,0,false)==nil,id..' survives a normal explosion')
 else
 local name=id:match('^pbzmc:(.+)$');local def=blocks.get(id);local e=expected[name]
 if not e then
  assert(def.construction or name=='spawner','new block needs an explicit explosion acceptance case: '..id)
  local resistance=def.blast_resistance or (name=='spawner'and 6)or 0
  e=resistance>=1200 and {0,nil}or {resistance>=6 and 220 or 500,'remove'}
 end
 if e[1]==0 then check(T.block_effect(id,0,false)==nil,id..' remains blast resistant')else
 check(T.block_effect(id,0,false)==e[2] and T.block_effect(id,e[1]-.001,false)==e[2],id..' reacts at the center and inside its radius')
 check(T.block_effect(id,e[1],false)==nil and T.block_effect(id,800,false)==nil,id..' respects strict radius boundary')
 end
 end
end
check(T.block_effect('native:terrain',0)==nil and T.block_effect('pbzmc:ender_chest',0)==nil,'unknown/original geometry is never removed by rule')
local blast=T.blast(0);near(blast.coefficient,5);near(blast.impulse,2000)
blast=T.blast(400);near(blast.exposure,.5);near(blast.coefficient,1.25);near(blast.impulse,1000)
blast=T.blast(800);near(blast.coefficient,.2);near(blast.impulse,0,'native radius edge has minimum damage but no knockback')
check(T.blast(800.001)==nil and T.blast(0,false)==nil,'out of radius and occluded actors receive no blast')
local impulse=T.knockback({x=300,y=400,z=0},1000)
near(math.sqrt(impulse.x^2+impulse.y^2+impulse.z^2),1000);check(impulse.z>0,'original upward-biased knockback direction')
impulse=T.knockback({x=0,y=0,z=-70},1000);near(impulse.x,0);near(impulse.z,0,'degenerate safe-normal impulse stays finite')
near(T.visual(4).scale,1);near(T.visual(.5).scale,1);near(T.visual(.2).scale,1.01875)
check(T.visual(.4).flash==1 and T.visual(.2).flash==0 and T.visual(.2).white,'five-tick white flash alternation')
near(T.visual(0).scale,1+.9^4*.3,'final pulse follows upstream plus-one-tick interpolation')

local f=T.new_fire({x=1,y=2,z=3});local burn=T.advance_fire(f,0)
check(burn.damage_ticks==0 and burn.smoke_ticks==0,'zero elapsed time emits no fire work')
burn=T.advance_fire(f,.01);check(burn.damage_ticks==1 and burn.smoke_ticks==0,'fire damage begins on its first update')
burn=T.advance_fire(f,.49);check(burn.damage_ticks==1 and burn.smoke_ticks==1 and burn.frame==10,'fire reaches half-second boundary without a catch-up smoke burst')
local function run_fire(fps)
 local f=T.new_fire({x=1,y=2,z=3});local damage,smoke,expires=0,0,0
 for i=1,fps*8 do local result=T.advance_fire(f,1/fps)
  damage=damage+result.damage_ticks;smoke=smoke+result.smoke_ticks;expires=expires+(result.expired and 1 or 0)
 end
 return f,damage,smoke,expires
end
for _,fps in ipairs({20,30,60,144})do
 local fire,damage,smoke,expires=run_fire(fps)
 check(fire.expired and damage==16 and smoke==39 and expires==1,'eight-second fire frame independence')
 local expired=T.advance_fire(fire,100)
 check(not expired.expired and expired.damage_ticks==0 and expired.smoke_ticks==0,'expired fire cannot replay events')
end
local slow,damage,smoke=run_fire(1)
check(slow.expired and damage<=8 and smoke<=8,'low frame rate preserves expiry without catch-up burst')
check(T.fire_damage(109.999)==.18 and T.fire_damage(110)==nil,'fire has strict 110cm radius and original coefficient')
for _,bad in ipairs({-1,0/0,math.huge,'1'})do
 check(not pcall(T.advance,new(),bad),'invalid delta rejected')
 check(not pcall(T.blast,bad),'invalid blast distance rejected')
 check(not pcall(T.chain_fuse,bad),'invalid random rejected')
end
check(not pcall(T.chain_fuse,1),'random source upper bound is exclusive')
check(not pcall(T.prime,T.new({x=0,y=0,z=0}),5),'fuse cannot create unbounded catch-up work')

-- Only the new starter unlock transaction is checked here. This is not a
-- repeated whole-inventory lifecycle or death/load regression.
local U=require('rules.tnt_unlock');local S=require('storage.state')
local slots=require('rules.container_slots');local definitions=require('content.items')
local function core()local c=S.empty();c.containers=slots.empty();return c end
local c=core();local unlocked,status=U.apply(c,'campaign-a')
check(unlocked~=c and not c.tnt_unlocked and not c.flint_unlocked,'unlock is copy-on-write')
check(unlocked.tnt_unlocked and unlocked.flint_unlocked,'independent markers are set together when space exists')
check(status.tnt.address=='player/hotbar/1' and status.flint.address=='player/hotbar/2','first free mixed-hotbar slots receive the two items')
local tnt=slots.get(unlocked.containers,status.tnt.address);local flint=slots.get(unlocked.containers,status.flint.address)
check(tnt.content_id=='pbzmc:tnt' and tnt.count==1 and flint.content_id=='pbzmc:flint_and_steel','starter references use stable IDs')
check(flint.instance_id=='flint-unlock-campaign-a' and not flint.metadata.durability,'flint has stable instance identity and no durability')
check(slots.get(c.containers,'player/hotbar/1')==nil and slots.validate(unlocked.containers,definitions),'original candidate and all existing container constraints remain valid')
check(U.apply(unlocked,'campaign-a')==unlocked,'repeated unlock is a true identity no-op')
local draft=slots.edit(unlocked.containers);draft:set(status.flint.address,nil);unlocked.containers=draft.data
check(U.apply(unlocked,'campaign-a')==unlocked and slots.get(unlocked.containers,status.flint.address)==nil,'claimed one-time item is not recreated after later removal')

c=core();local draft=slots.edit(c.containers)
for _,address in ipairs(slots.player_slots(true))do draft:set(address,{content_id='pbzmc:dirt',count=1,metadata=S.object()})end
c.containers=draft.data
local full,report=U.apply(c,'campaign-b')
check(full==c and report.tnt.status=='inventory-full' and report.flint.status=='inventory-full','full bag defers both unlocks without replacing inventory')
draft=slots.edit(c.containers);draft:set('player/main/7',nil);c.containers=draft.data
local partial,report=U.apply(c,'campaign-b')
check(partial.tnt_unlocked and not partial.flint_unlocked and report.tnt.address=='player/main/7','one free space unlocks TNT independently')
check(report.flint.status=='inventory-full' and not c.tnt_unlocked,'flint stays pending and original core unchanged')
draft=slots.edit(partial.containers);draft:set('player/main/8',nil);partial.containers=draft.data
local both,report=U.apply(partial,'campaign-b')
check(both.tnt_unlocked and both.flint_unlocked and report.flint.address=='player/main/8','later free slot grants only deferred flint')
check(slots.get(both.containers,'player/main/7').content_id=='pbzmc:tnt' and slots.get(both.containers,'player/main/6').content_id=='pbzmc:dirt','pending grant preserves existing item ownership')
check(slots.validate(both.containers,definitions),'partial grant keeps equipment instance unique')
c=core();draft=slots.edit(c.containers)
draft:set('ender/3/4',{content_id='pbzmc:tnt',count=1,metadata=S.object()})
draft:set('cursor',{content_id='pbzmc:flint_and_steel',count=1,metadata=S.object(),instance_id='existing-flint'})
c.containers=draft.data;local existing,report=U.apply(c,'campaign-c')
check(existing.containers==c.containers and report.tnt.status=='existing' and report.flint.status=='existing','existing owned items set markers without extra copies')
check(report.tnt.address=='ender/3/4' and report.flint.address=='cursor','existing ender and cursor ownership counts')
check(slots.validate(existing.containers,definitions),'existing-container candidate validates')
return {passed=true,checks=checks,native_runtime_verified=false}
''').items())
result['source_sha256']={p.relative_to(ROOT).as_posix():hashlib.sha256(p.read_bytes()).hexdigest()
    for p in (ROOT/'src/rules/tnt.lua',ROOT/'src/rules/tnt_unlock.lua',SOURCE)}
print(json.dumps(result,ensure_ascii=False,indent=2))
