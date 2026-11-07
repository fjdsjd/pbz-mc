"""Check the turtle shell at the waterline, the last protected tick and save/load."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / "build/lua-check"))
from lupa.lua54 import LuaRuntime

lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute("local r=...;package.path=r..'/src/?.lua;'..r..'/third_party/dkjson/?.lua;'..package.path", root.as_posix())
lua.execute("""
local r=require('rules.status_effects')
local j=require('dkjson')
local hud=require('presentation.status_hud')
local s=r.empty()
local function advance(ticks,wet,helmet,creative)
 local hits=0
 while ticks>0 do
  local n=math.min(ticks,100)
  local next,_,drown=r.advance(s,n,1000,wet,helmet,creative)
  r.validate(next);s=next;hits=hits+drown;ticks=ticks-n
 end
 return hits
end
assert(not r.needs_tick(s,false,false,false))
assert(r.needs_tick(s,false,true,false))
advance(1,false,true);assert(s.effects.water_breathing.ticks==200)
assert(not r.needs_tick(s,false,true,false) and not r.has_particles(s))
assert(#r.list(s)==1 and #r.list(s,true)==0)
advance(199,true,true);assert(s.effects.water_breathing.ticks==1 and s.air==nil)
advance(1,true,true);assert(not s.effects.water_breathing and s.air==nil)
advance(1,true,true);assert(s.air==299)
s=assert(j.decode(j.encode(s)));r.validate(s)
assert(advance(318,true,true)==0 and s.air==-19)
assert(advance(1,true,true)==1 and s.air==0)
assert(advance(40,true,true)==2 and s.air==0)
advance(1,false,true);assert(s.air==4 and s.effects.water_breathing.ticks==200)
advance(100,true,false);assert(s.air==4 and s.effects.water_breathing.ticks==100)
advance(100,true,true);assert(s.air==4 and not s.effects.water_breathing)
advance(1,false,true);assert(s.air==8 and s.effects.water_breathing.ticks==200)
advance(73,false,false);assert(s.air==nil and s.effects.water_breathing.ticks==127)
advance(127,false,false);assert(not s.effects.water_breathing)
assert(advance(600,true,false,true)==0 and s.air==nil)
assert(advance(320,true,false,false)==1)
assert(not pcall(r.validate,{schema=1,effects={},air=-20,serial=0,absorption=0,totem_cooldown=0}))
local assets={player_status={air='bubble',air_bursting='popping',effect_background='frame'},
 status_effects={water_breathing='breath'},stamina_bar={background='track',progress='bar'}}
local function counts(value,wet,inventory,stamina)
 local out={}
 for _,c in ipairs(hud.draw(value,assets,{scale=2},{width=1600,height=900},inventory,nil,stamina,nil,0,nil,0,wet)) do
  out[c.texture]=(out[c.texture] or 0)+1
 end
 return out
end
s=r.empty();advance(1,false,true)
local a=counts(s,true,false,1);assert(a.breath==1 and a.frame==1 and a.bubble==10)
s.air=271;a=counts(s,true,false,1);assert(a.bubble==9 and a.popping==1)
a=counts(s,true,false,nil);assert(a.breath==1 and not a.bubble)
a=counts(s,true,true,nil);assert(not a.breath and not a.bubble)
s=r.apple(s,'pbzmc:golden_apple',1000);assert(r.has_particles(s) and #r.list(s,true)==2)
""")
print("PASS: helmet refresh, underwater equipment swaps, partial and empty air, repeated drowning, creative, particles, save round-trip and oxygen HUD.")
