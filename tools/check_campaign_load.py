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
  binding={is_current=function()return true end,actor=actor}
end
local function status()
  return state.decode(assert(fs.read(dir..'campaign-inventory-status.json')))
end
local why='PBZMCJsonBridge: save-limit: expanded save JSON (UTF-16 code units)=8388609, limit=8388608'
local reads,anchor_reads=0,0
local backup
PBZMC_ReadCampaignLoadState=function()
  reads=reads+1;if why then return nil,why end;return summary,nil,backup
end
PBZMC_ReadCampaignState=function()anchor_reads=anchor_reads+1;return summary end
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
assert(campaign.bound() and s.campaign_id==id and s.checkpoint==checkpoint and reads==3)
assert(s.store.core.containers.player.hotbar['3'].count==11 and s.store.core.buildings.kept.x==3)
campaign.observe();assert(not status().error)
s.unpublished=true
PBZMC_PutCampaignCheckpoint=function()return nil,'checkpoint-not-written: save-limit: before write=8384513, limit=8384512' end
hooks[save][2](ref(binding.actor))
assert(anchor_reads==1,'savepoint unnecessarily serialized the native root twice')
assert(s.unpublished and s.checkpoint==checkpoint and status().operation=='savepoint-failed')
assert(logs[#logs]:find('MC 存档点未能确认保存',1,true) and logs[#logs]:find('8384512',1,true),logs[#logs])
-- A failed load after a successful bind must not reactivate the previous store.
why='PBZMCJsonBridge: duplicate decoded JSON object key';reload()
campaign.observe()
assert(not campaign.bound() and not status().formal_inventory_bound and not status().campaign_id)
local ok,reason=pcall(campaign.ensure,binding);assert(not ok and reason:find(why,1,true) and not reason:find('超过',1,true))
-- A first-use filesystem failure must not allocate another campaign and
-- orphan immutable files on every presentation/input frame.
why=nil;backup='{"PBZGameSystem":{}}';summary=json.encode({needs_registration=true,root_sha256=string.rep('0',64),root_bytes=#backup})
local fresh={is_current=function()return true end,actor=actor}
local ids,writes,native_writes=0,0,0
package.loaded['host.pbz.local_player']={controller=function()return {}end}
package.loaded['host.pbz.native_equipment']={new=function()return nil end}
PBZMC_NewCampaignId=function()ids=ids+1;return '374958ea-71ca-4c30-bb3e-4c0dbd237f7a'end
PBZMC_ReadOrdinaryJson=function()return '{"PBZGameSystem":{}}'end
PBZMC_CreateCampaignIdentity=function()native_writes=native_writes+1;error('must not publish failed storage')end
PBZMC_PutCampaignCheckpoint=function()native_writes=native_writes+1;error('must not publish failed storage')end
local write=fs.write
fs.write=function(path,value)
  writes=writes+1
  if path:find('.campaign-checkpoint-',1,true)then
    error('PBZMC-IO: write/open failed (path_chars=264, errno=2): No such file or directory; path='..path)
  end
  return write(path,value)
end
reload()
local ok,reason=pcall(campaign.ensure,fresh)
assert(not ok and reason:find('无法读写模组存档文件',1,true) and reason==campaign.failure(),tostring(reason))
assert(ids==1 and native_writes==0 and not campaign.bound(),('ids=%s native=%s bound=%s'):format(ids,native_writes,tostring(campaign.bound())))
local after_writes,after_reads=writes,reads
for i=1,60 do
  local good,again=pcall(campaign.ensure,fresh);assert(not good and again==reason)
end
assert(ids==1 and writes==after_writes and reads==after_reads and native_writes==0)
assert(status().operation=='load-rejected' and status().error==reason)
fs.write=write
-- Corrupt MC data recovers into one separate branch. Neither the old files
-- nor the host JSON are overwritten, and no whole-save backup is made.
local old_summary=json.encode({campaign_id=id,checkpoint=checkpoint,root_sha256=string.rep('0',64)})
summary=old_summary;backup=nil
local original=assert(fs.read(c:path(checkpoint),false))
fs.write(c:path(checkpoint),original..'broken')
ids=0;PBZMC_NewCampaignId=function()ids=ids+1;return '92669c42-c7cc-4d92-87b1-96442988de14'end
local disk_reads,disk_writes=0,0
local read=fs.read
fs.read=function(...)disk_reads=disk_reads+1;return read(...)end
fs.write=function(...)disk_writes=disk_writes+1;return write(...)end
reload();local fresh=campaign.ensure(binding)
assert(ids==1 and native_writes==0 and summary==old_summary and campaign.bound())
assert(fresh.campaign.player_id~='local-primary' and fresh.recovery.automatic_reset and campaign.notice())
assert(fresh.store.core.containers.player.hotbar['3'].count==1 and next(fresh.store.core.buildings)==nil)
assert(fs.read(c:path(checkpoint),false)==original..'broken','old data changed')
local n,w,r=disk_reads,disk_writes,reads
for i=1,1000 do assert(campaign.ensure(binding)==fresh)end
assert(disk_reads==n and disk_writes==w and reads==r,'steady gameplay touched disk/root')
-- Reloading the same bad anchor reuses the same recovery. No backup growth.
reload();local again=campaign.ensure(binding)
assert(ids==1 and again.campaign.player_id==fresh.campaign.player_id and disk_writes==w)
local expected=again.recovery.checkpoint
-- First native savepoint publishes only the MC checkpoint; its immutable
-- route must already exist. A subsequent load restores exactly that state.
local t=again.store:checkout({});t.data.containers.player.hotbar['3'].count=2
assert(again.store:commit(t,t.data))
PBZMC_PutCampaignCheckpoint=function(_,before,which,digest)
  native_writes=native_writes+1;assert(which==id and before==string.rep('0',64))
  local rc,rl=require('storage.campaign_recovery').load(dir,id,digest)
  assert(rc and rl and rl.profiles.free.core.containers.player.hotbar['3'].count==2)
  expected=digest;summary=json.encode({campaign_id=id,checkpoint=digest,root_sha256=string.rep('1',64)})
  return json.encode({campaign_id=id,checkpoint=digest,before_sha256=before,after_sha256=string.rep('1',64)})
end
local before_reads=anchor_reads
hooks[save][2](ref(binding.actor))
assert(native_writes==1 and anchor_reads==before_reads+1 and again.checkpoint==expected and not again.store.dirty)
reload();local saved=campaign.ensure(binding)
assert(saved.checkpoint==expected and saved.store.core.containers.player.hotbar['3'].count==2 and ids==1)
-- Restoring a valid original exact checkpoint remains possible; no latest
-- recovery head may supersede it or copy its new inventory onto an old save.
write(c:path(checkpoint),original);summary=old_summary;reload()
local restored=campaign.ensure(binding)
assert(restored.campaign.player_id=='local-primary' and restored.store.core.containers.player.hotbar['3'].count==11)
assert(restored.store.core.buildings.kept and ids==1)
-- A failed migration cannot expose a partially initialized active session.
local unlock=require('rules.shield_unlock');local apply=unlock.apply
local prior=restored.store.core;prior.shield_unlocked=nil
local another={is_current=function()return true end,actor=actor}
unlock.apply=function()error('injected-migration-failure')end
local ok,err=pcall(campaign.ensure,another)
assert(not ok and err:find('injected-migration-failure',1,true) and not campaign.bound())
local before_reads=reads
for i=1,100 do assert(not pcall(campaign.ensure,another))end
assert(reads==before_reads and ids==1)
unlock.apply=apply
fs.read=read;fs.write=write
''')
print("PASS: deferred native read, explicit failures, MC-only recovery/reuse/exact savepoint/reload, unchanged old files, no frame IO, one native summary per savepoint, atomic bind")
