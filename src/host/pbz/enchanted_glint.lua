-- Pinned MinecraftGlint.cs: original glint texture sampled into 12 color frames.
-- Only UpdateMeshSection is used; collision, triangles and ownership are fixed.
local M={};local caches={}
local function read(path)
 local f=assert(io.open(path,'rb'));local data=f:read('a');f:close();return data
end
function M.update(entry,model,root,seconds)
 if not model.enchanted and not entry.glint then return end
 local part=model.part;local colors=part.colors;local frame
 if model.enchanted then
  local name=model.glint_asset or 'enchanted_apple_glint'
  assert(name=='enchanted_apple_glint' or name=='enchanted_mace_glint','unknown-item-glint')
  local key=root..'/../effects/'..name
  local frames=caches[key]
  if not frames then
   local spec=assert(require('dkjson').decode(read(key..'.json')));local raw=read(key..'.bin')
   assert(require('storage.sha256')(raw)==spec.sha256 and raw:sub(1,8)=='PBZGLNT1','glint-resource-digest')
   local count,n,cursor=string.unpack('<I4I4',raw,9)
   assert(count==#part.positions and n==12 and #raw==16+count*n*16,'glint-mesh-layout')
   frames={}
   for i=1,n do local row={};frames[i]=row
    for j=1,count do local r,g,b,a;r,g,b,a,cursor=string.unpack('<ffff',raw,cursor);row[j]={R=r,G=g,B=b,A=a} end
   end
   caches[key]=frames
  end
  frame=math.floor(seconds*12)%12+1;colors=frames[frame]
 end
 if entry.glint==frame and entry.glint_key==model.key then return end
 entry.component:UpdateMeshSection_LinearColor(0,part.positions,part.normals,part.uv,{},{},{},colors,{},false)
 entry.glint=frame;entry.glint_key=model.key
end
return M
