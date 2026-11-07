local S=require('rules.commands.syntax')
local M={}
local function pos(a,i,c)local p,n=S.position(a,i,c);for k,v in pairs(p)do p[k]=math.floor(v)end;return p,n end
local function block(raw)
 local id,properties,data=S.block(raw);return {id=S.id(id),properties=properties,data=data}
end
local function match(r,pattern)
 if pattern.id~=r.id then return false end
 for k,v in pairs(pattern.properties)do if (r.properties or {})[k]~=v then return false end end
 if pattern.data and not require('rules.commands.selectors').subset(pattern.data,r.data or {})then return false end
 return true
end
function M.setblock(e,a,c)
 local p,i=pos(a,1,c);local entry=block(assert(a[i],'block-required'));local mode=a[i+1] or 'replace'
 assert((mode=='replace' or mode=='destroy' or mode=='keep') and not a[i+2],'invalid-setblock-mode')
 if mode=='keep' and e:call('read_block',p).id~='minecraft:air'then return 0 end
 return e:call('write_blocks',{{pos=p,block=entry}})
end
function M.fill(e,a,c)
 local from,i=pos(a,1,c);local to,j=pos(a,i,c);local entry=block(assert(a[j],'block-required'))
 local mode=a[j+1] or 'replace';assert(mode=='replace' or mode=='destroy' or mode=='keep' or mode=='outline' or mode=='hollow','invalid-fill-mode')
 local filter=a[j+2] and block(a[j+2]);assert(not a[j+3] and (not filter or mode=='replace'),'fill-extra-arguments')
 local lo,hi={},{};local volume=1
 local limit=math.min(8192,e:state().rules.max_block_modifications or 32768)
 for _,k in ipairs({'x','y','z'})do
  lo[k]=math.min(from[k],to[k]);hi[k]=math.max(from[k],to[k]);local size=hi[k]-lo[k]+1
  assert(size<=limit and volume<=limit/size,'fill-volume-exceeds-host-limit:'..limit);volume=volume*size
 end
 local changes={}
 for y=lo.y,hi.y do for z=lo.z,hi.z do for x=lo.x,hi.x do
  e:spend();local p={x=x,y=y,z=z};local current=e:call('read_block',p)
  local edge=x==lo.x or x==hi.x or y==lo.y or y==hi.y or z==lo.z or z==hi.z
  if (mode~='keep' or current.id=='minecraft:air') and (mode~='outline' or edge) and (not filter or match(current,filter))then
   changes[#changes+1]={pos=p,block=mode=='hollow' and not edge and {id='minecraft:air',properties={}} or entry}
  end
 end end end
 return e:call('write_blocks',changes)
end
function M.clone(e,a,c)
 local from,i=pos(a,1,c);local to,j=pos(a,i,c);local target,k=pos(a,j,c)
 local mask=a[k] or 'replace';assert(mask=='replace' or mask=='masked' or mask=='filtered','invalid-clone-mask')
 local filter;if mask=='filtered'then filter=block(assert(a[k+1],'clone-filter-required'));k=k+1 end
 local mode=a[k+1] or 'normal';assert(mode=='normal' or mode=='force' or mode=='move','invalid-clone-mode')
 assert(not a[k+2],'clone-extra-arguments');local lo,hi={},{};local volume=1
 local limit=math.min(4096,e:state().rules.max_block_modifications or 32768)
 for _,axis in ipairs({'x','y','z'})do
  lo[axis]=math.min(from[axis],to[axis]);hi[axis]=math.max(from[axis],to[axis]);local size=hi[axis]-lo[axis]+1
  assert(size<=limit and volume<=limit/size,'clone-volume-exceeds-host-limit:'..limit);volume=volume*size
 end
 if mode=='normal'then
  local overlap=true;for _,axis in ipairs({'x','y','z'})do overlap=overlap and target[axis]<=hi[axis] and target[axis]+hi[axis]-lo[axis]>=lo[axis]end
  assert(not overlap,'clone-regions-overlap')
 end
 local moved,placed={},{}
 for y=lo.y,hi.y do for z=lo.z,hi.z do for x=lo.x,hi.x do
  e:spend();local p={x=x,y=y,z=z};local r=e:call('read_block',p)
  if (mask~='masked' or r.id~='minecraft:air') and (not filter or match(r,filter))then
   placed[#placed+1]={pos={x=target.x+x-lo.x,y=target.y+y-lo.y,z=target.z+z-lo.z},block=r}
   if mode=='move'then moved[#moved+1]={pos=p,block={id='minecraft:air',properties={}}}end
  end
 end end end
 for _,r in ipairs(placed)do moved[#moved+1]=r end
 return e:call('write_blocks',moved)
end
return M
