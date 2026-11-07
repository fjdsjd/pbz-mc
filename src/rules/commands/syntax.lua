-- Bounded command/SNBT parsing. Parsed text is data and is never evaluated as Lua.
local M={max_length=32767}
function M.utf16_length(text)
 assert(type(text)=='string'and utf8.len(text),'invalid-command-utf8')
 local units=0;for _,point in utf8.codes(text)do units=units+(point>65535 and 2 or 1)end;return units
end
function M.tokens(text)
 assert(type(text)=='string' and #text<=M.max_length*4 and M.utf16_length(text)<=M.max_length,'command-too-long')
 local tokens,starts={},{};local start,quote,escape,stack
 stack={}
 for i=1,#text do
  local c=text:sub(i,i)
  if not start and not c:match('%s')then start=i end
  if quote then
   if escape then escape=false elseif c=='\\'then escape=true elseif c==quote then quote=nil end
  elseif c=='"' or c=="'"then quote=c
  elseif c=='[' or c=='{'then stack[#stack+1]=c
  elseif c==']' or c=='}'then
   assert(table.remove(stack)==(c==']' and '[' or '{'),'unmatched-bracket-at-'..i)
  elseif c:match('%s') and #stack==0 and start then
   tokens[#tokens+1]=text:sub(start,i-1);starts[#starts+1]=start;start=nil
  end
 end
 assert(not quote and #stack==0,'unfinished-quote-or-bracket')
 if start then tokens[#tokens+1]=text:sub(start);starts[#starts+1]=start end
 return tokens,starts
end
function M.split(text,separator)
 local out={};local from=1;local quote,escape;local stack={}
 for i=1,#text do
  local c=text:sub(i,i)
  if quote then
   if escape then escape=false elseif c=='\\'then escape=true elseif c==quote then quote=nil end
  elseif c=='"' or c=="'"then quote=c
  elseif c=='[' or c=='{'then stack[#stack+1]=c
  elseif c==']' or c=='}'then assert(table.remove(stack)==(c==']' and '[' or '{'),'unmatched-bracket')
  elseif c==separator and #stack==0 then out[#out+1]=text:sub(from,i-1);from=i+1 end
 end
 assert(not quote and #stack==0,'unfinished-quote-or-bracket')
 out[#out+1]=text:sub(from);return out
end
function M.string(raw)
 if raw:sub(1,1)=='"' then
  local value,at,err=require('dkjson').decode(raw)
  assert(not err and type(value)=='string' and raw:sub(at):match('^%s*$'),'invalid-quoted-string')
  return value
 end
 if raw:sub(1,1)=="'"then
  assert(raw:sub(-1)=="'",'unfinished-quote');local value=raw:sub(2,-2)
  return (value:gsub('\\(.)',function(c)assert(c=="'" or c=='\\','invalid-string-escape');return c end))
 end
 return raw
end
function M.number(raw,minimum,maximum,integer)
 local n=tonumber(raw)
 assert(n and n==n and math.abs(n)<math.huge and (not minimum or n>=minimum)
  and (not maximum or n<=maximum) and (not integer or n%1==0),'invalid-number:'..tostring(raw))
 return n
end
function M.range_bounds(raw,minimum,maximum,integer,wrapped)
 assert(type(raw)=='string'and raw~='','number-range-required')
 local a,b=raw:match('^(.-)%.%.(.-)$')
 if not a then local n=M.number(raw,minimum,maximum,integer);return n,n end
 assert(a~='' or b~='','empty-number-range')
 a=a~=''and M.number(a,minimum,maximum,integer)or nil
 b=b~=''and M.number(b,minimum,maximum,integer)or nil
 assert(wrapped or not a or not b or a<=b,'inverted-number-range')
 return a,b
end
function M.range(raw,n)
 local a,b=M.range_bounds(raw)
 return (not a or n>=a)and (not b or n<=b)
end
function M.snbt(raw,depth)
 depth=depth or 0;assert(depth<16,'nbt-too-deep');raw=raw:match('^%s*(.-)%s*$')
 local first=raw:sub(1,1)
 if first=='{' or first=='['then
  local object=first=='{';assert(raw:sub(-1)==(object and '}' or ']'),'unfinished-nbt')
  local body=raw:sub(2,-2);local out=setmetatable({},{__jsontype=object and 'object' or 'array'})
  if not object then body=body:gsub('^[BIL];','')end
  if body:match('^%s*$')then return out end
  for _,v in ipairs(M.split(body,','))do
   if object then
    local quoted=v:match('^%s*(["\'])')
    local key,tail
    if quoted then
     local escaped=false;local start=v:find(quoted,1,true)
     for i=start+1,#v do
      local c=v:sub(i,i)
      if escaped then escaped=false elseif c=='\\'then escaped=true elseif c==quoted then
       key=M.string(v:sub(start,i));tail=v:sub(i+1):match('^%s*:%s*(.*)$');break
      end
     end
    else key,tail=v:match('^%s*([%w_.+%-]+)%s*:%s*(.*)$')end
    assert(key and tail and out[key]==nil,'invalid-or-duplicate-nbt-key');out[key]=M.snbt(tail,depth+1)
   else out[#out+1]=M.snbt(v,depth+1)end
  end
  return out
 end
 if first=='"' or first=="'"then return M.string(raw)end
 if raw=='true' then return true elseif raw=='false'then return false end
 local value=tonumber((raw:gsub('[bBsSlLfFdD]$','')))
 if value then return M.number(value)end
 assert(raw~='' and raw:match('^[%w_:.+/%-]+$'),'invalid-nbt-value');return raw
end
function M.block(raw)
 local name,body,nbt=raw:match('^([%w_:/.-]+)(%b[])(.*)$')
 if not name then name,nbt=raw:match('^([%w_:/.-]+)(.*)$')end
 assert(name,'invalid-block-id');local props={}
 if body then
  for _,v in ipairs(M.split(body:sub(2,-2),','))do
   local k,x=v:match('^%s*([%w_]+)%s*=%s*([%w_]+)%s*$');assert(k and props[k]==nil,'invalid-block-state')
   if x=='true' then props[k]=true elseif x=='false' then props[k]=false else props[k]=tonumber(x) or x end
  end
 end
 return name,props,nbt~='' and M.snbt(nbt) or nil
end
function M.position(args,index,context,center)
 local local_axes=args[index] and args[index]:sub(1,1)=='^';local p={};local names={'x','y','z'}
 for i=0,2 do
  local raw=assert(args[index+i],'missing-coordinate');local lead=raw:sub(1,1)
  assert((lead=='^')==local_axes,'mixed-local-coordinates')
  local relative=lead=='~' or lead=='^';local number=relative and (raw:sub(2)=='' and 0 or M.number(raw:sub(2))) or M.number(raw)
  if not relative and center and i~=1 and not raw:find('.',1,true)then number=number+.5 end
  p[names[i+1]]=number+(lead=='~' and context.pos[names[i+1]] or 0)
 end
 if local_axes then
  local yaw,pitch=math.rad(context.yaw or 0),math.rad(context.pitch or 0)
  local sy,cy,sp,cp=math.sin(yaw),math.cos(yaw),math.sin(pitch),math.cos(pitch)
  local origin=context.pos;local eye=context.anchor=='eyes' and (context.eye_height or 1.62) or 0
  p={x=origin.x+cy*p.x-sy*sp*p.y-sy*cp*p.z,
   y=origin.y+eye+cp*p.y-sp*p.z,z=origin.z+sy*p.x+cy*sp*p.y+cy*cp*p.z}
 end
 for _,n in pairs(p)do assert(math.abs(n)<=30000000,'coordinate-out-of-range')end
 return p,index+3
end
function M.id(raw,space)
 assert(type(raw)=='string','resource-id-required')
 if not raw:find(':',1,true)then raw=(space or 'minecraft')..':'..raw end
 assert(raw:match('^[a-z0-9_.%-]+:[a-z0-9_/.%-]+$'),'invalid-resource-id:'..raw)
 return raw
end
return M
