-- Save only stable boat identity and pose. Riders, native objects, velocity and
-- simulation state belong to the host service and never enter the savepoint.
local state=require('storage.state')
local json=require('dkjson')
local M={max_vehicles=128,max_coordinate=1e9}
local fields={id=true,content_id=true,world=true,x=true,y=true,z=true,yaw=true}
local function object(value)
  return type(value)=='table' and value~=json.null and state.json_kind(value)=='object'
end
local function text(value,limit)
  return type(value)=='string' and #value>0 and #value<=limit and not value:find('\0',1,true)
end
function M.validate(vehicles)
  if vehicles==nil then return true end -- saves created before boats
  assert(object(vehicles),'invalid-vehicles-map')
  local count=0
  for id,record in pairs(vehicles) do
    count=count+1;assert(count<=M.max_vehicles,'excessive-vehicle-records')
    assert(text(id,128) and object(record) and record.id==id,'invalid-vehicle-instance')
    for key in pairs(record) do assert(fields[key],'unknown-vehicle-field') end
    assert(record.content_id=='pbzmc:boat','invalid-vehicle-content')
    assert(text(record.world,1023),'invalid-vehicle-world')
    for _,axis in ipairs({'x','y','z','yaw'}) do
      local value=record[axis]
      assert(type(value)=='number' and value==value and math.abs(value)<=M.max_coordinate,
        'invalid-vehicle-transform')
    end
  end
  state.validate_value(vehicles)
  return true
end
return M
