-- Reader for the pinned upstream STEVEM01 format. Geometry remains private/local.
local M={}
local unpack=string.unpack
local huge=math.huge
local function linear(v) return v<=.04045 and v/12.92 or ((v+.055)/1.055)^2.4 end
function M.read(path,scale)
  local file=assert(io.open(path,'rb'))
  local size=file:seek('end');file:seek('set',0)
  if not size or size>64*1024*1024 then file:close();error('mesh-too-large') end
  local raw=file:read('a');file:close()
  return M.decode(raw,scale)
end
function M.decode(raw,scale)
  assert(type(scale)=='number' and scale>0 and scale<1000,'invalid-mesh-scale')
  assert(type(raw)=='string' and #raw<=64*1024*1024,'invalid-mesh-bytes')
  assert(raw:sub(1,8)=='STEVEM01','invalid-mesh-magic')
  local count,cursor=unpack('<I4',raw,9)
  assert(count>0 and count<=64,'invalid-mesh-parts')
  local parts={}
  for part_index=1,count do
    local length;length,cursor=unpack('<I4',raw,cursor)
    assert(length>0 and length<=128,'invalid-part-name')
    local name=raw:sub(cursor,cursor+length-1);cursor=cursor+length
    assert(#name==length and name:match('^[a-z0-9_]+$'),'invalid-part-name')
    local px,py,pz,vertices,indices
    px,py,pz,vertices,indices,cursor=unpack('<fffI4I4',raw,cursor)
    assert(px>-huge and px<huge and py>-huge and py<huge and pz>-huge and pz<huge,'nonfinite-mesh-pivot')
    assert(vertices<=100000 and indices%3==0 and indices<=600000 and
      ((vertices==0 and indices==0) or (vertices>0 and indices>0)),'invalid-mesh-counts')
    assert(cursor+vertices*48+indices*4-1<=#raw,'truncated-mesh-data')
    local positions,normals,uv,colors,triangles={},{},{},{},{}
    for i=1,vertices do
      local x,y,z,nx,ny,nz,u,v,r,g,b,a
      x,y,z,nx,ny,nz,u,v,r,g,b,a,cursor=unpack('<ffffffffffff',raw,cursor)
      -- Every unpacked float remains finite-checked, without constructing an
      -- extra 12-value table or calling a predicate once per field. Ordered
      -- comparisons reject NaN as well as either infinity.
      assert(x>-huge and x<huge and y>-huge and y<huge and z>-huge and z<huge
        and nx>-huge and nx<huge and ny>-huge and ny<huge and nz>-huge and nz<huge
        and u>-huge and u<huge and v>-huge and v<huge and r>-huge and r<huge
        and g>-huge and g<huge and b>-huge and b<huge and a>-huge and a<huge,'nonfinite-mesh-value')
      assert(x>=-10000 and x<=10000 and y>=-10000 and y<=10000 and z>=-10000 and z<=10000,'invalid-mesh-position')
      positions[i]={X=-z*scale,Y=-x*scale,Z=-y*scale}
      normals[i]={X=-nz,Y=-nx,Z=-ny}
      uv[i]={X=u,Y=v}
      colors[i]={R=linear(r),G=linear(g),B=linear(b),A=a}
    end
    -- Indices are guaranteed to be a multiple of three. Direct fixed-size
    -- unpacking avoids one temporary table and two C calls per triangle.
    for i=1,indices,3 do
      local a,b,c;a,b,c,cursor=unpack('<I4I4I4',raw,cursor)
      assert(a<vertices and b<vertices and c<vertices,'mesh-index-out-of-range')
      triangles[i]=a;triangles[i+1]=b;triangles[i+2]=c
    end
    parts[part_index]={name=name,pivot={X=-pz*scale,Y=-px*scale,Z=-py*scale},positions=positions,normals=normals,uv=uv,colors=colors,triangles=triangles}
  end
  assert(cursor==#raw+1,'trailing-mesh-bytes')
  return parts
end
function M.apply(component,part,section)
  component:CreateMeshSection_LinearColor(section or 0,part.positions,part.triangles,part.normals,part.uv,{},{},{},part.colors,{},false,false)
end
return M
