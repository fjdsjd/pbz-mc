"""Potion rules, action routing and shared-host settlement without a game save."""
from pathlib import Path
import sys
root=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(root/'build/lua-check'))
from lupa.lua54 import LuaRuntime
lua=LuaRuntime(unpack_returned_tuples=True)
lua.execute("local r=...;package.path=r..'/src/?.lua;'..r..'/third_party/dkjson/?.lua;'..package.path",root.as_posix())
for path in (root/'src').rglob('*.lua'):
    lua.execute('assert(load(...))',path.read_text(encoding='utf8'))
lua.execute('''
local r=require('rules.status_effects');local p=require('rules.potions')
local s=r.empty()
r.add(s,'slowness',400,5,1000);assert(math.abs(r.speed(s)-.1)<.00001)
r.add(s,'speed',3600,1,1000);assert(math.abs(r.speed(s)-.14)<.00001)
r.validate(s)
s=r.empty();r.add(s,'poison',100,0,1000)
local next,heal,_,pulses=r.advance(s,100,1000)
assert(pulses.poison==4 and pulses.wither==0 and heal==0 and not next.effects.poison)
s=r.empty();r.add(s,'wither',100,1,1000)
local _,_,_,pulses=r.advance(s,100,1000);assert(pulses.wither==5)
s=r.empty();r.add(s,'speed',100,0,1000);r.add(s,'speed',20,1,1000)
s=r.advance(s,20,1000);assert(s.effects.speed.amplifier==0 and s.effects.speed.ticks==80)
r.add(s,'levitation',2147483647,255,1000);r.validate(s)
s=r.advance(s,100,1000);assert(s.effects.levitation.ticks==2147483647)
assert(p.instant('instant_health',0,1,false)==4 and p.instant('instant_health',0,1,true)==-6)
assert(p.instant('instant_damage',1,.5,false)==-6 and p.instant('instant_damage',1,.5,true)==4)
assert(p.immune('poison','zombie')and p.immune('poison','cave_spider')and not p.immune('poison','cow'))
assert(p.immune('wither','wither_skeleton')and not p.immune('wither','zombie'))
assert(p.splash(0)==1 and p.splash(200)==.5 and p.splash(400)==0)
local c=p.cloud()
for i=1,9 do local alive,query=p.cloud_tick(c);assert(alive and not query)end
local alive,query=p.cloud_tick(c);assert(alive and query and c.radius==299.5)
assert(p.cloud_hit(c,'a')and not p.cloud_hit(c,'a'))
for i=1,20 do p.cloud_tick(c)end
assert(p.cloud_hit(c,'a')and c.radius==189.5)
local before=0
for id,def in pairs(p.all())do
 if def.available then
  assert(require('content.items').get(id).stack_limit==1)
  local action=require('content.item_actions').get(id)
  assert(action.use==(def.form=='potion'and 'drink'or 'potion_throw'))
  assert(require('rules.item_catalogue').category(id)=='potions');before=before+1
 end
end
assert(before==123,before)
local a=require('rules.mob_effects')
assert(a.contact('shulker')[1]=='levitation'and a.contact('stray')[2]==600)
assert(a.witch(900,20,{},function()return 0 end)=='slowness')
assert(a.witch(400,20,{},function()return 0 end)=='poison')
assert(a.witch(100,4,{},function()return 0 end)=='weakness')
assert(a.witch(100,4,{weakness=true},function()return 0 end)=='harming')
local actions=require('runtime.minecraft_actions')
local calls={}
local host={handlers={},authorize=function()return true end,cancel=function()end}
for _,name in ipairs({'mine','interact','attack_target','use','consume','eat_feedback','shield'})do
 host.handlers[name]=function(_,record)calls[#calls+1]={name=name,record=record};return name=='consume'or name=='use' end
end
local function test(main,off,kind,hand)
 local act=actions.new(host)
 local c={kind='game',weapon_group='mc',allow_actions=true,epoch=1,input_epoch=1,equipment_revision=1,mode='free',
 main=main and {content_id=main,count=1,metadata={}},offhand=off and {content_id=off,count=1,metadata={}},has_arrow=true}
 assert(act:step(0,c,{}))
 act.use_down=true
 act:_use(.3,c,false,false)
 if kind=='drink'then
  assert(act.using and act.using.kind=='drink'and act.using.hand==hand)
  act:_update(2,c,.05)
  assert(calls[#calls].name=='consume'and calls[#calls].record.kind=='drink')
 else assert(calls[#calls].name=='use'and calls[#calls].record.kind=='potion_throw'and calls[#calls].record.hand==hand)end
end
-- Action records carry validated equipment snapshots; no native click replay.
test('pbzmc:potion_healing',nil,'drink','main')
test(nil,'pbzmc:potion_healing','drink','offhand')
test('pbzmc:splash_potion_poison',nil,'throw','main')
test(nil,'pbzmc:lingering_potion_slowness','throw','offhand')
''')
print('PASS: Lua syntax, 123 available potion variants, stacking, pulse timing, undead inversion, cloud reapplication, mob payloads and both-hand actions')
lua.execute('''
package.loaded['host.pbz.appearance']={valid=function(o)return o~=nil end}
package.loaded['host.pbz.object_identity']={capture=function(o)return o end,matches=function(o,id)return o~=nil and o==id end}
local sections,updates,destroyed,uploaded_red=0,0,0,nil
package.loaded['host.pbz.mesh_bundle']={apply=function()sections=sections+1 end}
local pool=require('host.pbz.status_particles');local status=require('rules.status_effects')
local mesh={K2_SetWorldLocationAndRotation=function()end,SetHiddenInGame=function()end,
 UpdateMeshSection_LinearColor=function(_,_,_,normals,_,_,_,_,colors)
  assert(#normals==0);updates=updates+1;if colors[1]then uploaded_red=colors[1].R end
 end}
local actor={K2_GetActorLocation=function()return {X=0,Y=0,Z=0}end,
 CapsuleComponent={GetScaledCapsuleRadius=function()return 30 end,GetScaledCapsuleHalfHeight=function()return 96 end}}
local binding={actor=actor,mc_status_service={value=status.empty()}}
local pc={PlayerCameraManager={CameraCachePrivate={POV={Location={X=0,Y=0,Z=0},Rotation={Pitch=0,Yaw=0,Roll=0}}}}}
local player,entities,potions={},{},{}
local p=pool.acquire(binding,pc,player,true)
assert(pool.acquire(binding,pc,entities)==p and pool.acquire(binding,pc,potions)==p)
function p:prepare()
 if self.mesh then return end
 self.mesh=mesh;self.actor={K2_DestroyActor=function()destroyed=destroyed+1 end};self.actor_id=self.actor
end
p:step(0);assert(not p.mesh,'idle batch loaded resources')
assert(not p:emit_at(0x00ff00,{X=4000,Y=0,Z=0},0,0),'far particle not culled')
for i=1,1000 do p:emit_at(0x00ff00,{X=100,Y=0,Z=0},0,0)end
assert(#p.particles==128 and p.report.dropped==872)
p:step(.05);local buffer=p.buffer;local positions=buffer.positions
assert(sections==1 and buffer.capacity==128)
-- Same engine time from three callers must not repeat physics or upload.
local rendered=p.report.renders;p:step(.05);p:step(.05);assert(p.report.renders==rendered)
for i=2,50 do p:step(i*.05)end
assert(#p.particles==0 and p.ambient==0 and #p.free==128 and not p.visible)
for i=1,128 do p:emit_at(0x00ff00,{X=100,Y=0,Z=0},0,0)end
p:step(2.55);assert(p.buffer==buffer and p.buffer.positions==positions)
local before_sections=sections
for i=1,2000 do p:emit(1,nil,{X=100,Y=0,Z=0},60,192)end
assert(#p.particles==384 and p.peak==384 and #p.free==0)
p:step(2.6);assert(p.buffer.capacity==384 and sections==before_sections+1)
-- A large past burst must not cause permanent large uploads for a tiny cloud.
for i=#p.particles,4,-1 do p.particles[i]=nil end
for i=1,3 do p.particles[i].max=1000 end
for i=53,64 do p:step(i*.05)end
assert(p.buffer.capacity==16,'low occupancy did not shrink')
-- Invisible bursts do not allocate or upload a section.
local other=pool.new(binding,pc)
for i=1,128 do other:emit_at(0x00ff00,{X=-1000,Y=0,Z=0},0,0)end
other:step(4);assert(not other.mesh and other.report.renders==0)
-- Re-entering the view must overwrite a different sprite's cached color even
-- when this particle occupied that same slot on an older frame.
local swap=pool.new(binding,pc);swap.prepare=p.prepare
swap:emit_at(0x00ff00,{X=100,Y=0,Z=0},0,0)
swap:emit_at(0xff0000,{X=-1000,Y=0,Z=0},0,0)
swap:render(pc.PlayerCameraManager.CameraCachePrivate.POV,10)
swap.particles[1].x=-1000;swap.particles[2].x=100
swap:render(pc.PlayerCameraManager.CameraCachePrivate.POV,10.1);assert(uploaded_red==1)
swap.particles[1].x=100;swap.particles[2].x=-1000
swap:render(pc.PlayerCameraManager.CameraCachePrivate.POV,10.2);assert(uploaded_red==0)
swap:close();destroyed=0
pool.acquire(binding,pc,{}):release(potions);assert(not p.closed)
p:release(player);p:release(entities);assert(not p.closed,'other owner lost shared particles')
for owner in pairs(p.users)do p:release(owner)end
assert(p.closed and destroyed==1 and binding.mc_status_particles==nil)
''')
print('PASS: shared particle lifetime, 128 ambient / 384 total budget, culling, reuse, expiry compaction and same-frame upload deduplication')
lua.execute('''
local C={};C.__index=C;require('host.pbz.entity_effects').install(C)
local values={MaxWalkSpeed=string.unpack('f',string.pack('f',523.173))}
local move=setmetatable({},{__index=values,__newindex=function(_,k,v)values[k]=string.unpack('f',string.pack('f',v))end})
local s={handle={actor={CharacterMovement=move}},leases={}}
local self=setmetatable({},C);local base=move.MaxWalkSpeed
self:_movement(s,'MaxWalkSpeed',.7);local first=move.MaxWalkSpeed
for i=1,100 do self:_movement(s,'MaxWalkSpeed',.7)end
assert(move.MaxWalkSpeed==first,'float32 rounding compounded slow effect')
self:_restore(s,'MaxWalkSpeed');assert(move.MaxWalkSpeed==base,'rounded speed lease did not restore')
move.MaxWalkSpeed=600;self:_movement(s,'MaxWalkSpeed',.7)
move.MaxWalkSpeed=700;self:_restore(s,'MaxWalkSpeed');assert(move.MaxWalkSpeed==700,'external host change overwritten')
''')
print('PASS: native float32 movement remains stable across 100 effect ticks and restores without overwriting external changes')
lua.execute('''
local effects=require('host.pbz.entity_effects');local rules=require('rules.status_effects')
local C={};C.__index=C;effects.install(C)
local actor={AttributeSetBase={Attack={CurrentValue=0}}}
local utility={ModifyCharacterAttributeValue=function(_,a,_,_,delta)a.AttributeSetBase.Attack.CurrentValue=a.AttributeSetBase.Attack.CurrentValue+delta end}
StaticFindObject=function()return utility end
local s={handle={id='player',player=true,actor=actor,identity=actor},attack_attribute={},base_damage=100,written_damage=0,state=rules.empty()}
rules.add(s.state,'weakness',100,0,1000)
local c=setmetatable({effects={player=s},options={player_id='player'},current=function()return true end},C)
local binding={};package.loaded['host.pbz.command_service']={get=function(b)assert(b==binding);return {entities=c}end}
local result=effects.with_attack_base(binding,function(x)assert(actor.AttributeSetBase.Attack.CurrentValue==100);return x end,42)
assert(result==42 and actor.AttributeSetBase.Attack.CurrentValue==0 and not s.borrowed_attack)
local ok=pcall(effects.with_attack_base,binding,function()error('hit-failed')end)
assert(not ok and actor.AttributeSetBase.Attack.CurrentValue==0 and not s.borrowed_attack,'failed MC hit left native attack restored')
package.loaded.UEHelpers={}
local tnt=setmetatable({binding=binding},require('host.pbz.tnt_damage'))
tnt._run=function(self,kind,point,source,id,power,wet,allied)
 assert(self==tnt and kind=='explosion'and point.X==1 and source==nil and id=='qa'and power==4 and wet and allied)
 assert(actor.AttributeSetBase.Attack.CurrentValue==100)
 return {dispatched=2}
end
assert(tnt:run('explosion',{X=1},nil,'qa',4,true,true).dispatched==2)
assert(actor.AttributeSetBase.Attack.CurrentValue==0,'TNT did not return native Weakness lease')
''')
print('PASS: Weakness does not suppress MC damage normalization; native debuff is restored after success and failure')
