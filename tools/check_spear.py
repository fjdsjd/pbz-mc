"""Exercise the live spear handler with deterministic host collisions and velocities."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'build/lua-check'))
from lupa.lua54 import LuaRuntime

lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute("local r=...;package.path=r..'/src/?.lua;'..r..'/third_party/dkjson/?.lua;'..package.path", root.as_posix())
lua.execute(r'''
local rules=require('rules.minecraft_combat')
local profiles=require('content.combat_profiles')
local catalogue=require('rules.item_catalogue')
for _,material in ipairs({'wooden','stone','copper','iron','golden','diamond','netherite'}) do
  assert(catalogue.category('pbzmc:'..material..'_spear')=='equipment')
  assert(not catalogue.category('pbzmc:'..material..'_spear_lunge_iii'))
end
local function vec(x,y,z)return {X=x,Y=y or 0,Z=z or 0}end
local function actor(x,character)
  local a={x=x,velocity=vec(0),AttributeSetBase={Health={CurrentValue=1e6}},CharacterMovement={MovementMode=1}}
  function a:IsA()return character end
  function a:GetAddress()return self.x end
  function a:GetVelocity()return self.velocity end
  function a:LaunchCharacter()self.pushes=(self.pushes or 0)+1 end
  return a
end
package.loaded['host.pbz.appearance']={valid=function(x)return x~=nil end}
package.loaded['host.pbz.boat_service']={get=function()return nil end}
StaticFindObject=function(class)return class end
local spear=require('host.pbz.spear')
local scaling=require('rules.damage_scaling')
local pawn=actor(0,true)
local c={binding={actor=pawn},actions={record_spear_contact=function()end},hits=0,damage={},sounds={}}
local targets={actor(100,true),actor(280,true),actor(340,true),actor(425,false),actor(440,true),actor(600,true)}
function c:sound(event)self.sounds[event]=(self.sounds[event] or 0)+1 end
function c:aim()return vec(0),vec(1)end
function c:trace(a,b,radius,one,ignore)
  for _,o in ipairs(targets)do
    local visible=o.x>=a.X and o.x<=b.X
    for _,ignored in ipairs(ignore)do if ignored==o then visible=false end end
    if visible then return true,{ImpactPoint=vec(o.x)},o end
  end
  return false
end
function c.damage:eligible(target)return target:IsA()end
function c.damage:hit(o,amount,id,contact)
  assert(contact.kind=='spear')
  o.ids=o.ids or {};assert(not o.ids[id],'duplicate damage on one target in the same game tick')
  o.ids[id]=true;o.damage=amount;o.hits=(o.hits or 0)+1
  local result=scaling.apply(amount,10000,contact.kind,contact.weapon_id,100)
  assert(result.requested>amount and result.scaling_reason=='target-max-growth')
  return true
end
local rec={action_id='test',now=1,elapsed=0,equipment={main={content_id='pbzmc:diamond_spear'},mode='free'}}
local function strike(now,elapsed,charged)
  rec.now=now;rec.elapsed=elapsed;return spear.strike(c,rec,charged)
end
local a,b=targets[2],targets[3]
assert(strike(1,0,false) and a.hits==1 and b.hits==1)
assert(not targets[1].hits and not targets[5].hits and not targets[6].hits)
assert(c.sounds.spear_attack==1 and c.sounds.spear_hit==1)
pawn.velocity=vec(900)
assert(not strike(2,.49,true))                         -- Diamond wind-up.
pawn.velocity=vec(0,1800)
assert(not strike(2.05,.55,true))                      -- Lateral motion gives no bonus.
pawn.velocity=vec(600);b.velocity=vec(600)
assert(strike(2.1,.60,true) and a.hits==2 and b.hits==1) -- Accelerate without leaving contact.
local slow=a.damage
pawn.velocity=vec(1200);b.velocity=vec(-300)
assert(strike(2.15,.65,true) and a.hits==3 and b.hits==2 and a.damage>slow and b.damage>a.damage)
assert(not strike(2.16,.66,true) and a.hits==3)         -- Second render frame, same gameplay tick.
assert(strike(22,20.5,true) and a.hits==4)             -- Stay on the same target beyond Java's last phase.
assert(c.sounds.spear_use==1)
table.insert(targets,1,actor(50,false))
assert(not strike(22.05,20.55,true) and a.hits==4)     -- Wall before the minimum reach blocks the whole shaft.
table.remove(targets,1);table.remove(targets,4)
pawn.velocity=vec(10000)
assert(strike(22.10,20.60,true) and not targets[#targets].hits) -- Speed cannot extend Bedrock reach.
rec.equipment.mode='creative'
assert(strike(22.15,20.65,true) and targets[#targets].hits==1)
local stats=profiles.get('pbzmc:diamond_spear').spear
assert(rules.charge_damage(stats,0,-6,2)>0 and rules.charge_damage(stats,6,6,2)==0)
-- Drive the same discrete events as the pointer adapter. Duplicate frames,
-- release, and loss of equipment ownership must never create extra thrusts.
local actions=require('runtime.minecraft_actions')
local pulses,jabs=0,0
local host={handlers={},authorize=function()return true end,cancel=function()end}
for _,op in ipairs({'mine','interact','attack_target'})do host.handlers[op]=function()return false end end
host.handlers.spear_charge=function()pulses=pulses+1;return true end
host.handlers.spear_jab=function()jabs=jabs+1;return true end
local runner=actions.new(host)
local ctx={kind='game',weapon_group='mc',allow_actions=true,epoch=1,input_epoch=1,equipment_revision=1,mode='free',
  main={content_id='pbzmc:diamond_spear',instance_id='s1',count=1,metadata=require('storage.state').object()}}
local function step(t,button,seq)
  local events={}
  if button then events[1]={kind=button,seq=seq,source='1/1/1',owner_epoch=1,input_epoch=1,equipment_revision=1}end
  local ok,err=runner:step(t,ctx,events);assert(ok,err)
end
step(0,'use_press',1);step(.49);assert(pulses==0)
step(.5);step(.51);step(.55);step(.59);step(.6);assert(pulses==3)
step(20);assert(pulses==4)
step(20.05,'use_release',2);step(20.1);assert(pulses==4)
step(21,'attack_press',3);step(21.05,'attack_release',4);assert(jabs==1)
step(22,'use_press',5);ctx.kind='inactive';step(23);ctx.kind='game';step(24);assert(pulses==4)
-- Visual fatigue may not cancel kinetic damage. Release blends the hand
-- independently of the world action; a new item/epoch cannot inherit it.
step(25,'use_press',7);step(36)
local p=runner:presentation(36,ctx)
assert(p.spear_charge>=11 and p.spear_recover_weight==0)
local count=pulses
step(36.01,'use_release',8);p=runner:presentation(36.01,ctx)
assert(p.spear_charge==0 and p.spear_recover_charge>=11 and p.spear_recover_weight==1)
step(36.08);p=runner:presentation(36.08,ctx)
assert(p.spear_recover_weight>0 and p.spear_recover_weight<1 and pulses==count)
step(36.2);assert(runner:presentation(36.2,ctx).spear_recover_charge==0 and pulses==count)
local visual=require('presentation.minecraft_spear_animation')
for _,tier in ipairs({'wooden','stone','copper','iron','golden','diamond','netherite'}) do
  local s=profiles.get('pbzmc:'..tier..'_spear').spear
  local braced=visual.solve(s,s.delay+.1);local tired=visual.solve(s,s.delay+s.dismount+1)
  local lowered=visual.solve(s,s.delay+s.knockback+1)
  assert(braced.raise==1 and braced.tired==0 and tired.tired==1 and tired.lower==0)
  assert(lowered.lower==1 and lowered.shake==0 and rules.charge_damage(s,8,0,60)>0)
end
assert(visual.hit_feedback(0)==0 and visual.hit_feedback(2)==7.5/16 and visual.hit_feedback(10)==0)
print('PASS: spear combat, held contact, speed scaling, visual stages and release without extra hits')
''')
