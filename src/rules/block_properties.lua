-- Stable block-state values only; no host transforms or pointers are persisted.
local M={}
local enums={axis={x=true,y=true,z=true},facing={east=true,west=true,north=true,south=true,up=true,down=true},
 half={lower=true,upper=true},hinge={left=true,right=true},mode={compare=true,subtract=true},
 face={floor=true,wall=true,ceiling=true},type={normal=true,sticky=true},
 east={none=true,side=true,up=true},west={none=true,side=true,up=true},north={none=true,side=true,up=true},south={none=true,side=true,up=true}}
enums.half.top=true;enums.half.bottom=true
enums.type.top=true;enums.type.bottom=true;enums.type.double=true
enums.shape={straight=true,inner_left=true,inner_right=true,outer_left=true,outer_right=true}
for _,side in ipairs({'north','south','east','west'})do
  enums[side][true]=true;enums[side][false]=true;enums[side].low=true;enums[side].tall=true
end
local booleans={open=true,powered=true,lit=true,extended=true,locked=true,falling=true,short=true,dot=true,
  waterlogged=true,in_wall=true,up=true,conditional=true,auto=true,track_output=true}
local ranges={power={0,15},delay={1,4},level={0,7},signal={0,15},output={0,15},wall_inset={0,100},success_count={0,2147483647}}
function M.validate(value)
  if value==nil then return true end
  assert(type(value)=='table','invalid-block-properties')
  for key,v in pairs(value)do
    if enums[key]then assert(enums[key][v],'invalid-block-property:'..key)
    elseif key=='spawn_egg' then assert(require('content.summon_mobs').egg(v),'invalid-block-property:spawn_egg')
    elseif key=='command' then assert(type(v)=='string' and #v<=130000 and require('rules.commands.syntax').utf16_length(v)<=32500 and not v:find('%z'),'invalid-block-command')
    elseif key=='last_output' then assert(type(v)=='string' and #v<=2048 and not v:find('%z'),'invalid-command-output')
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
