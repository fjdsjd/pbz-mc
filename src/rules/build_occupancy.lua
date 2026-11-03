-- Spatial occupancy and per-group limits for the current immutable building
-- snapshot. An inventory reload or a separate placement invalidates the index.
local M={};M.__index=M
local function position(r)return string.pack('<ddd',r.x+0.,r.y+0.,r.z+0.)end
local function add(t,k,n)t[k]=(t[k] or 0)+n;if t[k]==0 then t[k]=nil end end
local function tally(index,r,n)
  index.total=index.total+n
  if r.world~=index.world then return end
  add(index.cells,position(r),n)
  local def=index.registry.get(r.content_id)
  if def then
    local group=def.group or 'block'
    add(index.counts,group,n)
    local limits=index.limits[group] or {};index.limits[group]=limits
    add(limits,def.limit or 1024,n)
  end
end
local function empty(session)
  return {total=0,cells={},counts={},limits={},registry=session.registry,world=session.world}
end
function M.for_session(session)
  local map=session.data.buildings;local index=session.batch_occupancy
  if index and index.map==map then return index end
  index=setmetatable(empty(session),M);index.map=map
  for _,r in pairs(map)do tally(index,r,1)end
  session.batch_occupancy=index;return index
end
function M:delta(rows)
  local delta=empty(self)
  for _,row in ipairs(rows)do
    local a,b=row.before,row.after
    if not (a and b and a.content_id==b.content_id and a.x==b.x and a.y==b.y and a.z==b.z)then
      if a then tally(delta,a,-1)end
      if b then tally(delta,b,1)end
    end
  end
  for _,row in ipairs(rows)do
    if row.after then
      local key=position(row.after)
      if (self.cells[key] or 0)+(delta.cells[key] or 0)>1 then return nil,'batch-grid-occupied'end
    end
  end
  if self.total+delta.total>8192 then return nil,'world-building-capacity'end
  for group,increase in pairs(delta.counts)do if increase>0 then
    local count=(self.counts[group] or 0)+increase
    local old,changed=self.limits[group] or {},delta.limits[group]
    for limit,n in pairs(old)do
      if count>limit and n+(changed[limit] or 0)>0 then return nil,'building-capacity'end
    end
    for limit,n in pairs(changed)do
      if n>0 and count>limit then return nil,'building-capacity'end
    end
  end end
  return delta
end
function M:publish(delta,map)
  self.total=self.total+delta.total;self.map=map
  for k,n in pairs(delta.cells)do add(self.cells,k,n)end
  for k,n in pairs(delta.counts)do add(self.counts,k,n)end
  for g,values in pairs(delta.limits)do
    local limits=self.limits[g] or {};self.limits[g]=limits
    for k,n in pairs(values)do add(limits,k,n)end
  end
end
return M
