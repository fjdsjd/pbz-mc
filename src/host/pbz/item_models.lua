-- Private original MC models. Resolve by stable item ID and original context;
-- hash the exact bytes consumed by the mesh reader, with no icon substitution.
local bundle=require('host.pbz.mesh_bundle')
local sha256=require('storage.sha256')
local json=require('dkjson')
local M={};M.__index=M
local function read(path,limit)
  local file=assert(io.open(path,'rb'))
  local size=file:seek('end');file:seek('set',0)
  if not size or size>limit then file:close();error('item-model-file-too-large') end
  local raw=file:read('a');file:close();return assert(raw)
end
local function path_ok(path)
  return type(path)=='string' and (path:match('^[a-z0-9_./-]+%.mesh$')or path:match('^mechanisms/palettes/[a-z_]+%.png$')) and path:sub(1,1)~='/'
    and not path:find('..',1,true) and not path:find('//',1,true)
end
function M.new(root)
  local raw=read(root..'/manifest.json',8*1024*1024)
  local manifest,pos,why=json.decode(raw)
  assert(manifest and not why and raw:sub(pos):match('^%s*$'),'invalid-item-model-manifest-json')
  assert(manifest.schema==1 and manifest.format=='STEVEM01' and manifest.private_local_assets==true,
    'unsupported-item-model-manifest')
  assert(type(manifest.items)=='table' and type(manifest.models)=='table' and type(manifest.outputs)=='table',
    'invalid-item-model-manifest')
  local self=setmetatable({root=root,manifest=manifest,records={},cache={}},M)
  for _,entry in ipairs(manifest.outputs) do
    assert(path_ok(entry.path) and not self.records[entry.path],'invalid-or-duplicate-item-model-path')
    assert(type(entry.sha256)=='string' and #entry.sha256==64 and entry.sha256:match('^[0-9a-f]+$'),
      'invalid-item-model-digest')
    assert(type(entry.bytes)=='number' and entry.bytes>0 and entry.bytes<=64*1024*1024,'invalid-item-model-size')
    self.records[entry.path]=entry
  end
  return self
end
function M:resolve(stack,context,properties,units)
  if not stack or require('rules.native_slot_reference').is(stack) then return nil end
  local id=stack.content_id
  local item=self.manifest.items[id]
  if not item and (require('content.blocks').get(id) or {}).construction then
    if require('content.blocks').get(id).command_block then
      self.command_blocks=self.command_blocks or require('host.pbz.construction_assets').open(self.root..'/../command-blocks')
      return self.command_blocks:item(id:sub(7),context,units)
    end
    self.construction=self.construction or require('host.pbz.construction_assets').open(self.root..'/../construction')
    return self.construction:item(id:sub(7),context,units)
  end
  if not item then return nil,'item-model-unavailable:'..tostring(id) end
  -- This generated trident asset is the GUI icon. Its entity mesh has not been
  -- converted yet; never show the icon as a held or dropped trident.
  if id=='pbzmc:trident' and context~='gui' then return nil,'item-model-entity-required:'..id end
  local selected=item.contexts[context]
  if not selected then return nil,'item-model-context-unavailable:'..id..':'..context end
  properties=properties or {}
  for _,condition in ipairs(selected.conditions or {}) do
    if condition~='untrimmed only' or (stack.metadata and stack.metadata.trim) then
      return nil,'item-model-condition-unavailable:'..id
    end
  end
  local key=selected.model
  for _,variant in ipairs(item.variants or {}) do
    if variant.base_model==selected.model then
      local matches=true
      for property,minimum in pairs(variant.predicate or {}) do
        local value=properties[property] or (property=='trim_type' and -1 or 0)
        assert(type(value)=='number' and value==value and math.abs(value)<math.huge,'invalid-model-property')
        if value<minimum then matches=false end
      end
      if matches then
        if not variant.model then return nil,'item-model-variant-unavailable:'..id end
        key=variant.model
      end
    end
  end
  local model=assert(self.manifest.models[key],'missing-item-model-definition')
  local record=assert(self.records[model.path],'unlisted-item-model-output')
  if model.palette then
    local palette=assert(self.records[model.palette.path],'unlisted-item-palette')
    assert(palette.sha256==model.palette.sha256 and palette.bytes==model.palette.bytes,'item-palette-manifest-mismatch')
  end
  assert(type(units)=='number' and units>0 and units<1000,'invalid-item-model-units')
  -- Shield states share geometry and change only their original display pose.
  -- Reuse the mesh across those states, avoiding a procedural mesh upload on
  -- every press/release. Bow variants still have distinct geometry files.
  local cache_key=model.path..':'..record.sha256..'@'..tostring(units)..(model.palette and ':'..model.palette.sha256 or '')
  local part=self.cache[cache_key]
  if not part then
    local raw=read(self.root..'/'..model.path,64*1024*1024)
    assert(#raw==record.bytes and sha256(raw)==record.sha256,'item-model-hash-mismatch:'..model.path)
    local parts=bundle.decode(raw,units)
    assert(#parts==1 and #parts[1].positions>0,'item-model-single-mesh-required')
    part=parts[1]
    if model.palette then require('host.pbz.translucent_blocks').palette_vertices(part)
    else for _,uv in ipairs(part.uv) do uv.X=433.5/512;uv.Y=139.5/256 end end
    if model.render_layer=='translucent'then require('host.pbz.translucent_blocks').two_sided(part)end
    self.cache[cache_key]=part
  end
  local command_enchanted=id=='pbzmc:mace'and stack.metadata and stack.metadata.command_enchantments and next(stack.metadata.command_enchantments)~=nil
  return {key=cache_key,model=key,part=part,display=model.display,context=context,units=units,enchanted=item.enchantment_glint==true or command_enchanted==true,
    glint_asset=command_enchanted and 'enchanted_mace_glint'or item.glint_asset,
    render_layer=model.render_layer,palette=model.palette}
end
return M
