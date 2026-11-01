-- One immutable manifest joins the independently scoped player modes. The
-- native save contains only this manifest's SHA256, never a latest-head hint.
-- File publication does not itself publish an anchor or claim a host save.
local state=require('storage.state')
local Store=require('storage.player_store')
local encode=require('storage.canonical_json')
local sha=require('storage.sha256')
local json=require('dkjson')
local M={};M.__index=M
local function object(v)
  return type(v)=='table' and v~=json.null and state.json_kind(v)=='object'
end
local function hash(v) return type(v)=='string' and #v==64 and v:match('^[0-9a-f]+$') end
local function uuid(v)
  return type(v)=='string' and v:match('^[0-9a-f]+%-[0-9a-f]+%-4[0-9a-f]+%-[89ab][0-9a-f]+%-[0-9a-f]+$')
    and #v==36 and v:sub(9,9)=='-' and v:sub(14,14)=='-' and v:sub(19,19)=='-' and v:sub(24,24)=='-'
end
local function modes(profiles)
  assert(object(profiles),'invalid-campaign-profiles')
  local names={}
  for mode in pairs(profiles) do
    assert(mode=='free' or mode=='adventure','unsupported-campaign-profile-mode')
    names[#names+1]=mode
  end
  assert(#names>0,'empty-campaign-profiles');table.sort(names);return names
end
function M.open(directory,campaign_id,player_id,definitions,filesystem)
  assert(uuid(campaign_id),'invalid-campaign-uuid')
  assert(type(player_id)=='string' and #player_id>0 and #player_id<=128 and not player_id:find('\0',1,true),
    'invalid-campaign-player-id')
  return setmetatable({directory=directory,campaign_id=campaign_id,player_id=player_id,
    definitions=definitions,io=filesystem or require('storage.file_io'),
    prefix=directory..'/'..sha(campaign_id..'\0'..player_id)..'.campaign-checkpoint-'},M)
end
function M:path(digest) assert(hash(digest),'invalid-campaign-checkpoint-digest');return self.prefix..digest..'.json' end
function M:scope(mode) return {campaign_id=self.campaign_id,player_id=self.player_id,mode=mode} end
function M:validate(manifest)
  assert(object(manifest) and manifest.format=='pbzmc-campaign-checkpoint' and manifest.version==1,
    'unsupported-campaign-checkpoint')
  assert(manifest.campaign_id==self.campaign_id and manifest.player_id==self.player_id,'campaign-checkpoint-scope-mismatch')
  local count=0;for _ in pairs(manifest) do count=count+1 end
  assert(count==5,'unexpected-campaign-checkpoint-fields')
  for _,mode in ipairs(modes(manifest.profiles)) do
    assert(hash(manifest.profiles[mode]),'invalid-campaign-profile-digest')
  end
  return manifest
end
function M:load(digest)
  local ok,result=pcall(function()
    local raw=assert(self.io.read(self:path(digest),false),'missing-campaign-checkpoint')
    assert(sha(raw)==digest,'campaign-checkpoint-checksum-mismatch')
    local manifest=self:validate(state.decode(raw));local profiles={}
    for _,mode in ipairs(modes(manifest.profiles)) do
      local store=Store.open(self.directory,self:scope(mode),self.definitions,self.io)
      local core,warning=store:load_checkpoint(manifest.profiles[mode])
      assert(core and not warning and not store.read_only,warning or 'campaign-profile-unavailable')
      profiles[mode]=store
    end
    -- No profile is exposed on a partial failure. No call to Store:load(),
    -- no empty replacement and no native write occurs along this path.
    return {digest=digest,manifest=manifest,profiles=profiles}
  end)
  if not ok then return nil,tostring(result) end
  return result
end
function M:create(profiles)
  local ok,result=pcall(function()
    local names=modes(profiles)
    local manifest={format='pbzmc-campaign-checkpoint',version=1,campaign_id=self.campaign_id,
      player_id=self.player_id,profiles=state.object()}
    local generations={}
    for _,mode in ipairs(names) do
      local store=profiles[mode]
      assert(type(store)=='table' and encode(store.scope)==encode(self:scope(mode)), 'campaign-profile-scope-mismatch')
      assert(store.prefix==Store.open(self.directory,self:scope(mode),self.definitions,self.io).prefix
        and store.io==self.io and store.definitions==self.definitions,'campaign-profile-backend-mismatch')
      generations[mode]=store.generation
      local digest,why=store:create_checkpoint();assert(digest,why)
      manifest.profiles[mode]=digest
    end
    self:validate(manifest)
    local function current()
      for _,mode in ipairs(names) do
        local store=profiles[mode]
        assert(store.generation==generations[mode] and not store.read_only,'campaign-profile-changed-during-publication')
        store:check_heads()
      end
    end
    current()
    local raw=encode(manifest);local digest=sha(raw);local path=self:path(digest)
    local existing=self.io.read(path,false)
    if existing then assert(existing==raw,'existing-campaign-checkpoint-mismatch')
    else
      self.io.write(path..'.tmp',raw)
      assert(self.io.read(path..'.tmp',false)==raw,'campaign-checkpoint-readback-mismatch')
      current();self.io.rename(path..'.tmp',path)
    end
    assert(self.io.read(path,false)==raw,'campaign-checkpoint-readback-unavailable')
    -- Each create_checkpoint already validated its complete immutable closure.
    -- The exact manifest readback above plus the final generation/head fences
    -- preserve those proofs; constructing new Stores just repeats all that IO.
    current()
    return digest
  end)
  -- Failure may leave pinned immutable files, but never a returned digest that
  -- has not been verified. The caller must not mutate the native anchor on nil.
  if not ok then return nil,tostring(result) end
  return result
end
return M
