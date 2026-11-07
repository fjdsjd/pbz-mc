-- Persistent custom bars, independent from PBZ's native boss encounter UI.
local S=require('rules.commands.syntax')
local encode=require('storage.canonical_json')
local M={}
local colors={pink=true,blue=true,red=true,green=true,yellow=true,purple=true,white=true}
local styles={progress=true,notched_6=true,notched_10=true,notched_12=true,notched_20=true}
local function count(t)local n=0;for _ in pairs(t or {})do n=n+1 end;return n end
local function name(raw)
 assert(type(raw)=='string'and raw~='','bossbar-name-required')
 local value=S.snbt(raw)
 local function plain(v,depth)
  assert(depth<16,'bossbar-name-too-deep')
  if type(v)=='string'then return v end
  assert(type(v)=='table','bossbar-text-component-required')
  local out={}
  if #v>0 then for _,child in ipairs(v)do out[#out+1]=plain(child,depth+1)end
  else
   for key in pairs(v)do assert(key=='text'or key=='extra','bossbar-text-component-unsupported:'..tostring(key))end
   assert(type(v.text)=='string','bossbar-text-component-required');out[1]=v.text
   for _,child in ipairs(v.extra or {})do out[#out+1]=plain(child,depth+1)end
  end
  return table.concat(out)
 end
 local result=plain(value,0)
 assert(utf8.len(result)and utf8.len(result)<=256 and not result:find('[%z\1-\31\127]'),'bossbar-name-invalid-or-too-long')
 return result
end
local function lookup(e,id)return assert((e:state().bossbars or {})[id],'unknown-bossbar:'..id)end
function M._store(e,id,field,value)
 assert(field=='value'or field=='max','bossbar-store-field-invalid');lookup(e,id)
 -- execute store uses Java int conversion, unlike /bossbar set's >=0 parser.
 value=math.floor(value);value=math.max(-2147483648,math.min(2147483647,value))
 e:edit(function(s)assert(s.bossbars and s.bossbars[id],'bossbar-removed')[field]=value end)
end
function M.bossbar(e,a,c)
 local action=a[1]
 if action=='list'then
  assert(not a[2],'bossbar-extra-arguments');local ids={}
  for id in pairs(e:state().bossbars or {})do ids[#ids+1]=id end;table.sort(ids)
  return #ids,table.concat(ids,', '),true
 end
 local id=S.id((assert(a[2],'bossbar-id-required')))
 if action=='add'then
  local title=name(table.concat(a,' ',3))
  e:edit(function(s)
   s.bossbars=s.bossbars or {};assert(not s.bossbars[id],'bossbar-already-exists')
   assert(count(s.bossbars)<64,'bossbar-count-limit')
   s.bossbars[id]={name=title,color='white',style='progress',value=0,max=100,visible=true,players={}}
  end)
  return count(e:state().bossbars),'已创建 '..id,true
 end
 local bar=lookup(e,id)
 if action=='remove'then
  assert(not a[3],'bossbar-extra-arguments');e:edit(function(s)s.bossbars[id]=nil end)
  return count(e:state().bossbars),'已移除 '..id,true
 end
 local field=a[3]
 if action=='get'then
  assert(not a[4],'bossbar-extra-arguments')
  assert(field=='max'or field=='value'or field=='visible'or field=='players','bossbar-get-field-invalid')
  local value=field=='players'and count(bar.players)or field=='visible'and(bar.visible and 1 or 0)or bar[field]
  return value,id..' '..field..' = '..value,true
 end
 assert(action=='set','usage:bossbar add|remove|list|set|get')
 local value
 if field=='name'then value=name(table.concat(a,' ',4))
 elseif field=='players'then
  assert(not a[5],'bossbar-extra-arguments');value={}
  if a[4]then for _,player in ipairs(e:select(a[4],c,false,true))do value[player.id]=true end end
 elseif field=='color'then value=assert(a[4],'bossbar-color-required');assert(colors[value],'invalid-bossbar-color')
 elseif field=='style'then value=assert(a[4],'bossbar-style-required');assert(styles[value],'invalid-bossbar-style')
 elseif field=='visible'then assert(a[4]=='true'or a[4]=='false','boolean-required');value=a[4]=='true'
 elseif field=='value'or field=='max'then value=S.number(a[4],field=='max'and 1 or 0,2147483647,true)
 else error('bossbar-set-field-invalid:'..tostring(field),0)end
 if field~='name'then assert(not a[5],'bossbar-extra-arguments')end
 assert(type(value)=='table'and encode(bar[field])~=encode(value)or type(value)~='table'and bar[field]~=value,'bossbar-value-unchanged')
 e:edit(function(s)assert(s.bossbars[id],'bossbar-removed')[field]=value end)
 local result=field=='players'and count(value)or field=='value'and value or field=='max'and value or 0
 return result,id..' '..field..' 已更新',true
end
return M
