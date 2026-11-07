"""Original rig / animation regressions; a game render check is still required."""
from pathlib import Path
import argparse,json,sys,hashlib,struct

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'build/lua-check'))
from lupa.lua54 import LuaRuntime

def main():
    p=argparse.ArgumentParser();p.add_argument('--assets',type=Path,default=ROOT/'build/command-check/clean-enhanced/assets/private/undead');a=p.parse_args()
    lua=LuaRuntime(unpack_returned_tuples=True)
    lua.execute("package.path=... ..'/src/?.lua;'..package.path",ROOT.as_posix())
    def table(v):
        if isinstance(v,dict):return lua.table_from({k:table(x)for k,x in v.items()})
        if isinstance(v,list):return lua.table_from([table(x)for x in v])
        return v
    data=json.loads((a.assets/'animations.json').read_bytes());rigs=json.loads((a.assets/'manifest.json').read_bytes())
    for name,e in rigs.items():
        for field in ('mesh','texture'):
            raw=(a.assets/e[field]['path']).read_bytes()
            assert len(raw)==e[field]['bytes']and hashlib.sha256(raw).hexdigest()==e[field]['sha256'],name
    from PIL import Image
    sheep=Image.open(a.assets/'sheep.png').convert('RGBA')
    # Original sheep material uses alpha as dye mask. Face and hooves are
    # opaque even where the TGA mask is 3/255, not invisible cutout pixels.
    assert sheep.getpixel((10,10))[3]==255
    assert sheep.getpixel((2,24))[3]==255
    assert rigs['chicken']['bottom']==0 and rigs['chicken']['top']==15
    lua.globals().DATA=table(data);lua.globals().RIGS=table(rigs)
    checks=lua.execute(r'''
local animation=require('presentation.mob_animation');local lib=animation.library(DATA)
local defs=require('content.summon_mobs').list();local count=0
local function near(a,b)assert(math.abs(a-b)<.0001,tostring(a)..' ~= '..tostring(b));count=count+1 end
local function make(name)
 local def;for _,d in ipairs(defs)do if d.name==name then def=d;break end end
 assert(def);local m={def=def,health=20,position={X=0,Y=0,Z=0},move={MovementMode=1},serial=1}
 return m,animation.new(lib,name,RIGS[name].rig)
end
-- Villager's crossed arms are a distinct 3-cube bone. Its offset is local to
-- the bind pivot; interpreting "this" as world Y used to lower arms to feet.
local trader,v=make('wandering_trader');local p=v:update(trader,0)
assert(p.arms and p.leg0 and p.leg1 and p.arms.visible);near(p.arms.rotation[1],-42.97)
near(p.arms.position[2],RIGS.wandering_trader.rig.arms.pivot[2]-1)
local villager,vill=make('villager');local vp=vill:update(villager,0)
assert(vp.arms.position[2]>15,'villager arms lost their bind pivot')
-- Wolf native setup uses absolute coordinates from the 24-unit model origin.
-- Check all four leg pivots and shoulder placement, not just bone presence.
local wolf,wv=make('wolf');local wp=wv:update(wolf,0)
for _,name in ipairs({'leg0','leg1','leg2','leg3'})do
 for i=1,3 do near(wp[name].position[i],RIGS.wolf.rig[name].pivot[i])end
end
near(wp.body.position[2],10);near(wp.upperbody.position[2],10)
near(wp.upperbody.position[3],-3);near(wp.body.rotation[1],90)
near(wp.tail.rotation[1],math.pi/5*57.3)
-- Chicken wings flap while airborne, settle on ground, and retain the
-- matching temperate model/texture variant.
local chicken,cv=make('chicken');local cp=cv:update(chicken,0)
near(cp.wing0.rotation[3],0);near(cv.vars['variable.index'],0)
chicken.move.MovementMode=3
for i=1,5 do cp=cv:update(chicken,i*.05)end
assert(math.abs(cp.wing0.rotation[3])>1);near(cp.wing0.rotation[3],-cp.wing1.rotation[3])
chicken.move.MovementMode=1
for i=6,20 do cp=cv:update(chicken,i*.05)end
near(cp.wing0.rotation[3],0)
-- ShulkerAttackGoal drives the native peek input, not the whole actor.
-- The source lid curve opens/rotates independently from the fixed base,
-- and the head can track a target around the entire shell.
local shulker,sv=make('shulker');shulker.no_ai=true
local sp=sv:update(shulker,0);local closed_y=sp.lid.position[2]
near(sp.lid.rotation[2],0)
shulker.target={};shulker.look_at={X=-100,Y=100,Z=0}
for i=1,22 do sp=sv:update(shulker,i*.05)end
near(sv.vars['variable.shulker.peekamount'],1)
assert(sp.lid.position[2]>closed_y+10);near(sp.lid.rotation[2],360)
near(sp.base.rotation[1],0);near(sp.base.rotation[2],0);near(sp.base.rotation[3],0)
near(sp.head.rotation[2],135)
shulker.target=nil
for i=23,45 do sp=sv:update(shulker,i*.05)end
near(sp.lid.position[2],closed_y);near(sp.lid.rotation[2],0)
local peek=require('rules.shulker_pose')
local idle={};peek.update(idle,0)
local _,state=peek.update(idle,.1,function()return 1 end)
assert(state.raw==30 and state.event=='open')
for i=2,7 do peek.update(idle,i*.1,function(_,n)return n end)end
near(idle.shulker_pose.current,.3)
for i=8,18 do peek.update(idle,i*.1,function(_,n)return n end)end
near(idle.shulker_pose.current,0);assert(idle.shulker_pose.event=='close')
local function at_rate(hz)
 local m={target={},no_ai=true};peek.update(m,0)
 for i=1,hz do peek.update(m,i/hz)end
 return peek.update(m,1.025)
end
near(at_rate(10),at_rate(60))
assert(require('rules.mob_ai').profile('shulker').stationary)
-- Sheep's front/back and left/right legs must remain four independently
-- animated bones with the original diagonal phase relationship.
local sheep,s=make('sheep');s:update(sheep,0)
for i=1,30 do sheep.position.X=i*10;p=s:update(sheep,i*.05)end
local expected=math.cos(s.walk_pos*38.17*math.pi/180)*80*s.walk_speed
near(p.leg0.rotation[1],expected);near(p.leg1.rotation[1],-expected)
near(p.leg2.rotation[1],-expected);near(p.leg3.rotation[1],expected)
local walk=s.walk_pos
for i=31,130 do p=s:update(sheep,i*.05)end
assert(s.walk_pos-walk<1.3 and math.abs(p.leg0.rotation[1])<.001,'blocked mob keeps walking animation')
-- Original action controllers: warden melee and sonic are different actions.
local warden,w=make('warden');w:update(warden,0)
warden.last_attack=.01;warden.last_attack_kind='melee';w:update(warden,.1);p=w:update(warden,.2)
assert(w.controllers['controller.animation.warden.melee_attacking'].state=='attack')
assert(w.controllers['controller.animation.warden.sonic_boom'].state=='default')
warden.last_attack=nil;warden.last_attack_kind=nil;warden.charging_kind='sonic';warden.charge_started=.3
w:update(warden,.3);w:update(warden,.4)
assert(w.controllers['controller.animation.warden.sonic_boom'].state=='sonic_attack')
-- Every registered creature uses original controllers, never the old shared
-- sine-wave pose. Exercise movement, target, charge, attack, flight and water.
local frames=0;local unchanged={};local absent={}
for _,def in ipairs(defs)do
 local m,v=make(def.name);local prior=v:update(m,0);local baseline={}
 for bone,pose in pairs(prior)do baseline[bone]={table.unpack(pose.rotation)}end
 local changed=false
 for i=1,100 do
  local t=i*.05;m.position.X=i>10 and (i-10)*10 or 0
  m.target=i>30 and {}or nil;m.look_at={X=m.position.X+300,Y=90,Z=20}
  m.last_attack=i>50 and 2.5 or nil;m.charge_started=i>40 and i<51 and 2 or nil
  m.swimming=def.aquatic;m.move.MovementMode=def.flies and 5 or def.aquatic and 5 or 1
  local poses=v:update(m,t)
  for bone,pose in pairs(poses)do
   for j=1,3 do assert(pose.rotation[j]==pose.rotation[j]and math.abs(pose.rotation[j])<1e6)
    if math.abs(pose.rotation[j]-baseline[bone][j])>.1 then changed=true end
   end
  end
  frames=frames+1
 end
 if not changed then unchanged[#unchanged+1]=def.name end
 for key in pairs(v.playing)do for bone in pairs(lib.animations[key].bones)do
  if not v.rig[bone]then absent[def.name..':'..bone]=true end
 end end
 count=count+1
end
table.sort(unchanged);print('Static rotation (scale/position can animate): '..table.concat(unchanged,', '))
local missing={};for k in pairs(absent)do missing[#missing+1]=k end;table.sort(missing)
print('Optional animation bones not in selected adult variant: '..table.concat(missing,', '))
return count,frames
''')
    print('Mob rig/animation checks:',checks,'game_loaded=false')

if __name__=='__main__':main()
