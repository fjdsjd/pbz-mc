-- Stable block-state values only; no host transforms or pointers are persisted.
local M={}
local enums={axis={x=true,y=true,z=true},facing={east=true,west=true,north=true,south=true,up=true,down=true},
 half={lower=true,upper=true},hinge={left=true,right=true},mode={compare=true,subtract=true},
 face={floor=true,wall=true,ceiling=true},type={normal=true,sticky=true},
 east={none=true,side=true,up=true},west={none=true,side=true,up=true},north={none=true,side=true,up=true},south={none=true,side=true,up=true}}
local booleans={open=true,powered=true,lit=true,extended=true,locked=true,falling=true,short=true,dot=true}
local ranges={power={0,15},delay={1,4},level={0,7},signal={0,15},output={0,15}}
function M.validate(value)
  if value==nil then return true end
  assert(type(value)=='table','invalid-block-properties')
  for key,v in pairs(value)do
    if enums[key]then assert(enums[key][v],'invalid-block-property:'..key)
    elseif booleans[key]then assert(type(v)=='boolean','invalid-block-property:'..key)
    elseif ranges[key]then local r=ranges[key];assert(type(v)=='number' and v%1==0 and v>=r[1] and v<=r[2],'invalid-block-property:'..key)
    else error('unknown-block-property:'..tostring(key))end
  end
  return true
end
function M.copy(value)
  M.validate(value)
  if not value then return nil end
  local result={};for k,v in pairs(value)do result[k]=v end;return result
end
function M.equal(a,b)
  if a==nil or b==nil then return a==b end
  M.validate(a);M.validate(b)
  for k,v in pairs(a)do if b[k]~=v then return false end end
  for k,v in pairs(b)do if a[k]~=v then return false end end
  return true
end
function M.axis(normal)
  local x,y,z=math.abs(normal.X),math.abs(normal.Y),math.abs(normal.Z)
  -- Minecraft Y is vertical; PBZ uses Z vertically and Y for MC's Z axis.
  if z>=x and z>=y then return 'y' end
  return x>=y and 'x' or 'z'
end
return M
