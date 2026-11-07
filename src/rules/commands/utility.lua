local S=require('rules.commands.syntax')
local catalogue=require('content.command_catalogue')
local M={}
local function selected(e,raw,c)
 local list=e:select(raw or '@s',c,false,true);assert(#list>0,'no-players-found');return list
end
local function text(raw)
 if raw:sub(1,1)=='{' or raw:sub(1,1)=='[' or raw:sub(1,1)=='"'then
  local value=S.snbt(raw)
  local function render(v)
   if type(v)=='string'then return v end
   assert(type(v)=='table','invalid-text-component')
   local parts={}
   if #v>0 then for _,child in ipairs(v)do parts[#parts+1]=render(child)end
   else
    assert(v.text or v.translate,'unsupported-text-component')
    parts[#parts+1]=v.text or v.translate
    for _,child in ipairs(v.extra or {})do parts[#parts+1]=render(child)end
   end
   return table.concat(parts)
  end
  return render(value)
 end
 return raw
end
function M.help(e,a)
 if a[1]then local row=assert(catalogue.by_id[a[1]],'unknown-command');return #row.syntax,row.usage,true end
 local names={};for _,name in ipairs(catalogue.roots)do if e.handlers[catalogue.aliases[name] or name]then names[#names+1]=name end end
 return #names,table.concat(names,' ')
end
function M.version(e,a)
 assert(not a[1],'version-extra-arguments')
 return 1,e:call('version'),true
end
function M.time(e,a)
 assert(a[1]=='query'and a[2]=='gametime'and not a[3],'time-clock-system-unavailable:only-query-gametime')
 local value=e:call('game_time')%2147483647
 return value,'gametime = '..value,true
end
function M.list(e,a,c)
 local names={};for _,p in ipairs(selected(e,'@a',c))do names[#names+1]=p.name end;return #names,table.concat(names,', ')
end
function M.gamemode(e,a,c)
 local mode=({['0']='survival',['1']='creative',['2']='adventure',['3']='spectator'})[a[1]] or a[1]
 assert(require('rules.game_mode').valid(mode),'game-mode-unavailable:'..tostring(mode))
 local found=selected(e,a[2],c);assert(not a[3],'gamemode-extra-arguments')
 for _,p in ipairs(found)do e:call('game_mode',p,mode)end;return #found,'游戏模式 '..mode
end
function M.give(e,a,c)
 local list=selected(e,a[1],c);local id=S.id((assert(a[2],'item-required')));local count=S.number(a[3] or 1,1,2304,true)
 assert(not a[4],'give-extra-arguments');for _,p in ipairs(list)do e:call('give',p,id,count)end
 return #list,'已给予 '..id..' ×'..count
end
function M.clear(e,a,c)
 local list=selected(e,a[1],c);local id=a[2] and S.id(a[2]);local count=a[3] and S.number(a[3],0,2147483647,true)
 assert(not a[4],'clear-extra-arguments');local removed=0
 for _,p in ipairs(list)do removed=removed+e:call('clear_items',p,id,count)end
 return removed,'清理物品 '..removed
end
function M.item(e,a,c)
 assert(a[1]=='replace' and a[2]=='entity','item-operation-unavailable')
 local targets=e:select(a[3],c);assert(#targets>0,'no-entities-found');local slot=a[4]
 if a[5]=='with'then
  local id=S.id(a[6]);local count=S.number(a[7] or 1,1,64,true);assert(not a[8],'item-extra-arguments')
  for _,target in ipairs(targets)do e:call('replace_item',target,slot,id,count)end
 else error('item-source-unavailable',0)end
 return #targets
end
function M.say(e,a,c)
 local value=table.concat(a,' ');assert(#value>0,'message-required');e:call('message','chat',value,c);return 1,value
end
function M.me(e,a,c)return M.say(e,a,c)end
function M.msg(e,a,c)
 local found=selected(e,a[1],c);local value=table.concat(a,' ',2);assert(#value>0,'message-required')
 e:call('message','chat',value,c);return #found,value
end
function M.teammsg(e,a,c)
 local member=e:state().members[c.executor];assert(member,'executor-has-no-team');return M.say(e,a,c)
end
function M.tellraw(e,a,c)
 local found=selected(e,a[1],c);local message=text(table.concat(a,' ',2));e:call('message','chat',message,c);return #found,message
end
function M.title(e,a,c)
 local found=selected(e,a[1],c);local kind=a[2]
 assert(kind=='title' or kind=='subtitle' or kind=='actionbar' or kind=='clear' or kind=='reset' or kind=='times','invalid-title-action')
 if kind=='times'then e:call('title_times',S.number(a[3],0,2147483647,true),S.number(a[4],0,2147483647,true),S.number(a[5],0,2147483647,true))
 else e:call('message',kind,(kind=='clear' or kind=='reset') and '' or text(table.concat(a,' ',3)),c)end
 return #found
end
local rules={send_command_feedback={true,'bool'},
 max_command_sequence_length={65536,'int',1,65536},max_command_forks={65536,'int',1,65536},max_block_modifications={32768,'int',1,32768}}
function M.gamerule(e,a)
 local id=(a[1] or ''):gsub('^minecraft:','');local spec=assert(rules[id],'gamerule-has-no-host-implementation:'..id)
 if not a[2]then local value=e:state().rules[id];if value==nil then value=spec[1]end;return type(value)=='boolean' and (value and 1 or 0) or value,id..' = '..tostring(value),true end
 assert(not a[3],'gamerule-extra-arguments');local value
 if spec[2]=='bool'then assert(a[2]=='true' or a[2]=='false','boolean-required');value=a[2]=='true'
 else value=S.number(a[2],spec[3],spec[4],true)end
 e:edit(function(s)s.rules[id]=value end);return 1,id..' = '..tostring(value)
end
function M.random(e,a)
 local operation=a[1];assert(operation=='value' or operation=='roll','random-sequence-operation-unavailable')
 local lo,hi=(a[2] or ''):match('^(.-)%.%.(.-)$');lo=S.number(lo,-2147483648,2147483647,true);hi=S.number(hi,lo,2147483647,true)
 assert(not a[3],'seeded-random-sequences-unavailable');local n=math.random(lo,hi);return n,tostring(n),true
end
function M.trigger(e,a,c)
 local name=a[1];local objective=e:state().objectives[name]
 assert(objective and objective.criteria=='trigger' and objective.enabled and objective.enabled[c.executor],'trigger-not-enabled')
 local op=a[2] or 'add';assert(op=='add' or op=='set','invalid-trigger-operation')
 local value=S.number(a[3] or 1,-2147483648,2147483647,true)
 return e:edit(function(s)
  local values=s.scores[c.executor] or {};s.scores[c.executor]=values
  values[name]=op=='set' and value or ((values[name] or 0)+value+2147483648)%4294967296-2147483648
  s.objectives[name].enabled[c.executor]=nil;return values[name]
 end),nil,true
end
function M.function_(e,a,c)
 local source=e:call('function_lines',S.id((assert(a[1],'function-required'))))
 assert(not a[2],'function-macros-unavailable');local ctx=e.copy(c);ctx.function_call={};local successes=0
 for _,line in ipairs(source)do
  e:spend();local result=e:dispatch(line,ctx)
  if result.success then successes=successes+1 end
  if ctx.function_call.returned then return ctx.function_call.value,nil,ctx.function_call.success end
 end
 return successes
end
M['function']=M.function_;M.function_=nil
M['return']=function(e,a,c)
 assert(c.function_call,'return-outside-function')
 local value,success
 if a[1]=='run'then local r=e:dispatch(table.concat(a,' ',2),c);value,success=r.result,r.success
 elseif a[1]=='fail'then value,success=0,false
 else value,success=S.number(a[1],-2147483648,2147483647,true),true end
 c.function_call.returned=true;c.function_call.value=value;c.function_call.success=success;return value,nil,success
end
function M.schedule(e,a,c)
 if a[1]=='clear'then return e:call('clear_schedule',S.id(a[2]))end
 assert(a[1]=='function','invalid-schedule-action');local number,unit=(a[3] or ''):match('^([%d.]+)([dst]?)$')
 local ticks=math.max(1,math.floor(S.number(number,0,1e9)*(unit=='s' and 20 or unit=='d' and 24000 or 1)+.5))
 local mode=a[4] or 'replace';assert(mode=='replace' or mode=='append','invalid-schedule-mode')
 e:call('schedule',S.id(a[2]),ticks,mode);return ticks
end
function M.stopwatch(e,a)
 local op,id=a[1],S.id((assert(a[2],'stopwatch-id-required')));e.watches=e.watches or {};local t=e.host:wall_clock()
 if op=='create'then assert(not e.watches[id],'stopwatch-exists');e.watches[id]=t;return 1 end
 assert(e.watches[id],'unknown-stopwatch')
 if op=='restart'then e.watches[id]=t;return 1
 elseif op=='remove'then e.watches[id]=nil;return 1
 elseif op=='query'then local value=(t-e.watches[id])*S.number(a[3] or 1);return value<0 and math.ceil(value)or math.floor(value),tostring(value),true end
 error('invalid-stopwatch-action',0)
end
function M.compute(e,a,c)
 local index
 if a[1]=='default'then index=2
 elseif a[1]=='entity'then e:select(a[2],c,true);index=3
 elseif a[1]=='block'then local _,nexti=S.position(a,2,c);index=nexti
 else error('compute-context-required:default|block|entity',0)end
 local kind=a[index];assert(kind=='integer'or kind=='float','compute-type-required:integer|float')
 local n=S.number(a[index+1]);assert(not a[index+3],'compute-provider-unavailable')
 if kind=='integer'then assert(n%1==0 and not a[index+2],'integer-required');return n,tostring(n),true end
 return math.floor(n*S.number(a[index+2]or 1)),tostring(n),true
end
return M
