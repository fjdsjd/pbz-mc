local syntax=require('rules.commands.syntax')
local state=require('storage.state')
local M={}
local allowed={x=true,y=true,z=true,dx=true,dy=true,dz=true,distance=true,limit=true,sort=true,
 type=true,name=true,tag=true,team=true,scores=true,gamemode=true,level=true,x_rotation=true,y_rotation=true,nbt=true,predicate=true}
function M.parse(raw)
 assert(type(raw)=='string'and #raw>0,'selector-required')
 local kind,body=raw:match('^@([a-z])(%b[])$')
 if not kind then kind=raw:match('^@([a-z])$')end
 if not kind then assert(raw:sub(1,1)~='@','invalid-selector');return {name=syntax.string(raw)}end
 assert(('separn'):find(kind,1,true),'unknown-selector:'..kind)
 local out={kind=kind,filters={}}
 if body and #body>2 then
  for _,v in ipairs(syntax.split(body:sub(2,-2),','))do
   local key,value=v:match('^%s*([%w_]+)%s*=%s*(.-)%s*$');assert(key and allowed[key],'unknown-selector-filter:'..tostring(key))
   out.filters[#out.filters+1]={key=key,value=value}
  end
 end
 return out
end
local function subset(pattern,value)
 if type(pattern)~='table'then return pattern==value end
 if type(value)~='table'or state.json_kind(pattern)~=state.json_kind(value)then return false end
 if state.json_kind(pattern)=='array'then
  if #pattern==0 then return #value==0 end
  for _,expected in ipairs(pattern)do
   local found=false;for _,actual in ipairs(value)do if subset(expected,actual)then found=true;break end end
   if not found then return false end
  end
  return true
 end
 for k,v in pairs(pattern)do if not subset(v,value[k])then return false end end
 return true
end
M.subset=subset
local negatable={type=true,name=true,tag=true,team=true,gamemode=true,nbt=true,predicate=true}
local function range(f,n)return (not f.minimum or n>=f.minimum)and (not f.maximum or n<=f.maximum)end
local function wrap(n)return (n+180)%360-180 end
local function rotation(f,n)
 local lo=f.minimum and wrap(f.minimum)or -180;local hi=f.maximum and wrap(f.maximum)or 180;n=wrap(n)
 return lo>hi and (n>=lo or n<=hi)or lo<=hi and n>=lo and n<=hi
end
function M.select(raw,context,entities,options)
 options=options or {};local selector=M.parse(raw);local filters=selector.filters or {}
 local origin={x=context.pos.x,y=context.pos.y,z=context.pos.z};local bounds={}
 local limit=selector.kind=='s' and 1 or (selector.kind=='p' or selector.kind=='r' or selector.kind=='n') and 1 or 2147483647
 local sort=selector.kind=='p' or selector.kind=='n';sort=sort and 'nearest' or selector.kind=='r' and 'random' or 'arbitrary'
 local seen,positive={},{}
 -- Validate filters before walking candidates, including an empty world.
 for _,f in ipairs(filters)do
  local key,rawvalue=f.key,f.value;f.negate=rawvalue:sub(1,1)=='!'
  assert(not f.negate or negatable[key],'selector-negation-unavailable:'..key)
  local value=syntax.string(f.negate and rawvalue:sub(2)or rawvalue);f.value=value
  if key~='tag' and key~='type' and key~='name' and key~='team' and key~='nbt' and key~='predicate'and key~='gamemode'then
   assert(not seen[key],'duplicate-selector-filter:'..key);seen[key]=true
  end
  if (key=='type'or key=='name'or key=='team'or key=='gamemode')and not f.negate then
   assert(not positive[key],'duplicate-positive-selector-filter:'..key);positive[key]=true
  end
  if origin[key]~=nil then origin[key]=syntax.number(value)
  elseif key=='dx' or key=='dy' or key=='dz'then bounds[key:sub(2)]=syntax.number(value)
  elseif key=='limit'then limit=syntax.number(value,1,2147483647,true)
  elseif key=='sort'then assert(value=='nearest' or value=='furthest' or value=='random' or value=='arbitrary','invalid-selector-sort');sort=value
  elseif key=='distance'or key=='level'then
   assert(key~='level'or options.levels~=false,'experience-system-unavailable')
   f.minimum,f.maximum=syntax.range_bounds(value,0,nil,key=='level')
  elseif key=='x_rotation'or key=='y_rotation'then f.minimum,f.maximum=syntax.range_bounds(value,nil,nil,false,true)
  elseif key=='type'then assert(value:sub(1,1)~='#','entity-type-tags-unavailable');f.value=syntax.id(value)
  elseif key=='nbt'then f.pattern=syntax.snbt(value);assert(type(f.pattern)=='table'and state.json_kind(f.pattern)=='object','selector-nbt-compound-required')
  elseif key=='predicate'then assert(options.predicate,'predicate-system-unavailable')
  elseif key=='gamemode'then assert(value=='survival'or value=='creative'or value=='adventure'or value=='spectator','invalid-selector-gamemode')
  elseif key=='scores'then
   f.scores={};assert(value:sub(1,1)=='{'and value:sub(-1)=='}','invalid-scores-filter')
   local body=value:sub(2,-2)
   if not body:match('^%s*$')then for _,entry in ipairs(syntax.split(body,','))do
    local obj,rawrange=entry:match('^%s*([%w_.+%-]+)%s*=%s*(.-)%s*$');assert(obj and not f.scores[obj],'invalid-or-duplicate-score-filter')
    local lo,hi=syntax.range_bounds(rawrange,-2147483648,2147483647,true);f.scores[obj]={minimum=lo,maximum=hi}
   end end
  end
 end
 local result={}
 for _,e in ipairs(entities)do
  local accept=e.alive~=false
  if selector.name then accept=accept and (e.name==selector.name or e.id==selector.name)
  elseif selector.kind=='s'then accept=accept and e.id==context.executor
  elseif selector.kind=='a' or selector.kind=='p' or selector.kind=='r'then accept=accept and e.player end
  local dx,dy,dz=e.pos.x-origin.x,e.pos.y-origin.y,e.pos.z-origin.z;local distance=dx*dx+dy*dy+dz*dz
  if next(bounds)then
   local radius=e.radius or .3;local height=e.height or 1.8
   for _,axis in ipairs({'x','y','z'})do
    local d=bounds[axis] or 0;local lo=origin[axis]+math.min(0,d);local hi=origin[axis]+math.max(0,d)+1
    local bottom=e.pos[axis]-(axis~='y' and radius or 0);local top=e.pos[axis]+(axis=='y' and height or radius)
    accept=accept and bottom<hi and top>lo
   end
  end
  for _,f in ipairs(filters)do
   local key,value,match=f.key,f.value
   if key=='distance'then match=range(f,math.sqrt(distance))
   elseif key=='type'then match=e.type==value
   elseif key=='name'then match=e.name==value
   elseif key=='tag'then match=value=='' and not next(e.tags or {}) or (e.tags or {})[value]==true
   elseif key=='team'then match=(e.team or '')==value
   elseif key=='gamemode'then match=e.player and e.gamemode==value
   elseif key=='level'then match=e.player and range(f,e.level or 0)
   elseif key=='x_rotation'then match=rotation(f,e.pitch or 0)
   elseif key=='y_rotation'then match=rotation(f,e.yaw or 0)
   elseif key=='nbt'then match=subset(f.pattern,e.data or {})
   elseif key=='predicate'then match=options.predicate(value,e)
   elseif key=='scores'then
    match=true;for obj,bounds in pairs(f.scores)do
     local score=e.scores and e.scores[obj];match=match and score~=nil and range(bounds,score)
    end
   end
   if key=='gamemode'or key=='level'then accept=accept and e.player end
   if match~=nil then if f.negate then match=not match end;accept=accept and match end
  end
  if accept then result[#result+1]={entity=e,distance=distance}end
 end
 if sort=='nearest' or sort=='furthest'then
  table.sort(result,function(a,b)if a.distance==b.distance then return a.entity.id<b.entity.id end
   if sort=='nearest'then return a.distance<b.distance end;return a.distance>b.distance end)
 elseif sort=='random'then for i=#result,2,-1 do local j=(options.random or math.random)(i);result[i],result[j]=result[j],result[i]end end
 local found={};for i=1,math.min(#result,limit)do found[i]=result[i].entity end;return found
end
return M
