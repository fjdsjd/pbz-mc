-- Six-face connectivity of the currently restored, same-kind MC cubes.
-- Spatial buckets bound lookup cost; corner-only contacts are not connected.
local M={}
local width=100.5
local function cell(x,y,z) return math.floor(x/width)..':'..math.floor(y/width)..':'..math.floor(z/width) end
function M.find(records,handles,start)
  local root=records[start];if not root or not handles[start] then return {} end
  local buckets={}
  for id,r in pairs(records) do
    if r.world==root.world and r.content_id==root.content_id and handles[id] then
      local key=cell(r.x,r.y,r.z);buckets[key]=buckets[key] or {};buckets[key][#buckets[key]+1]=id
    end
  end
  local function adjacent(a,b)
    local x,y,z=math.abs(a.x-b.x),math.abs(a.y-b.y),math.abs(a.z-b.z)
    local function face(n,u,v) return math.abs(n-100)<=.5 and u<99.5 and v<99.5 end
    return face(x,y,z) or face(y,x,z) or face(z,x,y)
  end
  local seen={[start]=true};local queue={start};local cursor=1
  while cursor<=#queue do
    local r=records[queue[cursor]];cursor=cursor+1
    for x=-1,1 do for y=-1,1 do for z=-1,1 do
      for _,id in ipairs(buckets[cell(r.x+x*width,r.y+y*width,r.z+z*width)] or {}) do
        if not seen[id] and adjacent(r,records[id]) then seen[id]=true;queue[#queue+1]=id end
      end
    end end end
  end
  return queue
end
return M
