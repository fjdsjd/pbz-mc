-- Original MC bone-local armor. File verification/decoding and layer merging
-- happen once per material/outfit change, never in the animation hot path.
local bundle=require('host.pbz.mesh_bundle')
local sha=require('storage.sha256')
local json=require('dkjson')
local M={};M.__index=M
local catalogs={}
local bones={'head','body','left_arm','right_arm','left_leg','right_leg'}
local slots={'head','chest','legs','feet'}
local function read(path,limit)
  local f=assert(io.open(path,'rb'));local size=f:seek('end');f:seek('set',0)
  if not size or size>limit then f:close();error('armor-file-too-large')end
  local raw=f:read('a');f:close();return assert(raw)
end
local function safe(path)
  return type(path)=='string' and path:match('^[a-z0-9_./-]+%.mesh$')
    and path:sub(1,1)~='/' and not path:find('..',1,true) and not path:find('//',1,true)
end
function M.new(root)
  if catalogs[root] then return catalogs[root]end
  local raw=read(root..'/manifest.json',4*1024*1024)
  local manifest,pos,why=json.decode(raw)
  assert(manifest and not why and raw:sub(pos):match('^%s*$'),'invalid-armor-manifest')
  assert(manifest.schema==1 and manifest.format=='STEVEM01' and manifest.private_local_assets==true,'unsupported-armor-manifest')
  local self=setmetatable({root=root,manifest=manifest,records={},meshes={},combinations={},order={},
    report={reads=0,decodes=0,merges=0}},M)
  for _,entry in ipairs(manifest.outputs)do
    if entry.path:match('%.mesh$')then
      assert(safe(entry.path) and not self.records[entry.path],'invalid-armor-path')
      assert(type(entry.sha256)=='string' and #entry.sha256==64 and entry.sha256:match('^[0-9a-f]+$'),'invalid-armor-digest')
      assert(type(entry.bytes)=='number' and entry.bytes>0 and entry.bytes<=16*1024*1024,'invalid-armor-size')
      self.records[entry.path]=entry
    end
  end
  catalogs[root]=self;return self
end
function M:mesh(path)
  local result=self.meshes[path];if result then return result end
  local record=assert(self.records[path],'unlisted-armor-output:'..tostring(path))
  local raw=read(self.root..'/'..path,16*1024*1024)
  assert(#raw==record.bytes and sha(raw)==record.sha256,'armor-hash-mismatch:'..path)
  local parts=bundle.decode(raw,require('presentation.native_steve_pose').scale)
  assert(#parts==1 and #parts[1].positions>0,'armor-single-bone-required')
  result=parts[1]
  assert(result.pivot.X==0 and result.pivot.Y==0 and result.pivot.Z==0,'armor-local-pivot-required')
  for _,uv in ipairs(result.uv)do uv.X=433.5/512;uv.Y=139.5/256 end
  self.meshes[path]=result;self.report.reads=self.report.reads+1;self.report.decodes=self.report.decodes+1
  return result
end
function M:resolve(snapshot)
  local lists={};for _,bone in ipairs(bones)do lists[bone]={}end
  for _,slot in ipairs(slots)do
    local equipped=snapshot.pieces[slot]
    if equipped and equipped.model_layer~='elytra' then
      local item=assert(self.manifest.items[equipped.content_id],'armor-model-unavailable:'..equipped.content_id)
      assert(item.slot==slot,'armor-model-slot-mismatch')
      for _,part in ipairs(item.parts)do
        local list=assert(lists[part.bone],'armor-model-bone-invalid')
        assert(safe(part.path),'armor-model-path-invalid');list[#list+1]=part.path
      end
    end
  end
  local result={}
  for _,bone in ipairs(bones)do
    local paths=lists[bone]
    if #paths>0 then
      local key=bone..':'..table.concat(paths,'|');local merged=self.combinations[key]
      if not merged then
        if #paths==1 then merged=self:mesh(paths[1])
        else
          merged={name=bone,pivot={X=0,Y=0,Z=0},positions={},normals={},uv={},colors={},triangles={}}
          for _,path in ipairs(paths)do
            local mesh=self:mesh(path);local offset=#merged.positions
            -- Immutable vertex records are shared; only index/list storage is merged.
            for _,name in ipairs({'positions','normals','uv','colors'})do
              for _,v in ipairs(mesh[name])do merged[name][#merged[name]+1]=v end
            end
            for _,i in ipairs(mesh.triangles)do merged.triangles[#merged.triangles+1]=i+offset end
          end
          self.report.merges=self.report.merges+1
        end
        self.combinations[key]=merged;self.order[#self.order+1]=key
        if #self.order>48 then self.combinations[table.remove(self.order,1)]=nil end
      end
      result[bone]={key=key,part=merged}
    end
  end
  return result
end
M.bones=bones
return M
