"""Regression of live health ownership and data-driven creature goals; no game."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'build/lua-check'))
from lupa.lua54 import LuaRuntime

lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute("local root=...;package.path=root..'/src/?.lua;'..root..'/third_party/dkjson/?.lua;'..package.path", ROOT.as_posix())
checks = lua.execute(r'''
local count=0
local function check(value,message)count=count+1;assert(value,message)end
local goals=require('rules.mob_ai')
local follow=require('rules.mob_follow')
for _,def in ipairs(require('content.summon_mobs').list())do
 local p=goals.profile(def.name);check(p.health>0 and p.health<1e6,def.name..' health')
 if p.ranged then check(p.range>0 and p.interval_min>0 and p.interval_max>=p.interval_min,def.name..' ranged')end
end
check(goals.profile('warden').health==500,'warden health from MC')
check(goals.profile('wolf').health==40 and goals.profile('wolf').damage==4,'tamed wolf, not wild/baby')
local m={def={name='skeleton',interval=3},ai=goals.profile('skeleton')}
check(not goals.ready(m,0,42,800,true,false),'initial sight time')
check(goals.ready(m,1.01,42,800,true,false),'first shot after seeing target')
check(not goals.ready(m,2,42,800,true,false),'no render-frame firing')
check(not goals.ready(m,5,42,800,false,false),'wall cancels charge')
check(not goals.ready(m,6,42,800,true,false),'reacquire needs sight')
check(goals.ready(m,7.1,42,800,true,false),'reacquired target attacked')
m={def={name='blaze',interval=3},ai=goals.profile('blaze')}
check(not goals.ready(m,0,1,500,true,false),'blaze acquire')
check(not goals.ready(m,1,1,500,true,false),'blaze starts charge')
check(not goals.ready(m,8.9,1,500,true,false),'blaze charge before threshold')
check(goals.ready(m,9.01,1,500,true,false),'blaze shot 1')
check(not goals.ready(m,9.1,1,500,true,false),'burst interval')
check(goals.ready(m,9.32,1,500,true,false),'blaze shot 2')
check(goals.ready(m,9.63,1,500,true,false),'blaze shot 3')
check(not goals.ready(m,9.94,1,500,true,false),'burst cannot loop without charging')
m={def={name='zombie'},ai=goals.profile('zombie')}
check(goals.ready(m,0,1,100,true,true),'zombie contact')
check(not goals.ready(m,.1,2,100,true,true),'switching target keeps attack cooldown')
check(goals.ready(m,1.01,2,100,true,true),'melee cooldown ends')
m={serial=1,ai=goals.profile('phantom')}
local p,attacking=goals.fly_goal(m,0,{X=0,Y=0,Z=0},false)
check(not attacking and p.Z==500,'phantom circles above before swoop')
_,attacking=goals.fly_goal(m,10,{X=0,Y=0,Z=0},false)
check(attacking,'phantom swoops')
m.last_hurt=10.1
_,attacking=goals.fly_goal(m,10.2,{X=0,Y=0,Z=0},false,function()return .5 end)
check(not attacking and m.next_pass==25.2,'hurt aborts swoop; MC cooldown interval')

m={}
check(not follow.goal(m,999,false),'idle within start radius')
m.following=follow.goal(m,1000,false);check(m.following,'start at ten blocks')
check(follow.goal(m,500,false),'hysteresis continues inside start radius')
check(not follow.goal(m,200,false),'stop at two blocks')
local _,teleport=follow.goal(m,1300,true);check(not teleport,'combat not abandoned at twelve blocks')
_,teleport=follow.goal(m,2401,true);check(teleport,'combat leash recovery')
_,teleport=follow.goal({command_home={}},9000,false);check(not teleport,'command-owned home is not owner summon')
local seen={}
for i=0,9 do local c=follow.candidate({X=0,Y=0,Z=0},1,i,40)
 local key=math.floor(c.X)..':'..math.floor(c.Y);check(not seen[key],'different fallback locations');seen[key]=true end

package.loaded['host.pbz.appearance']={valid=function(o)return o and o.IsValid and o:IsValid()end}
package.loaded.UEHelpers={}
local identity=require('host.pbz.object_identity')
local serial=0
local function actor()
 serial=serial+1;local a={address=serial,valid=true,bCanBeDamaged=true}
 function a:IsValid()return self.valid end
 function a:GetAddress()return self.address end
 function a:GetFullName()return 'Actor Test.'..self.address end
 function a:SetActorEnableCollision(value)self.collision=value end
 function a:LaunchCharacter(v)self.velocity=v end
 return a
end
local t=0
local creature=actor()
local binding={actor=actor()}
local group={clock={GetTimeSeconds=function()return t end},report={},by_actor={},
 combat={damage={flash={show=function()return true end}}}}
binding.mc_summons=group
m={actor=creature,id=identity.capture(creature),health=20,absorption=2,
 move={StopMovementImmediately=function()end,SetMovementMode=function()end}}
group.by_actor[m.id.address]=m
local living=require('host.pbz.mob_living')
local accepted,r=living.hit(binding,creature,7,'sword1',{direction={X=1,Y=0,Z=0}})
check(accepted and m.health==15 and m.absorption==0 and r.flash,'health, absorption, flash and impulse')
check(not living.hit(binding,creature,7,'sword1',{}),'one transaction per contact')
t=.2;check(not living.hit(binding,creature,7,'sword2',{}),'hurt window equal damage rejected')
t=.3;check(living.hit(binding,creature,10,'stronger',{}) and m.health==12,'stronger hit only adds difference')
t=.51;check(living.hit(binding,creature,5,'later',{}) and m.health==7,'stronger hit did not extend invulnerability')
check(living.hit(binding,creature,7,'command',{command=true}),'explicit command bypass')
check(m.health==0 and m.dying_until and creature.collision==false,'death owns movement/collision cleanup')
check(not living.alive(binding,creature),'dead summon cannot be attacked or targeted')
check(not living.hit(binding,creature,5,'after',{}),'dead summon no duplicate kill')
creature.valid=false;check(not living.find(binding,creature),'stale actor rejected')

-- Real world-adapter jump path with collision doubles: tall obstacles/ceilings
-- must stay collidable, but one-block steps must launch the actual character.
local world=require('host.pbz.undead_world')
local sweeps=0
package.loaded.UEHelpers.GetKismetSystemLibrary=function()return {CapsuleTraceSingle=function()sweeps=sweeps+1;return false end}end
local height,free=100,true
local w=setmetatable({pawn=actor(),combat={trace=function()return true end}},world)
function w:ground(p)return {X=p.X,Y=p.Y,Z=height}end
function w:clear_capsule()return free end
m={actor=actor(),def={radius=30,height=180,speed=250},position={X=0,Y=0,Z=90},steer={X=1,Y=0,Z=0},
 move={MaxWalkSpeed=250,GetGravityZ=function()return -980 end}}
w:obstacle(m,0);check(m.jumps==1 and m.actor.velocity.Z>490,'one-block obstacle jumps')
w:obstacle(m,.1);check(m.jumps==1,'jump cooldown')
height=200;w:obstacle(m,1);check(m.jumps==1,'two-block wall is not jumped or teleported')
height=100;free=false;w:obstacle(m,2);check(m.jumps==1,'low ceiling prevents head clipping')

-- AI target rays have a shared budget, including a large obscured crowd.
local service=require('host.pbz.undead_summons')
local trace_count=0
local s=setmetatable({candidates={},sight_budget=2,world={sight=function()trace_count=trace_count+1;return false end}},service)
for i=1,100 do local a=actor();s.candidates[i]={actor=a,id=identity.capture(a),pos={X=i,Y=0,Z=0}}end
local _,deferred=s:target({def={},position={X=0,Y=0,Z=0}},{})
check(deferred and trace_count==2 and s.sight_budget==0,'crowd visibility cannot overrun query budget')
local target=s:target({def={phases_terrain=true},position={X=0,Y=0,Z=0}},{})
check(target==s.candidates[1] and trace_count==2 and s.sight_budget==0,'dragon can pursue through terrain without spending sight rays')
return count
''')
print(f'{checks} creature reference, goal, health, jump and bounded-work checks passed; game_loaded=false')
