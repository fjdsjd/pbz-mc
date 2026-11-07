-- First use creates a new scope with the released starter loadout. Large
-- native JSON stays opaque in Lua; verified bridge receipts fence all writes.
local M={}
local state=require('storage.state')
local fs=require('storage.file_io')
local encode=require('storage.canonical_json')
local Campaign=require('storage.campaign_store')
local Store=require('storage.player_store')
local definitions=require('content.items')
function M.create_profiles(base,id,player_id,starter_snapshot)
  local c=Campaign.open(base..'player-store',id,player_id,definitions)
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
  return c,{profiles=profiles,digest=digest}
end
local function proof(raw,id,before)
  local v=state.decode(assert(raw,'registration-proof-required'))
  assert(v.campaign_id==id and v.before_sha256==before and type(v.after_sha256)=='string'
    and #v.after_sha256==64,'registration-write-proof-mismatch')
  return v
end
function M.ensure(base,path,current,starter_snapshot,backup)
  assert(IsInGameThread(),'registration-game-thread-required')
  assert(type(current)=='table' and current.needs_registration==true and type(current.root_sha256)=='string'
    and #current.root_sha256==64,'registration-verified-summary-required')
  local id=current.campaign_id
  local expected=current.root_sha256
  local receipt
  if id then
    assert(type(id)=='string' and id:match('^[0-9a-f%-]+$') and #id==36,'registration-identity-format')
    receipt=state.decode(assert(fs.read(base..'campaign-bootstrap-'..id..'.json'),'existing-campaign-anchor-missing'))
    assert(receipt.campaign_id==id and receipt.schema==1,'registration-recovery-scope')
    local c=Campaign.open(base..'player-store',id,'local-primary',definitions)
    local loaded,why=c:load(receipt.checkpoint);assert(loaded,why)
  else
    assert(type(backup)=='string' and #backup==current.root_bytes,'registration-opaque-backup-required')
    local why;id,why=PBZMC_NewCampaignId();assert(id,why)
    local _,created=M.create_profiles(base,id,'local-primary',starter_snapshot)
    receipt={schema=1,campaign_id=id,checkpoint=created.digest,before_sha256=expected}
    -- A local recovery record precedes native writes; no existing profile or
    -- native slot is overwritten to manufacture an empty replacement.
    fs.write(base..'campaign-bootstrap-'..id..'-native-before.json',backup)
    local pending=encode(receipt);fs.write(base..'campaign-bootstrap-'..id..'.json',pending)
    assert(fs.read(base..'campaign-bootstrap-'..id..'.json')==pending,'registration-recovery-readback')
    local result,why=PBZMC_CreateCampaignIdentity(path,expected,id);assert(result,why)
    expected=proof(result,id,expected).after_sha256
  end
  local published,why=PBZMC_PutCampaignCheckpoint(path,expected,id,receipt.checkpoint);assert(published,why)
  assert(proof(published,id,expected).checkpoint==receipt.checkpoint,'registration-anchor-readback')
  return receipt
end
return M
