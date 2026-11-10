"""Regress the dragon-pillar hit route without a running PBZ client."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'build/lua-check'))
from lupa.lua54 import LuaRuntime

lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute("local root=...;package.path=root..'/src/?.lua;'..package.path", root.as_posix())
lua.execute(r'''
package.loaded['host.pbz.appearance']={valid=function(v)return v~=nil and v~=false end}
FName=function(tag)return tag end
local guard=require('host.pbz.weapon_guard')
local folder='/PBZCombatAsset/ActorData/Mobs/067_MoTian/'
local function class(name,parent)
  return {GetFullName=function()return 'BlueprintGeneratedClass '..folder..name..'.'..name..'_C' end,
    GetSuperStruct=function()return parent end}
end
local base=class('BP_Monster_MoTian')
local first=class('BP_Monster_MoTian_LongZhu_01',base)
local subclass=class('Child',first)
local function attribute(n)return {CurrentValue=n} end
local attrs={Shachi=attribute(1200),Shachi_Max=attribute(1200),Shachi_Min=attribute(0),Health_Max=attribute(8000)}
local source={AttributeSetBase={ShachiAttack=attribute(100)}}
local broken=false
local state={InExactState=function(_,tag)assert(tag.TagName=='CharacterState.Stand.Break');return broken end}
local boss={GetClass=function()return subclass end,AttributeSetBase=attrs,['Death Component']={['Actor State Component']=state}}
local cache={}
local function prepare(target,amount)
  local req={phase='damage',coefficient=amount/100}
  local before=guard.prepare(cache,target,source,req,amount)
  return req,before
end
local req,before=prepare(boss,640)
assert(before==1200 and req.phase=='shachi' and math.abs(req.coefficient-.96)<1e-8)
source.AttributeSetBase.ShachiAttack.CurrentValue=200
assert(math.abs(prepare(boss,960).coefficient-.72)<1e-8)
attrs.Shachi.CurrentValue=.00001
req,before=prepare(boss,640)
assert(req.phase=='shachi' and req.coefficient>.4)
attrs.Shachi.CurrentValue=0
local report={dispatched=true,blocked=false}
guard.observe(report,before,boss)
assert(report.native_shachi_hit and report.native_shachi_after==0)
assert(prepare(boss,640).phase=='damage')
attrs.Shachi.CurrentValue=50;broken=true
assert(prepare(boss,640).phase=='damage')
broken=false;assert(prepare(boss,640).phase=='shachi')
for _,cls in ipairs({base,class('BP_Monster_MoTian_LongZhu_04',base),class('BP_Monster_GoldMaskMan')})do
  local ordinary={GetClass=function()return cls end}
  req,before=prepare(ordinary,640);assert(req.phase=='damage' and before==nil and req.coefficient==6.4)
end
report={dispatched=false};guard.observe(report,100,boss);assert(not report.native_shachi_hit)
report={dispatched=true,blocked=true};guard.observe(report,100,boss);assert(not report.native_shachi_hit)
''')
print('PASS: native Shachi coefficient, break boundary, refill, receipts and encounter isolation')
