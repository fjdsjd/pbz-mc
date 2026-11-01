local json=require('dkjson')
local M={}
function M.object(value) return setmetatable(value or {},{__jsontype='object'}) end
function M.json_kind(value)
  local mt=getmetatable(value)
  if mt and mt.__jsontype then return mt.__jsontype end
  -- Empty Lua maps mean objects here; explicit arrays retain their JSON tag.
  local key=next(value)
  return type(key)=='number' and 'array' or 'object'
end
function M.clone(value)
  if type(value)~='table' or value==json.null then return value end
  local result=setmetatable({},{__jsontype=M.json_kind(value)})
  for key,child in pairs(value) do result[key]=M.clone(child) end
  return result
end
function M.decode(raw)
  local value,position,err=json.decode(raw,1,json.null)
  assert(not err,err)
  assert(value~=nil and raw:sub(position):match('^%s*$'),'trailing-or-empty-json')
  return value
end
local function finite(n) return type(n)=='number' and n==n and math.abs(n)<math.huge end
local function object(v)
  return type(v)=='table' and v~=json.null and (not getmetatable(v) or getmetatable(v).__jsontype~='array')
end
local function json_value(value,seen,depth)
  assert(depth<64,'state-too-deep')
  local t=type(value)
  if value==json.null or t=='string' or t=='boolean' then return end
  if t=='number' then assert(finite(value),'nonfinite-state');return end
  assert(t=='table' and not seen[value],'non-json-or-cyclic-state')
  local mt=getmetatable(value)
  assert(not mt or (mt.__tojson==nil and (mt.__jsontype=='array' or mt.__jsontype=='object')),'non-json-metatable')
  seen[value]=true
  local kind=M.json_kind(value)
  local count,maximum=0,0
  for k,v in pairs(value) do
    if kind=='array' then
      assert(type(k)=='number' and k%1==0 and k>=1 and k<2^53,'invalid-json-array-key')
      count=count+1;maximum=math.max(maximum,k)
    else assert(type(k)=='string','invalid-json-object-key') end
    json_value(v,seen,depth+1)
  end
  assert(kind~='array' or count==maximum,'sparse-json-array')
  seen[value]=nil
end
function M.validate_value(value) json_value(value,{},0);return true end
function M.validate_buildings(buildings)
  assert(object(buildings),'invalid-buildings-map')
  local count=0
  for id,record in pairs(buildings) do
    count=count+1
    assert(count<=8192,'excessive-building-records')
    assert(type(id)=='string' and #id>0 and #id<=128 and object(record) and record.id==id,'invalid-instance')
    assert(type(record.content_id)=='string' and record.content_id:match('^[a-z][a-z0-9_]*:[a-z0-9_/.-]+$'),'invalid-building-content')
    assert(type(record.world)=='string' and #record.world>0 and #record.world<1024,'invalid-building-world')
    require('rules.block_properties').validate(record.properties)
    for _,axis in ipairs({'x','y','z','yaw'}) do
      assert(finite(record[axis]) and math.abs(record[axis])<=1e9,'invalid-building-transform')
    end
  end
  return true
end
function M.validate(data)
  assert(object(data) and data.schema==1,'unsupported-state-schema')
  assert(object(data.inventory) and object(data.buildings),'invalid-state-maps')
  for id,count in pairs(data.inventory) do
    assert(type(id)=='string' and id:match('^[a-z][a-z0-9_]*:[a-z0-9_/.-]+$'),'invalid-item-id')
    assert(finite(count) and count%1==0 and count>=0 and count<=2147483647,'invalid-item-count')
  end
  M.validate_buildings(data.buildings)
  M.validate_building_grids(data.building_grids)
  json_value(data,{},0)
  return true
end
function M.validate_building_grids(grids)
  if grids==nil then return true end -- legacy saves
  assert(object(grids),'invalid-building-grids')
  for world,origin in pairs(grids) do
    assert(type(world)=='string' and #world>0 and #world<1024 and object(origin),'invalid-building-grid')
    for _,axis in ipairs({'x','y','z'}) do assert(finite(origin[axis]) and math.abs(origin[axis])<=1e9,'invalid-grid-origin') end
  end
  return true
end
function M.empty() return M.object({schema=1,inventory=M.object(),buildings=M.object()}) end
return M
