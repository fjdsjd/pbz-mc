local syntax=require('rules.commands.syntax')
local select_entities=require('rules.commands.selectors')
local state=require('storage.state')
local M={};M.__index=M
local function copy(value)local result={};for k,v in pairs(value)do result[k]=v end;return result end
M.copy=copy
function M.new(host)
 local self=setmetatable({host=host,handlers={},serial=0,max_operations=65536,max_depth=32},M)
 for _,name in ipairs({'entities','scores','world','data','execute','utility','bossbar','presentation','gameplay'})do
  for verb,handler in pairs(require('rules.commands.'..name))do
   if verb:sub(1,1)~='_'then
    assert(not self.handlers[verb],'duplicate-command:'..verb);self.handlers[verb]=handler
   end
  end
 end
 return self
end
function M:state()
 return self.host:command_state() or {scores={},objectives={},teams={},members={},tags={},storage={},rules={}}
end
function M:edit(fn)
 local expected=self:state();local candidate=state.clone(expected);local value=fn(candidate)
 state.validate_value(candidate)
 assert(#require('storage.canonical_json')(candidate)<=2*1024*1024,'command-data-limit')
 local ok,why=self.host:save_command_state(candidate,expected);assert(ok,why);return value
end
function M:select(raw,context,single,players)
 local entities=self.host.entities:list();local meta=self:state();local prepared={}
 for _,e in ipairs(entities)do
  local target=copy(e);target.tags=meta.tags[e.id] or e.tags or {};target.team=meta.members[e.id]
  if raw:find('nbt%s*=')then
   local data,why=self.host.entities:read_data(e);assert(data,why or 'entity-data-unavailable');target.data=data
  end
  target.scores=meta.scores[e.id] or meta.scores[e.name] or {};prepared[#prepared+1]=target
 end
 local found=select_entities.select(raw,context,prepared,{levels=self.host.entities.supports_level~=false})
 if players then for _,e in ipairs(found)do assert(e.player,'target-must-be-player')end end
 if single then assert(#found==1,'expected-one-entity')end
 return found
end
function M:mutate(method,e,...)
 local fn=assert(self.host.entities[method],'entity-operation-unavailable:'..method)
 local ok,why=fn(self.host.entities,e,...);assert(ok,why or 'entity-operation-failed')
 if self.host.entities.invalidate then self.host.entities:invalidate()end;return why
end
function M:call(method,...)
 local fn=assert(self.host[method],'host-operation-unavailable:'..method)
 local value,why=fn(self.host,...);assert(value~=false and value~=nil,why or 'host-operation-failed');return value,why
end
function M:score_holder(raw,context,multiple)
 if raw=='*' then
  local all={};for name in pairs(self:state().scores)do all[#all+1]=name end;table.sort(all);return all
 end
 if raw:sub(1,1)=='@'then
  local out={};for _,e in ipairs(self:select(raw,context,not multiple))do out[#out+1]=e.id end
  return out
 end
 assert(#raw>0 and #raw<=40,'invalid-score-holder');return {syntax.string(raw)}
end
function M:spend(n)
 assert(self.execution,'command-execution-context-missing')
 self.execution.operations=self.execution.operations+(n or 1)
 assert(self.execution.operations<=self.max_operations,'command-execution-budget-exceeded')
 if self.host.checkpoint then self.host:checkpoint()end
end
function M:dispatch(raw,context)
 self:spend();self.execution.depth=self.execution.depth+1
 assert(self.execution.depth<=self.max_depth,'command-recursion-limit')
 local args,starts=syntax.tokens(raw:gsub('^%s*/',''))
 local verb=assert(table.remove(args,1),'empty-command')
 assert(verb:match('^[a-z_][a-z0-9_%-]*$'),'invalid-command-name')
 local catalogue=require('content.command_catalogue')
 local canonical=(catalogue.aliases or {})[verb] or verb
 local handler=self.handlers[canonical]
 if not handler then
  local registered=(catalogue.by_id or {})[verb]
  local unmapped={difficulty=true,spawnpoint=true,setworldspawn=true,defaultgamemode=true}
  error(registered and (unmapped[verb]and 'command-unsupported-host-mapping:'or 'command-requires-unavailable-system:')..verb or 'unknown-command:'..verb,0)
 end
 local value,message,success,count=handler(self,args,context)
 self.execution.depth=self.execution.depth-1
 assert(type(value)=='number' and value==value and math.abs(value)<math.huge,'invalid-command-result')
 success=success==nil and value~=0 or success==true
 return {result=value,success=success,success_count=count or (success and 1 or 0),message=message or (canonical..': '..value)}
end
function M:run(raw,context)
 assert(not self.execution,'command-reentry')
 self.serial=self.serial+1;self.host.entities:begin_command(self.serial)
 self.execution={operations=0,depth=0}
 local ok,result=pcall(self.dispatch,self,raw,context or self.host:context())
 local used=self.execution.operations;self.execution=nil
 if not ok then
  result={success=false,success_count=0,result=0,error=tostring(result):gsub('^.-%.lua:%d+:%s*','')}
  result.message='命令失败 '..result.error
 end
 result.operations=used;return result
end
function M:suggestions(text,cursor)
 local catalogue=require('content.command_catalogue')
 local head=text:sub(1,cursor or #text):gsub('^/','');local root,prefix=head:match('^(%S+)%s+(.*)$')
 local values={}
 if not root then
  for _,name in ipairs(catalogue.roots)do if name:sub(1,#head)==head then values[#values+1]='/'..name..' 'end end
 else
  local canonical=catalogue.aliases[root]or root
  local last=prefix:match('([^%s]*)$')or '';local base='/'..head:sub(1,#head-#last)
  local ok,args=pcall(syntax.tokens,prefix)
  local at=ok and (#args+(prefix:match('%s$')and 1 or 0))or 1;if at<1 then at=1 end
  local targets={'@s','@p','@a','@e','@n','@r'};local choices={}
  if canonical=='gamemode'then choices=at==1 and {'survival','creative'}or targets
  elseif canonical=='give'then choices=at==1 and targets or at==2 and self.host:completion_ids('give')or {'1','64'}
  elseif canonical=='summon'then choices=at==1 and self.host:completion_ids('summon')or {'~','^'}
  elseif canonical=='setblock'or canonical=='fill'then
   local offset=canonical=='setblock'and 4 or 7
   choices=at<offset and {'~','^'}or at==offset and self.host:completion_ids('setblock')or {'replace','destroy','keep','outline','hollow'}
  elseif canonical=='effect'then
   choices=at==1 and {'give','clear'}or at==2 and targets or at==3 and {'minecraft:regeneration','minecraft:resistance','minecraft:fire_resistance','minecraft:water_breathing','minecraft:speed','minecraft:slowness','minecraft:absorption','minecraft:instant_health','minecraft:instant_damage','minecraft:poison','minecraft:wither','minecraft:strength','minecraft:weakness'}or {'1','30','60'}
  else
   -- Literal branches come from the pinned Brigadier grammar. Multi-component
   -- position arguments occupy three input tokens. The syntax cache is reused.
   self.syntax_cache=self.syntax_cache or {}
   if not self.syntax_cache[canonical]then
    local rows={};local row=catalogue.by_id[canonical]
    for _,form in ipairs(row and row.syntax or {})do
     local pattern={}
     for word in form:gmatch('%S+')do
      if word=='->'or word=='...'then break end
      if #pattern>0 or word:sub(1,1)~='/'then pattern[#pattern+1]=word
       if word:match('^<.*[Pp]os>$')or word=='<begin>'or word=='<end>'then pattern[#pattern+1]='<coordinate>';pattern[#pattern+1]='<coordinate>'end
      end
     end
     rows[#rows+1]=pattern
    end
    self.syntax_cache[canonical]=rows
   end
   local seen={}
   for _,pattern in ipairs(self.syntax_cache[canonical])do
    local match=ok
    for i=1,at-1 do if not pattern[i]or pattern[i]:sub(1,1)~='<'and pattern[i]~=args[i]then match=false;break end end
    local word=match and pattern[at]
    if word and word:sub(1,1)~='<'then seen[word]=true
    elseif word and(word:find('arget')or word=='<entities>'or word=='<entity>')then for _,v in ipairs(targets)do seen[v]=true end
    elseif word=='<objective>'then for v in pairs(self:state().objectives)do seen[v]=true end
    elseif word=='<team>'then for v in pairs(self:state().teams)do seen[v]=true end end
   end
   for v in pairs(seen)do choices[#choices+1]=v end
  end
  for _,v in ipairs(choices)do if v:sub(1,#last)==last then values[#values+1]=base..v end end
 end
 table.sort(values);return values,0
end
return M
