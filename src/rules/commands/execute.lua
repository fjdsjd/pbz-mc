local S=require('rules.commands.syntax')
local M={}
local function fork(c)local r={};for k,v in pairs(c)do r[k]=v end;return r end
local function rotation(raw,base)
 if raw:sub(1,1)=='~'then return base+(raw:sub(2)=='' and 0 or S.number(raw:sub(2)))end
 return S.number(raw)
end
local function score(e,holder,obj,c)
 local names=e:score_holder(holder,c,false);assert(#names==1,'expected-one-score-holder')
 local state=e:state();assert(state.objectives[obj],'unknown-objective:'..obj)
 local row=state.scores[names[1]];return row and row[obj]
end
local compares={['=']=function(a,b)return a==b end,['<']=function(a,b)return a<b end,
 ['<=']=function(a,b)return a<=b end,['>']=function(a,b)return a>b end,['>=']=function(a,b)return a>=b end}
local function condition(e,a,i,c)
 local kind=a[i]
 if kind=='entity'then local n=#e:select(a[i+1],c);return n>0,i+2,n end
 if kind=='score'then
  local value=score(e,a[i+1],a[i+2],c);local op=a[i+3]
  if op=='matches'then return value~=nil and S.range(a[i+4],value),i+5 end
  local compare=assert(compares[op],'invalid-score-comparison');local other=score(e,a[i+4],a[i+5],c)
  return value~=nil and other~=nil and compare(value,other),i+6
 end
 if kind=='block'then
  local p,nexti=S.position(a,i+1,c);for k,v in pairs(p)do p[k]=math.floor(v)end
  local id,properties=S.block(a[nexti]);local actual=e:call('read_block',p);local matches=actual.id==S.id(id)
  for k,v in pairs(properties)do matches=matches and actual.properties[k]==v end
  return matches,nexti+1
 end
 if kind=='data'then
  local D=require('rules.commands.data');local target,nexti=D._accessor(e,a,i+1,c)
  local path=a[nexti];assert(path,'data-path-required')
  local count=#D._references(e,D._read(target),D._path(path),false)
  return count>0,nexti+1,count
 end
 if kind=='function'then
  local result=e:dispatch('function '..assert(a[i+1],'function-required'),c);return result.success,i+2
 end
 if kind=='dimension'then return e:call('dimension')==S.id(a[i+1]),i+2 end
 if kind=='loaded'then local p,nexti=S.position(a,i+1,c);return e.host:is_loaded(p),nexti end
 error('execute-condition-unavailable:'..tostring(kind),0)
end
local function store(e,a,i,c,result)
 local which,kind=a[i],a[i+1];assert(which=='result' or which=='success','invalid-store-result')
 if kind=='bossbar'then
  local id=S.id(a[i+2]);local field=a[i+3]
  assert((e:state().bossbars or {})[id],'unknown-bossbar:'..id)
  assert(field=='value'or field=='max','bossbar-store-field-invalid')
  local nextc=fork(c);nextc.stores={table.unpack(c.stores or {})}
  nextc.stores[#nextc.stores+1]=function(r)
   require('rules.commands.bossbar')._store(e,id,field,which=='success'and(r.success and 1 or 0)or r.result)
  end
  return nextc,i+4
 end
 if kind=='score'then
  local holders=e:score_holder(a[i+2],c,true);local objective=a[i+3];assert(e:state().objectives[objective],'unknown-objective')
  local nextc=fork(c);nextc.stores={table.unpack(c.stores or {})}
  nextc.stores[#nextc.stores+1]=function(r)
   local value=which=='success' and (r.success and 1 or 0) or math.floor(r.result)
   e:edit(function(s)for _,name in ipairs(holders)do s.scores[name]=s.scores[name] or {};s.scores[name][objective]=value end end)
  end
  return nextc,i+4
 end
 if kind=='storage'or kind=='entity'or kind=='block'then
  local D=require('rules.commands.data');local target,nexti=D._accessor(e,a,i+1,c)
  local path=a[nexti];assert(path,'data-path-required');D._path(path)
  local ty=a[nexti+1];local widths={byte=8,short=16,int=32}
  assert(widths[ty]or ty=='float'or ty=='double'or ty=='long','invalid-store-number-type')
  local scale=S.number(a[nexti+2]);local nextc=fork(c);nextc.stores={table.unpack(c.stores or {})}
  nextc.stores[#nextc.stores+1]=function(r)
   local value=(which=='success'and(r.success and 1 or 0)or r.result)*scale
   if ty~='float'and ty~='double'then
    value=math.floor(value)
    if widths[ty]then local modulus=2^widths[ty];value=(value+modulus/2)%modulus-modulus/2
    else assert(math.abs(value)<=9007199254740991,'store-long-exceeds-exact-json-range')end
   end
   D._write_path(e,target,path,value)
  end
  return nextc,nexti+3
 end
 error('execute-store-unavailable:'..tostring(kind),0)
end
function M.execute(e,a,c)
 local states={c};local index=1
 while index<=#a do
  local op=a[index]
  if op=='run'then
   local command=table.concat(a,' ',index+1);assert(command~='','execute-run-command-required')
   local success,total,last_error=0,0,nil
   for _,ctx in ipairs(states)do
    e:spend();local depth=e.execution.depth;local ok,r=pcall(e.dispatch,e,command,ctx)
    if not ok then
     local why=tostring(r);e.execution.depth=depth
     if why:find('command-execution-budget-exceeded',1,true)or why:find('command-recursion-limit',1,true)
       or why:find('command-world-changed',1,true)then error(why,0)end
     last_error=why;r={success=false,result=0,message=why}
    end
    for _,sink in ipairs(ctx.stores or {})do sink(r)end
    if r.success then success=success+(r.success_count or 1);total=total+r.result end
    if ctx.function_call and ctx.function_call.returned then break end
   end
   if success==0 and last_error then error(last_error,0)end
   return total,'execute '..success..' branches',success>0,success
  end
  local nextstates={};local nextindex
  local fork_limit=e:state().rules.max_command_forks or 65536
  local function append(child)
   assert(#nextstates<fork_limit,'command-fork-budget-exceeded');nextstates[#nextstates+1]=child
  end
  for _,ctx in ipairs(states)do
   e:spend();local nextc=fork(ctx);local n=index+1
   if op=='as' or op=='at'then
    local selected=e:select(assert(a[n],'selector-required'),ctx)
    for _,t in ipairs(selected)do
     local child=fork(ctx)
     if op=='as'then child.executor=t.id;child.eye_height=(t.height or 1.8)*.9
     else child.pos=t.pos;child.yaw=t.yaw or 0;child.pitch=t.pitch or 0 end
     append(child)
    end
    nextc=nil;n=n+1
   elseif op=='positioned'then
    if a[n]=='as'then
     for _,t in ipairs(e:select(a[n+1],ctx))do local child=fork(ctx);child.pos=t.pos;child.anchor='feet';append(child)end
     nextc=nil;n=n+2
    else nextc.pos,n=S.position(a,n,ctx);nextc.anchor='feet'end
   elseif op=='rotated'then
    if a[n]=='as'then
     for _,t in ipairs(e:select(a[n+1],ctx))do local child=fork(ctx);child.yaw=t.yaw;child.pitch=t.pitch;append(child)end
     nextc=nil;n=n+2
    else nextc.yaw=rotation(a[n],ctx.yaw);nextc.pitch=rotation(a[n+1],ctx.pitch);n=n+2 end
   elseif op=='anchored'then assert(a[n]=='eyes' or a[n]=='feet','invalid-anchor');nextc.anchor=a[n];n=n+1
   elseif op=='align'then
    assert(a[n] and a[n]:match('^[xyz]+$'),'invalid-align-axes');nextc.pos=fork(ctx.pos)
    local seen={};for axis in a[n]:gmatch('.')do assert(not seen[axis],'duplicate-align-axis');seen[axis]=true;nextc.pos[axis]=math.floor(nextc.pos[axis])end;n=n+1
   elseif op=='facing'then
    local p
    if a[n]=='entity'then
     local selected=e:select(a[n+1],ctx)
     assert(a[n+2]=='eyes' or a[n+2]=='feet','facing-anchor-required')
     for _,t in ipairs(selected)do
      local child=fork(ctx);local dx,dz=t.pos.x-ctx.pos.x,t.pos.z-ctx.pos.z
      local dy=t.pos.y+(a[n+2]=='eyes' and (t.height or 1.8)*.9 or 0)-ctx.pos.y
      child.yaw=math.deg(math.atan(-dx,dz));child.pitch=-math.deg(math.atan(dy,math.sqrt(dx*dx+dz*dz)));append(child)
     end
     nextc=nil;n=n+3
    else p,n=S.position(a,n,ctx);local dx,dz=p.x-ctx.pos.x,p.z-ctx.pos.z
     nextc.yaw=math.deg(math.atan(-dx,dz));nextc.pitch=-math.deg(math.atan(p.y-ctx.pos.y,math.sqrt(dx*dx+dz*dz)))end
   elseif op=='if' or op=='unless'then
    local yes,result;yes,n,result=condition(e,a,n,ctx)
    if yes~=(op=='if')then nextc=nil else nextc.condition_result=op=='if'and(result or 1)or 1 end
   elseif op=='store'then nextc,n=store(e,a,n,ctx)
   elseif op=='in'then assert(S.id(a[n])==e:call('dimension'),'dimension-unavailable');n=n+1
   else error('execute-subcommand-unavailable:'..tostring(op),0)end
   if nextc then append(nextc)end
   assert(not nextindex or n==nextindex,'execute-parser-context-diverged');nextindex=n
  end
  if #states==0 then return 0,'execute 0 branches',false end
  states=nextstates;index=nextindex
 end
 local total=0;for _,ctx in ipairs(states)do total=total+(ctx.condition_result or 1)end
 return total,'execute '..#states..' branches',#states>0
end
return M
