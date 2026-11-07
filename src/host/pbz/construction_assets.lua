-- Vanilla state recipes and texture coordinates stay on disk until a block is used.
local json=require('dkjson')
local sha=require('storage.sha256')
local bundle=require('host.pbz.mesh_bundle')
local M={};M.__index=M
local catalogs=setmetatable({},{__mode='v'})
local function read(path,limit)
  local f=assert(io.open(path,'rb'),path);local raw=f:read(limit+1);f:close()
  assert(raw and #raw<=limit,'construction-resource-size:'..path);return raw
end
local function keep(cache,order,key,value,limit)
  cache[key]=value;order[#order+1]=key
  if #order>limit then cache[table.remove(order,1)]=nil end
  return value
end
function M.open(root)
  if catalogs[root]then return catalogs[root]end
  local data=assert(json.decode(read(root..'/manifest.json',1024*1024)))
  assert(data.schema==1 and data.vanilla=='26.3' and #data.atlases==11,'construction-manifest')
  local self=setmetatable({root=root,manifest=data,blocks={},block_order={},mesh={},mesh_order={},
    parts={},part_order={},shapes={}},M)
  catalogs[root]=self;return self
end
function M:block(name)
  if self.blocks[name]then return self.blocks[name]end
  local record=assert(self.manifest.blocks[name],'unknown-construction-block:'..name)
  local raw=read(self.root..'/blocks/'..name..'.json',512*1024)
  assert(#raw==record.bytes and sha(raw)==record.sha256,'construction-definition-digest:'..name)
  return keep(self.blocks,self.block_order,name,assert(json.decode(raw)),80)
end
function M:state(record)
  local name=record.content_id:sub(7);local block=self:block(name)
  local p=record.properties or {};local values={}
  for i,k in ipairs(block.keys)do
    local v=p[k];if v==nil then v=block.defaults[k]end;values[i]=tostring(v)
  end
  local key=table.concat(values,',')
  return assert(block.states[block.lookup[key]],'unknown-construction-state:'..name..':'..key),name,block
end
function M:model(record)
  local state,name=self:state(record);local pieces={}
  for _,options in ipairs(state[1])do
    local chosen=options[1][1]
    if #options>1 then
      local total=0;for _,choice in ipairs(options)do total=total+choice[2]end
      local seed=(math.floor(record.x)*31+math.floor(record.y)*131+math.floor(record.z)*257)%2147483647
      local value=(seed*48271)%2147483647%total
      for _,choice in ipairs(options)do value=value-choice[2];if value<0 then chosen=choice[1];break end end
    end
    pieces[#pieces+1]=chosen
  end
  return 'construction/'..name..'/'..table.concat(pieces,'.')
end
function M:boxes(record)
  local state=self:state(record);local physical=self.manifest.shapes[state[2]+1]
  local query=#physical==0
  local n=(query and state[3] or state[2])+1
  if not self.shapes[n]then
    local boxes={}
    for i,b in ipairs(self.manifest.shapes[n])do
      boxes[i]={center={(b[1]+b[4]-1)*50,(1-b[3]-b[6])*50,(b[2]+b[5]-1)*50},
        half={(b[4]-b[1])*50,(b[6]-b[3])*50,(b[5]-b[2])*50}}
    end
    self.shapes[n]=boxes
  end
  return self.shapes[n],query
end
function M:piece(block,id,units)
  local key=id..'@'..units
  if self.mesh[key]then return self.mesh[key]end
  local spec=assert(block.meshes[tostring(id)],'unknown-construction-mesh')
  local f=assert(io.open(self.root..'/geometry.bin','rb'))
  assert(f:seek('set',spec[1]));local raw=f:read(spec[2]);f:close()
  assert(raw and #raw==spec[2] and sha(raw)==spec[3],'construction-mesh-digest:'..id)
  return keep(self.mesh,self.mesh_order,key,bundle.decode(raw,units)[1],96)
end
function M:part(key)
  if self.parts[key]then return self.parts[key]end
  local name,ids=key:match('^construction/([a-z0-9_]+)/([%d.]*)$')
  local block=self:block(assert(name));local components={}
  for id in ids:gmatch('%d+')do components[#components+1]=self:piece(block,tonumber(id),6.25)end
  if #components==1 then return components[1]end
  local part={positions={},normals={},uv={},colors={},triangles={}}
  for _,source in ipairs(components)do
    local n=#part.positions
    for _,field in ipairs({'positions','normals','uv','colors'})do
      for _,v in ipairs(source[field])do part[field][#part[field]+1]=v end
    end
    for _,i in ipairs(source.triangles)do part.triangles[#part.triangles+1]=n+i end
  end
  return keep(self.parts,self.part_order,key,part,96)
end
function M:item(name,context,units)
  local b=self:block(name)
  return {key='construction-item/'..name..'@'..units,model=name,part=self:piece(b,b.item,units),
    display=b.display,context=context,units=units,render_layer=b.render_layer or 'cutout',palette=self.manifest.atlases[1],material_root=self.root}
end
function M:material(world,stage,model)
  local name=model and model:match('^construction/([^/]+)')
  local cutout=not name or self:block(name).render_layer~='translucent'
  return require('host.pbz.translucent_blocks').cached(world,world.pawn,self.root,self.manifest.atlases[(stage or -1)+2],cutout)
end
function M:animate(world,tick)
  local animation=self.manifest.animations
  if not animation or not world.translucent_materials then return end
  local base=self.manifest.atlases[1]
  local row=world.translucent_materials[self.root..'/'..base.path..':'..base.sha256..':cutout']
  if not row then return end
  local identity=require('host.pbz.object_identity')
  if not identity.matches(row.material,row.mid)then return end
  local frame=tick%animation.cycle_ticks
  if row.animation_frame==frame then return end
  row.animation_textures=row.animation_textures or {[0]={texture=row.texture,id=row.tid}}
  local cached=row.animation_textures[frame]
  if not cached or not identity.matches(cached.texture,cached.id)then
    local entry=animation.palettes[frame+1]
    local raw=read(self.root..'/'..entry.path,256*1024)
    assert(#raw==entry.bytes and sha(raw)==entry.sha256,'command-animation-digest')
    local texture=StaticFindObject('/Script/Engine.KismetRenderingLibrary:ImportFileAsTexture2D')(
      StaticFindObject('/Script/Engine.Default__KismetRenderingLibrary'),world.pawn,self.root..'/'..entry.path)
    assert(texture and texture:IsValid(),'command-animation-texture')
    require('host.pbz.pixel_texture').configure(texture)
    cached={texture=texture,id=identity.capture(texture)};row.animation_textures[frame]=cached
  end
  row.material:SetTextureParameterValue(FName('SpriteTexture'),cached.texture);row.animation_frame=frame
end
return M
