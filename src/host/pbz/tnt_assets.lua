-- Original local MC assets, verified and decoded once per process/root.
local bundle=require('host.pbz.mesh_bundle')
local sha=require('storage.sha256')
local json=require('dkjson')
local M={};M.__index=M
local roots={}
local function read(path)
 local f=assert(io.open(path,'rb'));local s=f:seek('end');f:seek('set',0)
 assert(s and s<8*1024*1024,'tnt-asset-size');local b=f:read('a');f:close();return b
end
function M.open(root)
 if roots[root]then return roots[root]end
 local manifest=assert(json.decode(read(root..'/manifest.json')))
 assert(manifest.schema==1 and manifest.minecraft_version=='1.21.1','tnt-asset-schema')
 local self=setmetatable({root=root,manifest=manifest,records={},cache={},verified={}},M)
 for _,r in ipairs(manifest.outputs)do self.records[r.path]=r end
 for _,r in ipairs(manifest.sources)do if r.retained then self.records[r.retained]={sha256=r.sha256}end end
 self.records[manifest.particles.path]=manifest.particles
 roots[root]=self;return self
end
function M:bytes(path)
 local r=assert(self.records[path],'unlisted-tnt-asset:'..path)
 local raw=read(self.root..'/'..path)
 assert((not r.bytes or #raw==r.bytes) and sha(raw)==r.sha256,'tnt-asset-digest:'..path)
 self.verified[path]=true;return raw
end
function M:path(path)
 if path=='particles/atlas.png' and not self.records[path]then self:particles()end
 if not self.verified[path]then self:bytes(path)end
 return self.root..'/'..path
end
function M:part(path)
 if self.cache[path]then return self.cache[path]end
 local r=assert(self.records[path]);local part=assert(bundle.decode(self:bytes(path),r.scale or 6.25)[1])
 if path~='fire/fire_textured.mesh' then
  for _,uv in ipairs(part.uv)do uv.X=433.5/512;uv.Y=139.5/256 end
 end
 self.cache[path]=part;return part
end
function M:fire(frame)
 local key='frame:'..frame;if self.cache[key]then return self.cache[key]end
 local base=self:part('fire/fire_textured.mesh');local p={}
 for k,v in pairs(base)do p[k]=v end;p.uv={}
 for i,uv in ipairs(base.uv)do p.uv[i]={X=uv.X,Y=(frame+uv.Y)/32}end
 self.cache[key]=p;return p
end
function M:particles()
 if not self.particle_data then
  self.particle_data=assert(json.decode(self:bytes('particles.json')))
  self.records[self.particle_data.atlas.path]=self.particle_data.atlas
 end
 return self.particle_data
end
return M
