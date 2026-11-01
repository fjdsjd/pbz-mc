-- Index axis-aligned full cubes. Glass culls against glass and solid neighbors,
-- but a glass neighbor must not remove the opaque surface visible behind it.
local M={};M.__index=M
M.offsets={{100,0,0},{-100,0,0},{0,100,0},{0,-100,0},{0,0,100},{0,0,-100}}
local function key(x,y,z) return string.format('%.2f/%.2f/%.2f',x,y,z) end
function M.new() return setmetatable({cells={}},M) end
function M:put(handle)
  local r=handle.record;local k=key(r.x,r.y,r.z)
  assert(not self.cells[k] or self.cells[k]==handle,'duplicate-render-cell')
  self.cells[k]=handle
end
function M:remove(handle)
  local r=handle.record;local k=key(r.x,r.y,r.z)
  if self.cells[k]==handle then self.cells[k]=nil end
end
function M:neighbor(handle,face)
  local r=handle.record;local d=M.offsets[face]
  local x,y,z=r.x+d[1],r.y+d[2],r.z+d[3];local n=self.cells[key(x,y,z)]
  if n and math.abs(n.record.x-x)<.01 and math.abs(n.record.y-y)<.01 and math.abs(n.record.z-z)<.01 then return n end
end
function M.occludes(handle,neighbor)
  if not neighbor then return false end
  if neighbor.opaque~=false then return true end
  return handle.cull_same~=nil and handle.cull_same==neighbor.cull_same
end
function M.split(part)
  local out,maps={},{}
  for i=1,6 do out[i]={positions={},normals={},uv={},colors={},triangles={}};maps[i]={} end
  local function face(n)
    if math.abs(n.X)>.99 then return n.X>0 and 1 or 2 end
    if math.abs(n.Y)>.99 then return n.Y>0 and 3 or 4 end
    assert(math.abs(n.Z)>.99,'non-cubic-face-normal');return n.Z>0 and 5 or 6
  end
  for i=1,#part.triangles,3 do
    local f=face(part.normals[part.triangles[i]+1]);local p,map=out[f],maps[f]
    for j=i,i+2 do
      local old=part.triangles[j]+1;assert(face(part.normals[old])==f,'cross-face-triangle')
      if not map[old] then
        local new=#p.positions+1;map[old]=new
        for _,field in ipairs({'positions','normals','uv','colors'}) do p[field][new]=part[field][old] end
      end
      p.triangles[#p.triangles+1]=map[old]-1
    end
  end
  return out
end
function M.combine(faces,mask)
  local part={positions={},normals={},uv={},colors={},triangles={}}
  for i=1,6 do if (mask&(1<<(i-1)))~=0 then
    local source=faces[i];local offset=#part.positions
    for _,field in ipairs({'positions','normals','uv','colors'}) do
      for _,value in ipairs(source[field]) do part[field][#part[field]+1]=value end
    end
    for _,index in ipairs(source.triangles) do part.triangles[#part.triangles+1]=offset+index end
  end end
  return part
end
return M
