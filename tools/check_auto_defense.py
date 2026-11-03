"""Exercise PBZ strike ordering independently of Unreal using the shipped Lua rules."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'build/lua-check'))
from lupa.lua54 import LuaRuntime

lua = LuaRuntime()
lua.globals().source = (root / 'src').as_posix()
lua.execute("""
package.path=source..'/?.lua;'..package.path
local help=require('presentation.quick_help')
local found=0
for _,line in ipairs(help.lines) do
  if line:find('[F6]',1,true) then
    assert(line:find('影之刃武器',1,true) and line:find('完美格挡',1,true) and line:find('闪避',1,true))
    found=found+1
  end
end
local hint=help.new()
assert(found==1 and hint:update(0,true,1) and not hint:update(1,false,1))
assert(hint:update(100,true,2) and not hint:update(112,true,2))
assert(hint:toggle() and hint:update(113,true,2) and not hint:toggle())
local r=require('rules.auto_defense')
local s=r.new()
local function decide(hits,delta)
  r.begin(s,10,delta or 1/60)
  for _,h in ipairs(hits)do r.consider(s,table.unpack(h))end
  return r.choose(s)
end
assert(not decide({{1,9.90,false,false},{2,11,true,false},{3,10.01,true,true}}))
assert(decide({{1,9.99,false,false}}).action=='guard')
assert(decide({{1,10.05,false,false}}).action=='guard')
assert(decide({{1,10.05,true,false}}).action=='dodge')
local same={{3,10.035,false,false},{8,10.041,true,false},{2,10.035,false,false}}
for i=1,3 do
  assert(decide(same).handle==8)
  table.insert(same,table.remove(same,1))
end
assert(decide({{3,10.01,false,false},{8,10.05,true,false}}).handle==3)
assert(decide({{4,10.02,false,false},{2,10.02,false,false}}).handle==2)
r.dispatched(s,decide({{2,10.02,false,false}}))
assert(not decide({{2,10.02,false,false}}))
assert(decide({{2,10.03,false,false}}).handle==2)
r.begin(s,11,1/60)
r.choose(s)
assert(s.sent[2]==nil)
local pulse=-3.39999995214436e38
local bolt=decide({{5,pulse,false,false},{6,10.09,false,false}})
assert(bolt.handle==5 and bolt.time==10)
r.dispatched(s,bolt)
assert(not decide({{5,pulse,false,false}}))
assert(decide({{5,pulse,false,false},{6,pulse,true,false}}).action=='dodge')
assert(not decide({{6,pulse,true,true}}))
assert(decide({{5,pulse,false,false}}).action=='guard')

-- An ignored edge during a recovery can be retried once close to impact.
-- A frame consumed by the engine, a contact notification, or a stale hit
-- cannot produce a second press.
s=r.new()
local function pending(now,hit)
  r.begin(s,now,.012);r.consider(s,4,1.105,true,hit);return r.choose(s)
end
r.dispatched(s,pending(1))
assert(not pending(1.045) and not pending(1.080))
local late=pending(1.090);assert(late.action=='dodge');r.dispatched(s,late)
assert(not pending(1.102) and not pending(1.110))
s=r.new();r.dispatched(s,pending(1));assert(not pending(1.093,true))
local body={radius=34,half=90}
assert(r.in_sweep(80,5,5,0,59,0,body) and not r.in_sweep(-80,0,0,0,59,0,body))
assert(not r.in_sweep(145,0,0,0,59,0,body) and not r.in_sweep(75,65,0,0,59,0,body))
s=r.new();r.begin(s,2,.012)
r.consider(s,55,2.10,true,false,true);r.consider(s,56,2.08,false,false)
assert(r.choose(s).handle==56)
r.begin(s,2.03,.012);r.consider(s,55,2.10,true,false,true);r.dispatched(s,r.choose(s))
r.begin(s,2.045,.012);assert(not r.choose(s))
r.begin(s,2.060,.012);r.consider(s,55,2.10,true,false,true);assert(not r.choose(s))
local eta=r.projectile_eta(140,0,15,-1200,0,0,body,.12)
assert(eta>.081 and eta<.083)
assert(not r.projectile_eta(140,0,15,1200,0,0,body,.12)) -- moving away
assert(not r.projectile_eta(140,90,15,-1200,0,0,body,.12)) -- passes beside player
assert(not r.projectile_eta(140,0,145,-1200,0,0,body,.12)) -- overhead
assert(r.projectile_eta(0,0,150,0,0,-1100,body,.12)) -- descending into capsule
assert(not r.projectile_eta(40,0,0,0,0,0,body,.12))

-- The same production entry point accepts a contact-only projectile and a
-- timed boss swing. No foreign actors, pools or world searches are required.
local enabled_key=false
local valid=function()return true end
local pc={IsValid=valid,GetAddress=function()return 1 end}
local rows={}
local frames=setmetatable({ForEach=function(_,fn)for _,v in ipairs(rows)do
  fn({get=function()return v[1]end},{get=function()return {HitGameTime=v[2],IsDodge=v[3],IsHit=false}end})
end end},{__len=function()return #rows end})
local component={IsValid=valid,ReceiveFrames=frames}
local binding={actor={['Deflect Component']=component}}
local device={IsValid=valid}
local injects={};local function callable(fn)return setmetatable({IsValid=valid},{__call=function(_,...)return fn(...)end})end
function FName(v)return v end
function StaticFindObject(path)
  if path:find('WasInputKeyJustPressed')then return callable(function(_,key)assert(key.KeyName=='F6');return enabled_key end)end
  if path:find('InjectInputVectorForAction')then return callable(function(_,action)injects[#injects+1]=action.name end)end
  if path:find('SubsystemBlueprintLibrary')then return {IsValid=valid,GetLocalPlayerSubSystemFromPlayerController=function()return device end}end
  return {IsValid=valid,name=path:match('%.([^%.]+)$')}
end
local a=require('host.pbz.auto_defense');local notices=0
local function frame(now,focus,pbz,key)
  enabled_key=key;a.begin_frame();a.update(binding,pc,focus,pbz,now,function()notices=notices+1 end,function()end)
end
frame(1,true,true,false);frame(1.01,true,true,true);assert(notices==1)
rows={{40,pulse,false}};frame(1.02,true,false,false);assert(#injects==0)
frame(1.03,true,true,false);assert(table.concat(injects,',')=='IA_Stance,IA_Deflect')
frame(1.04,true,true,false);assert(#injects==2)
rows={{41,1.09,true}};frame(1.06,false,true,true);assert(#injects==2)
frame(1.07,true,true,false);assert(injects[3]=='IA_Dodge' and notices==1)
frame(1.08,true,true,true);assert(notices==2)
rows={{42,pulse,false}};frame(1.09,true,true,false);assert(#injects==3)
""")
print('PASS: timed and on-contact hits, group ordering, handle reuse, physical toggle and PBZ/focus gates')
