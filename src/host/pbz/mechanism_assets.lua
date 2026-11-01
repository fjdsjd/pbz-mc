-- Original multi-element MC blockstates, resolved once per changed state.
local json=require('dkjson')
local sha=require('storage.sha256')
local bundle=require('host.pbz.mesh_bundle')
local M={};M.__index=M
local catalogs={}
local function read(path,limit)
  local f=assert(io.open(path,'rb'));local n=f:seek('end');f:seek('set',0)
  assert(n and n<=limit,'mechanism-resource-size');local raw=f:read('a');f:close();return raw
end
function M.open(root)
  if catalogs[root]then return catalogs[root]end
  local manifest=assert(json.decode(read(root..'/manifest.json',6*1024*1024)))
  assert(manifest.schema==1 and manifest.format=='STEVEM01' and manifest.private_local_assets,'mechanism-manifest')
  local self=setmetatable({root=root,manifest=manifest,keys={},parts={},order={},raw={},raw_order={},raw_bytes=0,
    report={reads=0,decodes=0,max_ms=0}},M)
  for id,block in pairs(manifest.blocks)do
    local keys={};for key in pairs(block.state_properties)do keys[#keys+1]=key end;table.sort(keys);self.keys[id]=keys
  end
  catalogs[root]=self;return self
end
function M:model(record)
  local block=assert(self.manifest.blocks[record.content_id],'mechanism-block-missing:'..record.content_id)
  local parts={};for _,key in ipairs(self.keys[record.content_id])do
    local value=record.properties and record.properties[key];if value==nil then value=block.state_defaults[key]end
    parts[#parts+1]=key..'='..tostring(value)
  end
  return assert(self.manifest.states[record.content_id][table.concat(parts,',')],'mechanism-state-missing:'..record.content_id..':'..table.concat(parts,','))
end
function M:boxes(record)
  return assert(self.manifest.models[self:model(record)]).boxes_cm
end
function M:part(key)
  if self.parts[key]then return self.parts[key]end
  local began=os.clock();local entry=assert(self.manifest.models[key],'unlisted-mechanism-model')
  assert(entry.path:match('^meshes/[a-f0-9]+%.mesh$'),'mechanism-model-path')
  local raw=self.raw[key]
  if not raw then
    raw=read(self.root..'/'..entry.path,8*1024*1024)
    assert(#raw==entry.bytes and sha(raw)==entry.sha256,'mechanism-model-digest')
    self.raw[key]=raw;self.raw_order[#self.raw_order+1]=key;self.raw_bytes=self.raw_bytes+#raw
    self.report.reads=self.report.reads+1
    while self.raw_bytes>16*1024*1024 and #self.raw_order>1 do local old=table.remove(self.raw_order,1);self.raw_bytes=self.raw_bytes-#self.raw[old];self.raw[old]=nil end
  end
  local decoded=bundle.decode(raw,entry.scale or 6.25);assert(#decoded==1,'mechanism-model-part-count')
  local part=decoded[1]
  if entry.palette then require('host.pbz.translucent_blocks').palette_vertices(part)
  else for _,uv in ipairs(part.uv)do uv.X=433.5/512;uv.Y=139.5/256 end end
  if entry.render_layer=='translucent'then require('host.pbz.translucent_blocks').two_sided(part)end
  self.parts[key]=part;self.order[#self.order+1]=key
  -- Active components own their native vertex buffers; unused Lua decoded
  -- meshes do not accumulate across every redstone strength/orientation.
  while #self.order>96 do self.parts[table.remove(self.order,1)]=nil end
  self.report.decodes=self.report.decodes+1;self.report.max_ms=math.max(self.report.max_ms,(os.clock()-began)*1000)
  return part
end
return M
