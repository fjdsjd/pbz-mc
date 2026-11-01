-- Immutable decoded geometry may be shared by bundle root. Native components,
-- capture flags, poses and materials are always owned by worn_elytra instances.
local bundle=require('host.pbz.mesh_bundle')
local sha=require('storage.sha256')
local json=require('dkjson')
local M={};M.__index=M
local catalogs={}
local names={'left_wing','right_wing'}
local function read(path,limit)
  local f=assert(io.open(path,'rb'));local size=f:seek('end');f:seek('set',0)
  if not size or size>limit then f:close();error('elytra-file-too-large')end
  local raw=f:read('a');f:close();return assert(raw)
end
local function safe(path)
  return type(path)=='string' and path:match('^[a-z0-9_./-]+%.mesh$') and path:sub(1,1)~='/'
    and not path:find('..',1,true) and not path:find('//',1,true)
end
function M.new(root)
  assert(type(root)=='string' and #root>0,'elytra-root-required')
  if catalogs[root]then return catalogs[root]end
  local raw=read(root..'/manifest.json',4*1024*1024)
  local manifest,pos,why=json.decode(raw)
  assert(manifest and not why and raw:sub(pos):match('^%s*$'),'invalid-elytra-manifest')
  assert(manifest.schema==1 and manifest.format=='STEVEM01' and manifest.private_local_assets==true,'unsupported-elytra-manifest')
  local self=setmetatable({root=root,manifest=manifest,records={},parts={},report={reads=0,decodes=0}},M)
  for _,record in ipairs(manifest.outputs)do
    if record.path:match('%.mesh$')then
      assert(safe(record.path) and not self.records[record.path],'invalid-elytra-path')
      assert(type(record.sha256)=='string' and #record.sha256==64 and record.sha256:match('^[0-9a-f]+$'),'invalid-elytra-digest')
      assert(type(record.bytes)=='number' and record.bytes>0 and record.bytes<=16*1024*1024,'invalid-elytra-size')
      self.records[record.path]=record
    end
  end
  for _,name in ipairs(names)do
    local spec=assert(manifest.wings[name],'elytra-wing-missing:'..name)
    assert(safe(spec.path) and self.records[spec.path],'invalid-elytra-wing-path')
    local p=spec.pivot_cm
    assert(type(p)=='table' and #p==3,'invalid-elytra-pivot')
    for _,n in ipairs(p)do assert(type(n)=='number' and n==n and math.abs(n)<1000,'invalid-elytra-pivot')end
  end
  catalogs[root]=self;return self
end
function M:resolve()
  for _,name in ipairs(names)do
    if not self.parts[name]then
      local spec=self.manifest.wings[name];local record=self.records[spec.path]
      local raw=read(self.root..'/'..spec.path,16*1024*1024)
      assert(#raw==record.bytes and sha(raw)==record.sha256,'elytra-hash-mismatch:'..spec.path)
      local parts=bundle.decode(raw,require('presentation.native_steve_pose').scale)
      assert(#parts==1 and parts[1].name==name and #parts[1].positions>0,'invalid-elytra-wing-mesh')
      local part=parts[1]
      assert(part.pivot.X==0 and part.pivot.Y==0 and part.pivot.Z==0,'elytra-local-pivot-required')
      for _,uv in ipairs(part.uv)do uv.X=433.5/512;uv.Y=139.5/256 end
      self.parts[name]={key=record.sha256,part=part}
      self.report.reads=self.report.reads+1;self.report.decodes=self.report.decodes+1
    end
  end
  return self.parts,self.manifest.wings
end
return M
