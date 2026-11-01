-- First use creates a new scope and empty formal profiles. Existing anchors
-- always load their exact immutable closure; they never use this initializer.
local M={}
local state=require('storage.state')
local fs=require('storage.file_io')
local encode=require('storage.canonical_json')
local sha=require('storage.sha256')
local Campaign=require('storage.campaign_store')
local Store=require('storage.player_store')
local definitions=require('content.items')
local function section(root,key)
  local found
  for k,v in pairs(root) do
    if k:lower()==key:lower() then assert(not found,'ambiguous-registration-section');found=v end
  end
  return found
end
function M.ensure(base,path,raw,starter_snapshot)
  assert(IsInGameThread(),'registration-game-thread-required')
  local root=state.decode(raw)
  assert(type(root.PBZGameSystem)=='table','registration-gameplay-root-required')
  local marker,anchor=section(root,'PBZMC_CampaignIdentity'),section(root,'PBZMC_Checkpoint')
  if anchor then assert(marker,'registration-orphan-anchor');return raw end
  local id=marker and marker.campaign_id
  local receipt
  if marker then
    assert(type(id)=='string' and id:match('^[0-9a-f%-]+$') and #id==36,'registration-identity-format')
    assert(encode(marker)==encode({owner='pbzmc',schema='campaign-identity-v1',campaign_id=id}),'registration-identity-format')
    receipt=state.decode(assert(fs.read(base..'campaign-bootstrap-'..id..'.json'),'existing-campaign-anchor-missing'))
    assert(receipt.campaign_id==id and receipt.schema==1,'registration-recovery-scope')
  else
    local why;id,why=PBZMC_NewCampaignId();assert(id,why)
    local c=Campaign.open(base..'player-store',id,'local-primary',definitions)
    local profiles=state.object()
    for _,mode in ipairs({'free','adventure'}) do
      local s=Store.open(c.directory,c:scope(mode),definitions)
      local core,warning=s:load();assert(core and not warning and s.generation==0 and not s.history_retained,
        'registration-new-profile-required')
      local ticket=s:checkout()
      local starter=require('rules.starter_loadout').create(ticket.data,id,starter_snapshot)
      local ok,err=s:commit(ticket,starter);assert(ok and not err,err)
      profiles[mode]=s
    end
    local digest,err=c:create(profiles);assert(digest,err)
    receipt={schema=1,campaign_id=id,checkpoint=digest,before_sha256=sha(raw)}
    -- A local recovery record precedes native writes; no existing profile or
    -- native slot is overwritten to manufacture an empty replacement.
    fs.write(base..'campaign-bootstrap-'..id..'-native-before.json',raw)
    local pending=encode(receipt);fs.write(base..'campaign-bootstrap-'..id..'.json',pending)
    assert(fs.read(base..'campaign-bootstrap-'..id..'.json')==pending,'registration-recovery-readback')
    local created,why=PBZMC_CreateCampaignIdentity(path,sha(raw),id);assert(created,why)
  end
  local c=Campaign.open(base..'player-store',id,'local-primary',definitions)
  local loaded,why=c:load(receipt.checkpoint);assert(loaded,why)
  local current,err=PBZMC_ReadOrdinaryJson(path);assert(current,err)
  local now=state.decode(current);local identity=section(now,'PBZMC_CampaignIdentity')
  assert(identity and identity.campaign_id==id and not section(now,'PBZMC_Checkpoint'),'registration-native-scope-changed')
  local published,why=PBZMC_PutCampaignCheckpoint(path,sha(current),id,receipt.checkpoint);assert(published,why)
  local after,err=PBZMC_ReadOrdinaryJson(path);assert(after,err)
  assert(section(state.decode(after),'PBZMC_Checkpoint').checkpoint==receipt.checkpoint,'registration-anchor-readback')
  return after
end
return M
