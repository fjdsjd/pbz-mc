-- A reusable section of camera-facing, double-sided sprites. UE requires a
-- stable vertex count for UpdateMeshSection, including when sprites expire.
local M={}
local white={R=1,G=1,B=1,A=1}
local normal={X=0,Y=0,Z=1}
local indices={0,1,2,0,2,3,2,1,0,3,2,0}
local corners={{-1,-1},{1,-1},{1,1},{-1,1}}

function M.new(capacity)
  local b={capacity=capacity,used=0,positions={},normals={},uv={},colors={},triangles={}}
  for slot=1,capacity do
    local base=(slot-1)*4
    for i=1,4 do
      b.positions[base+i]={X=0,Y=0,Z=0}
      b.uv[base+i]={X=0,Y=0}
      b.normals[base+i]=normal
      b.colors[base+i]=white
    end
    for _,i in ipairs(indices) do b.triangles[#b.triangles+1]=base+i end
  end
  return b
end

function M.write(b,slot,x,y,z,right,up,size,u0,v0,u1,v1,color)
  local base=(slot-1)*4
  for i,c in ipairs(corners) do
    local p,uv=b.positions[base+i],b.uv[base+i]
    p.X=x+(right.X*c[1]+up.X*c[2])*size
    p.Y=y+(right.Y*c[1]+up.Y*c[2])*size
    p.Z=z+(right.Z*c[1]+up.Z*c[2])*size
    uv.X=c[1]<0 and u0 or u1
    uv.Y=c[2]<0 and v1 or v0
    b.colors[base+i]=color or white
  end
end

function M.finish(b,used)
  for i=used*4+1,b.used*4 do
    local p=b.positions[i]
    p.X,p.Y,p.Z=0,0,0
  end
  b.used=used
  return b
end
return M
