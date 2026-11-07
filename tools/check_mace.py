"""Target the mace's fall threshold, catalogue, input priority and PBZ falling timer."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'build/lua-check'))
from lupa.lua54 import LuaRuntime

lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute("local r=...; package.path=r..'/src/?.lua;'..r..'/third_party/dkjson/?.lua;'..package.path", ROOT.as_posix())
lua.execute(r'''
local combat=require('rules.minecraft_combat')
assert(combat.smash_bonus(1.5,5)==0)
for _,case in ipairs({{2,8},{3,12},{5,16},{8,22},{12,26}})do
  assert(combat.smash_bonus(case[1],0)==case[2])
  assert(combat.smash_bonus(case[1],5)==case[2]+2.5*case[1])
end
local fall=require('rules.jump_critical').fall
local state=fall(nil,2000,true,-2000,.25)
assert(fall(state,1550,true,-2450,.2).distance==450)
assert(fall(state,100,true,-2000,.05).distance==0)
local scale=require('rules.damage_scaling')
assert(scale.apply(82,30000,'mace','pbzmc:mace',100).requested>scale.apply(82,300,'mace','pbzmc:mace',100).requested)
local item=require('rules.item_catalogue')
local profiles=require('content.combat_profiles')
assert(#profiles.catalogue('mace')==8)
for _,id in ipairs(profiles.catalogue('mace'))do assert(item.category(id)=='equipment')end

local runner=require('runtime.minecraft_actions')
local hits,blocked=0,false
local host={handlers={},authorize=function()return true end,cancel=function()end}
host.handlers.mine=function()return blocked end
host.handlers.attack_target=function()return false end
host.handlers.mace=function(_,record) assert(record.equipment.main.content_id=='pbzmc:mace');hits=hits+1;return true end
local actions=runner.new(host)
local ctx={kind='game',weapon_group='mc',allow_actions=true,epoch=1,input_epoch=1,equipment_revision=1,mode='free',
  main={content_id='pbzmc:mace',instance_id='m1',count=1,metadata=require('storage.state').object()}}
local function button(t,kind,seq)
  assert(actions:step(t,ctx,{{kind=kind,seq=seq,source='1/1/1',owner_epoch=1,input_epoch=1,equipment_revision=1}}))
end
button(1,'attack_press',1);button(1.02,'attack_release',2);assert(hits==1)
blocked=true;button(3,'attack_press',3);button(3.1,'attack_release',4);assert(hits==1)
ctx.kind='inactive';blocked=false;button(5,'attack_press',5);assert(hits==1)

-- Deferring the premature airborne kill must leave landing damage authoritative.
package.loaded['host.pbz.object_identity']={capture=function(p)return p end,matches=function(a,b)return a==b end}
local clock,active,floor,probes=1,true,true,0
local api={}
function api:K2_IsTimerActiveHandle()return active end
function api:K2_ClearTimerHandle()assert(active);active=false end
function api:K2_SetTimer(p,name,delay)assert(name=='TeleportToSafe' and delay==.1);active=true;return 2 end
function api:LineTraceSingle()probes=probes+1;return floor end
function StaticFindObject(path)
  if path:find('GameplayStatics') then return {GetTimeSeconds=function()return clock end} end
  return api
end
local p={BeforeFallingLocation={Z=4000},DeadDepth=2000,CharacterMovement={MovementMode=3}}
local pos={X=20,Y=10,Z=2500}
function p:K2_GetActorLocation()return pos end
function p:GetVelocity()return {Z=-1600}end
local s={binding={actor=p,mc_mace_owner={}},report={},value={totem_cooldown=1},totem_hand=function()return nil end}
local gate=require('host.pbz.native_totem_fall')
gate.tick(s);assert(active and probes==0)
pos.Z=2200;gate.tick(s);assert(not active and probes==1 and p.BeforeFallingLocation.Z==4000)
gate.tick(s);assert(probes==1)
floor=false;clock=1.12;gate.tick(s);assert(active and p.BeforeFallingLocation.Z==4000)
floor=true;clock=1.25;gate.tick(s);assert(not active)
s.binding.mc_mace_owner=nil;gate.tick(s);assert(active)
p.CharacterMovement.MovementMode=1;gate.tick(s);assert(not s.totem_fall)

-- Drive the production host hit handler against a fixed PBZ adapter. A contact
-- rejected by the native damage service cannot grant landing protection or wind.
package.loaded['host.pbz.appearance']={valid=function(a)return a~=nil end}
package.loaded['host.pbz.first_person_camera']={get=function()return nil end}
package.loaded['host.pbz.build_world']={object_types={0}}
package.loaded['host.pbz.item_interface']={reset_fall_after_teleport=function()end}
local lib={LineTraceSingle=function()return false end,SphereOverlapActors=function()return false end}
package.loaded.UEHelpers={GetKismetSystemLibrary=function()return lib end}
local capsule={GetScaledCapsuleHalfHeight=function()return 90 end}
p.CapsuleComponent=capsule;p.CharacterMovement.MovementMode=3
function p:LaunchCharacter(impulse,xy,z)self.impulse=impulse;assert(not xy and z)end
local target={CharacterMovement={MovementMode=1},CapsuleComponent=capsule,AttributeSetBase={Resistance_Physical={CurrentValue=.4}}}
function target:GetAddress()return 2 end
function target:K2_GetActorLocation()return {X=175,Y=0,Z=2190}end
local fx={count=0,burst=function(self)self.count=self.count+1 end}
local owner={binding={actor=p},damage={eligible=function()return true end},mace_fx=fx,hits=0,now=1}
function owner:aim()return {X=0,Y=0,Z=2200},{X=1,Y=0,Z=0}end
function owner:trace()return true,{ImpactPoint=target:K2_GetActorLocation()},target end
function owner:sound()return true end
local accept=false
function owner.damage:hit(t,amount,id,ctx)
  assert(t==target and amount>0 and ctx.kind=='mace' and id=='attempt');return accept
end
local strike=require('host.pbz.mace').strike
local r={action_id='attempt',strength=1,equipment={main={content_id='pbzmc:mace_wind_ii'}}}
owner.fall_state={distance=800};assert(not strike(owner,r))
assert(p.BeforeFallingLocation.Z==4000 and not p.impulse and fx.count==0)
accept=true;assert(strike(owner,r));assert(p.BeforeFallingLocation.Z==2200 and p.impulse.Z==3500 and fx.count==1)
owner.fall_state={distance=800};owner.binding.mc_gliding={}
assert(strike(owner,r) and not owner.last_mace.smash and fx.count==1)
local ordinary=owner.last_mace.base
r.equipment.main.content_id='pbzmc:mace_breach'
assert(strike(owner,r) and math.abs(owner.last_mace.base*.6-ordinary*.84)<1e-6)
print('PASS: eight mace variants, actual input path, fall thresholds, HP scaling, bounded approach and missed landing')
''')
