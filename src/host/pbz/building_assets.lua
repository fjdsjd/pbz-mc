-- Verified original full-cube resources. Only manifests are shared globally;
-- the owning world bounds decoded crack geometry and surface caches.
local json=require('dkjson')
local sha=require('storage.sha256')
local bundle=require('host.pbz.mesh_bundle')
local M={};M.__index=M
local catalogs={}
local function read(path,limit)
  local f=assert(io.open(path,'rb'));local size=f:seek('end');f:seek('set',0)
  if not size or size>limit then f:close();error('building-asset-size') end
  local raw=f:read('a');f:close();return assert(raw)
end
function M.open(root)
  if catalogs[root] then return catalogs[root] end
  local raw=read(root..'/manifest.json',2*1024*1024)
  local manifest,pos,err=json.decode(raw)
  assert(manifest and not err and raw:sub(pos):match('^%s*$'),'building-manifest-json')
  assert(manifest.schema==1 and manifest.format=='STEVEM01' and manifest.private_local_assets==true,'building-manifest-schema')
  local self=setmetatable({root=root,manifest=manifest,base_keys={},report={reads=0,bytes=0,decodes=0,max_ms=0}},M)
  for key,entry in pairs(manifest.models) do
    assert(type(key)=='string' and key:match('^building%-blocks/[a-z0-9_]+$'),'building-model-key')
    assert(type(entry.path)=='string' and entry.path:match('^[a-z0-9_/-]+%.mesh$') and not entry.path:find('..',1,true),'building-model-path')
    assert(type(entry.bytes)=='number' and entry.bytes>0 and entry.bytes<=8*1024*1024,'building-model-bytes')
    assert(type(entry.sha256)=='string' and #entry.sha256==64 and entry.sha256:match('^[0-9a-f]+$'),'building-model-sha256')
    if not key:match('_crack_%d$') then self.base_keys[#self.base_keys+1]=key end
  end
  table.sort(self.base_keys);catalogs[root]=self;return self
end
function M:model(record)
  local entry=assert(self.manifest.items[record.content_id],'building-item-model-unavailable')
  local axis=record.properties and record.properties.axis
  if axis then return assert(entry.variants[axis],'building-axis-model-unavailable') end
  return entry.default_model
end
function M:part(key)
  local began=os.clock();local entry=assert(self.manifest.models[key],'unlisted-building-model:'..key)
  self.raw_cache=self.raw_cache or {};self.raw_order=self.raw_order or {};self.raw_bytes=self.raw_bytes or 0
  local raw=self.raw_cache[key];local read_ms,hash_ms=0,0
  local report=self.report
  if not raw then
    raw=read(self.root..'/'..entry.path,8*1024*1024);read_ms=(os.clock()-began)*1000
    local hash_start=os.clock()
    assert(#raw==entry.bytes and sha(raw)==entry.sha256,'building-model-digest:'..key)
    hash_ms=(os.clock()-hash_start)*1000
    -- Compact verified bytes survive decoded-mesh eviction. Repeated mining
    -- of a material never repeats disk access or SHA work; storage is bounded.
    self.raw_cache[key]=raw;self.raw_order[#self.raw_order+1]=key;self.raw_bytes=self.raw_bytes+#raw
    while self.raw_bytes>32*1024*1024 and #self.raw_order>1 do
      local old=table.remove(self.raw_order,1);self.raw_bytes=self.raw_bytes-#self.raw_cache[old];self.raw_cache[old]=nil
    end
    report.reads=report.reads+1;report.bytes=report.bytes+#raw
  end
  local decode_start=os.clock()
  local parts=bundle.decode(raw,6.25);assert(#parts==1,'building-model-parts')
  local part=parts[1]
  assert(part.pivot.X==0 and part.pivot.Y==0 and part.pivot.Z==0,'building-model-pivot')
  for _,uv in ipairs(part.uv) do uv.X=433.5/512;uv.Y=139.5/256 end
  report.decodes=report.decodes+1;report.raw_cache_bytes=self.raw_bytes
  report.last_read_ms=read_ms;report.last_hash_ms=hash_ms;report.last_decode_ms=(os.clock()-decode_start)*1000
  report.max_decode_ms=math.max(report.max_decode_ms or 0,report.last_decode_ms)
  report.max_hash_ms=math.max(report.max_hash_ms or 0,hash_ms)
  report.last_ms=(os.clock()-began)*1000;report.max_ms=math.max(report.max_ms,report.last_ms)
  return part
end
return M
