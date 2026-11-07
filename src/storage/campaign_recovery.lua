-- MC-only recovery branches. The failed files remain untouched in place.
-- A small immutable route maps one exact native checkpoint to one replacement
-- MC checkpoint. Never use a latest head, scan directories or copy PBZ saves.
local M={}
local Campaign=require('storage.campaign_store')
local state=require('storage.state')
local encode=require('storage.canonical_json')
local sha=require('storage.sha256')
local fs=require('storage.file_io')
local definitions=require('content.items')
local function path(base,id,checkpoint)
  local canonical=Campaign.open(base..'player-store',id,'local-primary',definitions)
  assert(type(checkpoint)=='string' and #checkpoint==64 and checkpoint:match('^[0-9a-f]+$'),'recovery-source-checkpoint')
  return canonical.prefix..checkpoint..'.recovery.json'
end
local function decode(raw,id,source)
  local envelope=state.decode(raw)
  assert(type(envelope.payload)=='string' and sha(envelope.payload)==envelope.sha256,'recovery-route-checksum')
  local v=state.decode(envelope.payload)
  assert(v.schema==1 and v.campaign_id==id and v.source_checkpoint==source and type(v.player_id)=='string'
    and v.player_id:match('^local%-primary%-recovery%-[0-9a-f%-]+$') and type(v.checkpoint)=='string'
    and #v.checkpoint==64 and v.checkpoint:match('^[0-9a-f]+$'),'recovery-route-scope')
  return v
end
local function write(base,record)
  local filename=path(base,record.campaign_id,record.source_checkpoint)
  local payload=encode(record);local raw=encode({payload=payload,sha256=sha(payload)})
  assert(#raw<=8192,'recovery-route-size')
  local existing=fs.read(filename,8192)
  if existing then
    local v=decode(existing,record.campaign_id,record.source_checkpoint)
    assert(v.player_id==record.player_id and v.checkpoint==record.checkpoint,'recovery-route-conflict')
    return
  end
  fs.write(filename..'.tmp',raw)
  assert(fs.read(filename..'.tmp',8192)==raw,'recovery-route-readback')
  fs.rename(filename..'.tmp',filename)
  assert(fs.read(filename,8192)==raw,'recovery-route-unavailable')
end
function M.load(base,id,source)
  local raw=fs.read(path(base,id,source),8192)
  if not raw then return nil end
  local v=decode(raw,id,source)
  local c=Campaign.open(base..'player-store',id,v.player_id,definitions)
  local loaded,why=c:load(v.checkpoint);assert(loaded,why)
  return c,loaded,v
end
function M.create(base,id,source,why,starter)
  -- Failed recovery itself is not grounds for generating more branches on
  -- every frame/relaunch. The caller latches that error until a new load.
  local c,loaded,v=M.load(base,id,source)
  if c then return c,loaded,v end
  assert(not fs.is_error(why) and not tostring(why):find('external-player-save-change',1,true),why)
  local uuid,err=PBZMC_NewCampaignId();assert(uuid,err)
  local player_id='local-primary-recovery-'..uuid
  c,loaded=require('host.pbz.campaign_registration').create_profiles(base,id,player_id,starter)
  v={schema=1,campaign_id=id,source_checkpoint=source,player_id=player_id,checkpoint=loaded.digest,
    reason=tostring(why):sub(1,2048),automatic_reset=true,old_files_retained=true,pbz_save_unchanged=true}
  write(base,v)
  return c,loaded,v
end
function M.before_publish(base,c,checkpoint)
  if c.player_id=='local-primary' then return end
  -- Route is durable before the native savepoint can reference this digest.
  -- A failed native save leaves only a small harmless immutable record.
  write(base,{schema=1,campaign_id=c.campaign_id,source_checkpoint=checkpoint,player_id=c.player_id,
    checkpoint=checkpoint,automatic_reset=false,old_files_retained=true,pbz_save_unchanged=true})
end
return M
