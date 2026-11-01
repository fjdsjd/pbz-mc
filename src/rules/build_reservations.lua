-- Small spatial index for saved blocks waiting for native restoration. A
-- temporarily occupied record reserves only its own volume, not all building.
local M={};M.__index=M
local function key(x,y,z) return x..'/'..y..'/'..z end
local function bounds(r,h)
  local c,s=math.abs(math.cos(math.rad(r.yaw or 0))),math.abs(math.sin(math.rad(r.yaw or 0)))
  local x,y=c*h.x+s*h.y,s*h.x+c*h.y
  return {r.x-x,r.y-y,r.z-h.z,r.x+x,r.y+y,r.z+h.z}
end
local function visit(b,fn)
  for x=math.floor(b[1]/100),math.floor(b[4]/100) do
    for y=math.floor(b[2]/100),math.floor(b[5]/100) do
      for z=math.floor(b[3]/100),math.floor(b[6]/100) do
        local result=fn(key(x,y,z));if result then return result end
      end
    end
  end
end
function M.new(registry) return setmetatable({registry=registry,cells={},entries={}},M) end
function M:put(record)
  local b=bounds(record,self.registry.get(record.content_id).half)
  local entry={bounds=b,keys={}};self.entries[record.id]=entry
  visit(b,function(k)
    local cell=self.cells[k] or {};self.cells[k]=cell;cell[record.id]=entry;entry.keys[#entry.keys+1]=k
  end)
end
function M:remove(id)
  local entry=self.entries[id];if not entry then return end
  for _,k in ipairs(entry.keys) do local cell=self.cells[k];cell[id]=nil;if not next(cell) then self.cells[k]=nil end end
  self.entries[id]=nil
end
function M:overlap(content_id,position)
  local b=bounds(position,self.registry.get(content_id).half);local seen={}
  return visit(b,function(k)
    for id,entry in pairs(self.cells[k] or {}) do if not seen[id] then
      seen[id]=true;local other=entry.bounds;local hit=true
      for i=1,3 do if math.min(b[i+3],other[i+3])-math.max(b[i],other[i])<=.5 then hit=false;break end end
      if hit then return id end
    end end
  end)
end
return M
