-- Cooked PBZ material for original MC vertex colours and per-pixel alpha.
-- Owners cache the returned instance; no ticking, texture rebuild or IO.
local M={}
local identity=require('host.pbz.object_identity')
function M.new(context,root,palette)
  local base=LoadAsset('/Engine/EngineMaterials/Widget3DPassThrough_Translucent_OneSided.Widget3DPassThrough_Translucent_OneSided')
  assert(base and base:IsValid(),'translucent-block-material-unavailable')
  assert(palette and type(palette.path)=='string'and palette.path:match('^[a-z0-9_/]+%.png$')
    and not palette.path:find('..',1,true),'translucent-palette-path')
  local file=assert(io.open(root..'/'..palette.path,'rb'));local raw=file:read('a');file:close()
  assert(#raw==palette.bytes and require('storage.sha256')(raw)==palette.sha256,'translucent-palette-digest')
  local texture=StaticFindObject('/Script/Engine.KismetRenderingLibrary:ImportFileAsTexture2D')(
    StaticFindObject('/Script/Engine.Default__KismetRenderingLibrary'),context,root..'/'..palette.path)
  assert(texture and texture:IsValid(),'translucent-palette-import');texture.Filter=0
  local material=StaticFindObject('/Script/Engine.Default__KismetMaterialLibrary'):CreateDynamicMaterialInstance(
    context,base,FName('PBZMC_TranslucentBlocks'),1)
  assert(material and material:IsValid(),'translucent-block-instance-unavailable')
  material:SetTextureParameterValue(FName('SlateUI'),texture)
  material:SetVectorParameterValue(FName('TintColorAndOpacity'),{R=1,G=1,B=1,A=1})
  material:SetVectorParameterValue(FName('BackColor'),{R=0,G=0,B=0,A=0})
  material:SetScalarParameterValue(FName('OpacityFromTexture'),1)
  return material,texture
end
function M.cached(owner,context,root,palette)
  local key=root..'/'..palette.path..':'..palette.sha256
  owner.translucent_materials=owner.translucent_materials or {}
  local row=owner.translucent_materials[key]
  if not row or not identity.matches(row.material,row.mid)or not identity.matches(row.texture,row.tid)then
    local material,texture=M.new(context,root,palette)
    row={material=material,texture=texture,mid=identity.capture(material),tid=identity.capture(texture)}
    owner.translucent_materials[key]=row
  end
  return row.material
end
function M.palette_vertices(part)
  -- Widget pass-through ignores vertex colour. Sample the lossless original
  -- RGBA palette with its original UV instead of producing a white cube.
  for _,color in ipairs(part.colors)do color.R=1;color.G=1;color.B=1;color.A=1 end
end
function M.two_sided(part)
  if part.translucent_two_sided then return part end
  local t=part.triangles;local n=#t
  for i=1,n,3 do t[#t+1]=t[i];t[#t+1]=t[i+2];t[#t+1]=t[i+1]end
  part.translucent_two_sided=true
  return part
end
return M
