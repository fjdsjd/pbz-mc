local D=require('rules.block_directions')
local blocks=require('content.blocks')
local M={}
local function family(record)return record and (blocks.get(record.content_id) or {}).family end
local function props(record)return record and record.properties or {}end
local function copy(t)local out={};for k,v in pairs(t or {})do out[k]=v end;return out end
local function along(a,b)return a==b or a==D.opposite(b)end
function M.placement(def,position,hit,direction)
  local p=copy(def.defaults);local normal=hit.ImpactNormal
  local forward=D.from_yaw(math.deg(math.atan(direction.Y,direction.X)))
  local face=math.abs(normal.Z)>.5 and (normal.Z>0 and 'up' or 'down')
    or D.from_yaw(math.deg(math.atan(normal.Y,normal.X)))
  if p.axis then p.axis=require('rules.block_properties').axis(normal)end
  local half=(face=='down' or (face~='up' and hit.ImpactPoint.Z>position.z)) and 'top' or 'bottom'
  if def.family=='slab'then p.type=half end
  if p.half=='bottom'then p.half=half end
  if p.facing then
    p.facing=forward
    if def.family=='button'then
      p.face=face=='up' and 'floor' or face=='down' and 'ceiling' or 'wall'
      if p.face=='wall'then p.facing=face end
    elseif def.family=='trapdoor'then
      p.facing=(face=='up' or face=='down') and D.opposite(forward) or face
    elseif def.family==nil then p.facing=D.opposite(forward)end
  end
  return p
end
function M.can_merge(record,name,n)
  if not record or record.content_id~=name then return false end
  local t=props(record).type or 'bottom'
  return (t=='bottom' and n.Z>.5) or (t=='top' and n.Z<-.5)
end
local function sturdy(r)
  if not r then return false end
  if r.native_terrain then return not r.pending end
  local d=blocks.get(r.content_id)
  return d and (d.full_cube or d.family=='slab' and props(r).type=='double')
end
local function stairs(p,near)
  local facing=p.facing
  local function different(other)
    return family(other)~='stairs' or props(other).facing~=facing or props(other).half~=p.half
  end
  for i,dir in ipairs({facing,D.opposite(facing)})do
    local neighbor=near(dir);local q=props(neighbor)
    if family(neighbor)=='stairs' and q.half==p.half and not along(q.facing,facing)
        and different(near(i==1 and D.opposite(q.facing) or q.facing))then
      return (i==1 and 'outer_' or 'inner_')..(q.facing==D.counterclockwise(facing) and 'left' or 'right')
    end
  end
  return 'straight'
end
function M.connected(record,near)
  local kind=family(record);local p=copy(record.properties or blocks.get(record.content_id).defaults)
  if kind=='stairs'then p.shape=stairs(p,near)
  elseif kind=='gate'then
    local side=D.clockwise(p.facing);p.in_wall=family(near(side))=='wall' or family(near(D.opposite(side)))=='wall'
  elseif kind=='wall' or kind=='fence' or kind=='pane'then
    local high=kind=='wall' and sturdy(near('up'))
    for _,dir in ipairs(D.horizontal)do
      local neighbor=near(dir);local k=family(neighbor)
      local compatible=k==kind
      if compatible and kind=='fence'then
        compatible=(record.content_id=='pbzmc:nether_brick_fence')==(neighbor.content_id=='pbzmc:nether_brick_fence')
      end
      local gate=k=='gate' and not along(props(neighbor).facing or 'north',dir)
      local joins=compatible or sturdy(neighbor) or gate and kind~='pane'
      p[dir]=kind=='wall' and (joins and (high and 'tall' or 'low') or 'none') or not not joins
    end
    if kind=='wall'then
      local n,s,e,w=p.north~='none',p.south~='none',p.east~='none',p.west~='none'
      p.up=not ((n and s and not e and not w) or (e and w and not n and not s)) or high
    end
  end
  return p
end
function M.adapts(k)return k=='fence' or k=='pane' or k=='wall' or k=='stairs' or k=='gate' end
return M
