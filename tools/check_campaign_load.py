"""Exercise the production LoadGame/PreSaveGame Lua callbacks against an isolated player store."""
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "build/lua-check"))
from lupa.lua54 import LuaRuntime

with tempfile.TemporaryDirectory() as tmp:
    (Path(tmp) / "pbzmc-data/player-store").mkdir(parents=True)
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.globals().src = ROOT.as_posix()
    lua.globals().tmp = Path(tmp).as_posix()
    lua.execute(r'''
package.path=src..'/src/?.lua;'..src..'/third_party/dkjson/?.lua;'..package.path
local json=require('dkjson')
local state=require('storage.state')
local fs=require('storage.file_io')
local dir=tmp..'/pbzmc-data/'
local id='592f4a22-7fe0-412b-ae11-e87fbba5a832'
local defs=require('content.items')
local c=require('storage.campaign_store').open(dir..'player-store',id,'local-primary',defs)
local store=require('storage.player_store').open(c.directory,c:scope('free'),defs)
assert(store:load())
local t=store:checkout({})
local data=require('rules.starter_loadout').create(t.data,id)
data.containers.player.hotbar['3'].count=11
data.buildings.kept={id='kept',content_id='pbzmc:dirt',world='TestWorld',x=3,y=0,z=0,yaw=0}
assert(store:commit(t,data))
local checkpoint=assert(c:create({free=store}))
local summary=json.encode({campaign_id=id,checkpoint=checkpoint,root_sha256=string.rep('0',64)})
local function obj(name)
  return {IsValid=function() return true end,GetAddress=function() return name end,GetFullName=function() return name end}
end
local gi,sub,world=obj('GI'),obj('PBZSaveLoadSubsystem /Engine/Transient.Test'),obj('TestWorld')
sub.GetOuter=function() return gi end
local actor=obj('TestPlayer');actor.GetWorld=function()return world end
local binding={is_current=function()return true end,actor=actor}
package.loaded.UEHelpers={GetGameInstance=function()return gi end}
package.loaded['host.pbz.player_status_service']={new=function()end}
package.loaded['host.pbz.tnt_damage']={ready=function()return false end}
IsInGameThread=function()return true end
FindAllOf=function()return {sub} end
local load='/Script/ProjectPBZ.PBZGameInstance:LoadGame'
local save='/Script/ProjectPBZ.PBZGameSystem:PreSaveGame'
local fields={[load]={{'StrProperty','SlotName',0},{'StructProperty','LoadGameResultParam',16}},
              [save]={{'StructProperty','SaveGameParam',0}}}
StaticFindObject=function(path)
  local f=obj(path);f.GetFunctionFlags=function()return path==load and 0x04420401 or 0x20401 end
  f.ForEachProperty=function(_,visit)
    for _,p in ipairs(assert(fields[path])) do
      local prop=obj(p[1]..' '..path..':'..p[2])
      prop.GetOffset_Internal=function()return p[3] end
      prop.GetStruct=function()return obj('ScriptStruct /Script/ProjectPBZ.'..p[2]) end
      visit(prop)
    end
  end
  return f
end
local hooks={}
RegisterHook=function(path,pre,post) hooks[path]={pre,post};return 1,2 end
local result=obj('ScriptStruct /Script/ProjectPBZ.LoadGameResultParam')
result.IsMappedToObject=function()return true end;result.ResultType=0
local function ref(v)return {get=function()return v end} end
local function reload()
  hooks[load][1](ref(gi));hooks[load][2](ref(gi),nil,ref(result))
end
local function status()
  return state.decode(assert(fs.read(dir..'campaign-inventory-status.json')))
end
local why='PBZMCJsonBridge: save-limit: expanded save JSON (UTF-16 code units)=8388609, limit=8388608'
local reads=0
PBZMC_ReadCampaignLoadState=function()
  reads=reads+1;if why then return nil,why end;return summary
end
PBZMC_ReadCampaignState=function()return summary end
PBZMC_ReadOrdinaryJson=function()error('registered campaign unexpectedly requested the full root')end
PBZMC_NewCampaignId=function()error('unexpected registration')end
local campaign=require('host.pbz.campaign_inventory')
local logs={};campaign.start(function(msg)logs[#logs+1]=msg end,tmp)
-- Direct late binding and the native load hook must both retain the same
-- actionable reason; frame retries must not read the root again.
for _,via_hook in ipairs({false,true}) do
  if via_hook then reload() end
  local ok,reason=pcall(campaign.ensure,binding)
  assert(not ok and reason:find('MC 读档失败',1,true) and reason:find(why,1,true))
  local n=reads
  for i=1,20 do local good,again=pcall(campaign.ensure,binding);assert(not good and again==reason) end
  assert(reads==n and n==(via_hook and 2 or 1))
  local report=status()
  assert(report.operation=='load-rejected' and report.error==reason and report.frozen and not report.formal_inventory_bound)
end
assert(#logs==2)
why=nil;reload()
local s=campaign.ensure(binding)
assert(campaign.bound() and s.campaign_id==id and s.checkpoint==checkpoint and reads==4)
assert(s.store.core.containers.player.hotbar['3'].count==11 and s.store.core.buildings.kept.x==3)
campaign.observe();assert(not status().error)
s.unpublished=true
PBZMC_PutCampaignCheckpoint=function()return nil,'checkpoint-not-written: save-limit: before write=8384513, limit=8384512' end
hooks[save][2](ref(binding.actor))
assert(s.unpublished and s.checkpoint==checkpoint and status().operation=='savepoint-failed')
assert(logs[#logs]:find('MC 存档点未能确认保存',1,true) and logs[#logs]:find('8384512',1,true),logs[#logs])
-- A failed load after a successful bind must not reactivate the previous store.
why='PBZMCJsonBridge: duplicate decoded JSON object key';reload()
assert(not campaign.bound() and not status().formal_inventory_bound and not status().campaign_id)
local ok,reason=pcall(campaign.ensure,binding);assert(not ok and reason:find(why,1,true) and not reason:find('超过',1,true))
''')
print("PASS: load-hook and direct-bind diagnostics, bounded retries, retained inventory/building, savepoint refusal, reload")
