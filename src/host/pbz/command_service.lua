-- Commands share the campaign memory transaction and native world ownership.
-- Jobs yield between bounded operations; no worker thread calls Unreal.
local campaign=require('host.pbz.campaign_inventory')
local Blocks=require('content.blocks')
local state=require('storage.state')
local Props=require('rules.block_properties')
local D=require('rules.block_directions')
local M={};M.__index=M;local active
local modes={impulse='pbzmc:command_block',['repeat']='pbzmc:repeating_command_block',chain='pbzmc:chain_command_block'}
local yaw={north=180,south=0,east=-90,west=90,up=0,down=0}
local function copy(t)local result={};for k,v in pairs(t or {})do result[k]=v end;return result end
-- UE4SS binds Unreal calls to registered Lua states. A plain coroutine may
-- compute rules, but may not call a native userdata method. Marshal every host
-- operation back to the registered game-thread callback before resuming rules.
function M:host_proxy()
  local owner=self
  local function invoke(group,name,...)
    local thread=coroutine.running()
    if owner.job and thread==owner.job.thread then
      local values=table.pack(coroutine.yield({kind='host',group=group,name=name,args=table.pack(...)}))
      if not values[1]then error(values[2],0)end
      return table.unpack(values,2,values.n)
    end
    local target=group=='entities'and owner.entities or owner
    return assert(target[name],'command-host-method:'..name)(target,...)
  end
  -- The concrete adapter invalidates its snapshot inside each mutation. Avoid
  -- a second host yield after /kill, which can retire the player binding.
  local entity_proxy=setmetatable({supports_level=false,invalidate=false},{__index=function(_,name)
    return function(_,...)return invoke('entities',name,...)end
  end})
  return setmetatable({entities=entity_proxy,checkpoint=function(_,force)return owner:checkpoint(force)end},
    {__index=function(_,name)return function(_,...)return invoke('host',name,...)end end})
end
function M.get(binding)return active and active.binding==binding and not active.closed and active or nil end
function M.close()
  if active then
    active.closing=true
    local ok,why=active:cancel_all('command-world-closing')
    if not ok or active:has_pending_mutations()then
      local message=tostring(why or 'command-rollback-pending')
      if active.close_error~=message then pcall(active.message,active,'chat','命令回滚未完成，MC 保存已暂停：'..message)end
      active.close_error=message
      return false,active.close_error
    end
    if active.presentation then
      active:with_native(active.presentation.close,active.presentation)
      if active.binding.mc_command_presentation==active.presentation then active.binding.mc_command_presentation=nil end
    end
    if active.gameplay then assert(active.gameplay:close())end
    active.closed=true
    active.rules:clear();active.entities:close()
    if active.build.commands==active then active.build.commands=nil end
    active=nil
  end
  return true
end
function M.ensure(binding,build,directory,acquire_summons,log,feedback)
  if active and (active.binding~=binding or not binding:is_current()or active.closing)then local ok,why=M.close();assert(ok,why)end
  if not active then
    local self=setmetatable({binding=binding,build=build,directory=directory,log=log,feedback=feedback,
      queue={},serial=0,tick_id=0,processed=0,failed=0},M)
    self.clock=campaign.command_clock(binding)
    self.game=StaticFindObject('/Script/Engine.Default__GameplayStatics')
    self.entities=require('host.pbz.command_entities').new(binding,{origin=function()return build.mechanisms.origin end,
      summons=acquire_summons,player_id='player',log=log,
      get_tags=function(id)return self:command_state().tags[id]end,
      set_tags=function(id,tags)return self.engine:edit(function(s)s.tags[id]=tags;return true end)end})
    self.world=require('host.pbz.command_world').new(build,{
      rollback_memory=campaign.command_rollback(binding),checkpoint=function()self:checkpoint(true)end,
      native_context=function()return self.native_state==coroutine.running()end})
    self.engine=require('rules.commands.engine').new(self:host_proxy())
    self.rules=require('rules.command_blocks').new({
      get=function(p)return build.mechanisms.index[D.key(p.x,p.y,p.z)]end,
      cell=function(record)return build.mechanisms:cell(record)end,
      powered=function(record)return (record.properties or {}).powered==true end,
      execute=function(record,done)
        return self:submit((record.properties or {}).command or '',self:block_context(record),done)
      end,
      outcome=function(record,count,output)return self:outcome(record,count,output)end,
    },{budget=64,max_chain=function()return self:command_state().rules.max_command_sequence_length or 65536 end})
    build.commands=self
    for _,record in pairs(build.mechanisms.index)do
      if Blocks.get(record.content_id).command_block then self.rules:upsert(record)end
    end
    active=self;log('MC command engine bound; native-savepoint-only; bounded game-thread jobs')
  end
  return active
end
function M:command_state()
  self.initial_state=self.initial_state or {scores={},objectives={},teams={},members={},tags={},storage={},rules={}}
  return campaign.command_state(self.binding)or self.initial_state
end
function M:save_command_state(value,expected)
  if expected==self.initial_state then expected=nil end
  return campaign.save_command_state(self.binding,value,expected)
end
function M:checkpoint(force)
  if not self.job or coroutine.running()~=self.job.thread then return end
  assert(not self.cancel_reason,self.cancel_reason)
  self.slice_ops=(self.slice_ops or 0)+1
  if force or self.slice_ops>=64 or os.clock()>=(self.deadline or math.huge)then
    coroutine.yield({kind='budget'})
    assert(not self.cancel_reason,self.cancel_reason)
    assert(not self.closed,'command-world-changed')
  end
end
function M:has_pending_mutations()
  return self.world:has_pending_mutations()or self.gameplay and self.gameplay:has_pending_mutations()or false
end
function M:with_native(fn,...)
  local thread=coroutine.running()
  assert(not self.job or thread~=self.job.thread,'command-native-worker-rejected')
  -- UE4SS may use a different registered state for each game-thread callback.
  -- Authorize this exact callback scope, never its child rule coroutine.
  local previous=self.native_state;self.native_state=thread
  local result=table.pack(pcall(fn,...))
  self.native_state=previous
  if not result[1]then error(result[2],0)end
  return table.unpack(result,2,result.n)
end
function M:step_world(tx,owner)
  owner=owner or self.world
  return self:with_native(owner.step,owner,tx)
end
function M:gameplay_component()
  if not self.gameplay then self.gameplay=require('host.pbz.command_gameplay').new(self.binding,self.entities,{
    origin=function()return self.build.mechanisms.origin end,
    native_context=function()return self.native_state==coroutine.running()end})end
  return self.gameplay
end
function M:presentation_component()
  if not self.presentation then self.presentation=require('host.pbz.command_presentation').new(self.binding,self.directory..'/pbzmc-assets',{
    entities=self.entities,native_context=function()return self.native_state==coroutine.running()end,
    player_swing_available=function()
      local containers=campaign.view(self.binding)
      local stack=require('rules.container_slots').get(containers,'player/hotbar/'..containers.player.selected)
      return not require('rules.native_slot_reference').is(stack)
    end,
    swing_target=function(handle,record,check)
      if handle.kind~='mc'then return false end
      local part=record.hand=='offhand'and 'left_arm'or 'right_arm'
      if not handle.mob.parts or not handle.mob.parts[part]then return false end
      if not check then handle.mob.command_swing=record end
      return true
    end});self.binding.mc_command_presentation=self.presentation end
  return self.presentation
end
function M:block_ticket_valid(job)
  if not job.block then return true end
  local r=self.build.session.data.buildings[job.block.id]
  return r and r.content_id==job.block.content_id and (r.properties or {}).command==job.block.command
    and r.x==job.block.x and r.y==job.block.y and r.z==job.block.z or false
end
function M:cancel_job(reason)
  local job=self.job
  local tx=job and job.transaction or self.recovery
  local owner=job and job.transaction_owner or self.recovery_owner or self.world
  if not tx and self:has_pending_mutations()then
    owner=self.world:has_pending_mutations()and self.world or self.gameplay
    tx=owner:begin_rollback(reason);self.recovery=tx;self.recovery_owner=owner
  end
  if tx then
    owner:cancel(tx,reason)
    local done,_,value=self:step_world(tx,owner)
    if not done then
      if job then job.cancelled=reason end
      return false,tx.blocked or 'command-rollback-pending'
    end
    self.recovery=nil;self.recovery_owner=nil;if job then job.transaction=nil;job.transaction_owner=nil end
    if self:has_pending_mutations()then return false,tostring(value or 'command-rollback-pending')end
  end
  if not job then return true end
  self.cancel_reason=reason
  -- Pure rules unwind on an error result. No coroutine invokes Unreal.
  local ok,value=true,nil
  if job.started then ok,value=coroutine.resume(job.thread,false,reason)end
  if job.started and coroutine.status(job.thread)~='dead'then return false,'command-cancellation-did-not-unwind'end
  self.engine.execution=nil;self.cancel_reason=nil
  self:finish_job(job,{success=false,result=0,success_count=0,error=reason,message='命令已停止 '..reason})
  return true,not ok and value or nil
end
function M:cancel_all(reason)
  local queued=self.queue;self.queue={}
  for _,job in ipairs(queued)do if job.done then pcall(job.done,{success=false,result=0,success_count=0,error=reason,message='命令已停止 '..reason})end end
  return self:cancel_job(reason)
end
function M:context()
  local p=assert(self.entities:player(),'command-player-unavailable')
  return {executor=p.id,pos=copy(p.pos),yaw=p.yaw,pitch=p.pitch,eye_height=(p.height or 1.8)*.9,
    anchor='feet',dimension=self:dimension(),source='player'}
end
function M:block_context(record)
  local o=self.build.mechanisms.origin;local facing=(record.properties or {}).facing or 'north'
  return {pos={x=.5+(record.x-o.x)/100,y=.5+(record.z-o.z)/100,z=.5-(record.y-o.y)/100},
    yaw=yaw[facing],pitch=0,anchor='feet',dimension=self:dimension(),source='block',block_id=record.id}
end
function M:submit(text,context,done)
  if self.closed or self.closing or not self.binding:is_current()then return false,'command-world-changed'end
  if (not self.job or self.job.cancelled)and self:has_pending_mutations()then return false,'command-rollback-pending'end
  if #self.queue>=64 then return false,'command-queue-full'end
  if type(text)~='string'or #text>131068 or not utf8.len(text)or require('rules.commands.syntax').utf16_length(text)>32767 then return false,'command-too-long'end
  self.serial=self.serial+1
  local job={id=self.serial,text=text,context=context or self:context(),done=done}
  if job.context.block_id then
    local r=self.build.session.data.buildings[job.context.block_id]
    if not r or not Blocks.get(r.content_id).command_block then return false,'command-block-removed'end
    job.block={id=r.id,content_id=r.content_id,command=(r.properties or {}).command,x=r.x,y=r.y,z=r.z}
  end
  self.queue[#self.queue+1]=job
  return true,self.serial
end
function M:finish_job(job,value)
  self.job=nil;self.last_result=value;self.processed=self.processed+1
  if not value.success then self.failed=self.failed+1 end
  if job.done then local done,why=pcall(job.done,value);if not done then self.log('command completion failed '..tostring(why))end end
  local reported,why=pcall(function()
    if job.context.source~='block'then
      if not value.success or (self.message_serial or 0)==job.message_serial and self.binding:is_current()
        and self:command_state().rules.send_command_feedback~=false then self:message('chat',value.message,job.context)end
    elseif not value.success and self.last_block_error~=value.error then
      self.last_block_error=value.error;self.log('command block '..tostring(job.context.block_id)..' '..tostring(value.message))
    end
  end)
  if not reported then self.log('command feedback unavailable '..tostring(why))end
end
function M:invoke_job_host(job)
  local request=job.request;job.request=nil
  assert(request and request.kind=='host','invalid-command-host-request')
  if not self.binding:is_current()then job.response=table.pack(false,'command-world-changed');return end
  local args=request.args
  if request.group=='host'and request.name=='spread_players'then
    local owner=self:gameplay_component();local tx,why=owner:begin_spread(args[1])
    if not tx then job.response=table.pack(false,why)else job.transaction=tx;job.transaction_owner=owner end
  elseif request.group=='host'and (request.name=='write_blocks'or request.name=='write_block_data')then
    local name=request.name=='write_blocks'and 'begin_write_blocks'or 'begin_write_block_data'
    local ok,tx,why=pcall(self.world[name],self.world,table.unpack(args,1,args.n))
    if not ok or not tx then job.response=table.pack(false,ok and why or tx)
    else job.transaction=tx;job.transaction_owner=self.world end
  else
    local target=request.group=='entities'and self.entities or self
    local fn=assert(target[request.name],'unknown-command-host-method:'..tostring(request.name))
    job.response=table.pack(pcall(self.with_native,self,fn,target,table.unpack(args,1,args.n)))
  end
end
function M:tick(now,shared_budget)
  if self.closed or self.closing or not self.binding:is_current()then M.close();return end
  if not shared_budget then
    if not self.entities.effect_timer then self.entities:tick(now)end
    self.deadline=os.clock()+.002;self.slice_ops=0
    if self.presentation then self:with_native(self.presentation.tick,self.presentation,now)end
    if self.build.world.commands_catalog then self.build.world.commands_catalog:animate(self.build.world,math.floor(now*20))end
  end
  if os.clock()>=(self.deadline or 0)then return end
  if not self.job and self:has_pending_mutations()then
    if now<(self.next_recovery or 0)then return end
    local restored,why=self:cancel_job('command-recovery')
    if not restored then
      self.next_recovery=now+(self.recovery and self.recovery.blocked and .25 or 0)
      if self.recovery_error~=tostring(why)then
        self.recovery_error=tostring(why)
        pcall(self.message,self,'chat','正在恢复中断的方块操作；若恢复位置被挡住，请离开施工区域。完成前暂停 MC 保存。')
        self.log('command recovery pending '..self.recovery_error)
      end
      return
    end
    self.recovery_error=nil;self.next_recovery=nil
  end
  local completed=0
  repeat
    if not self.job then
      self.job=table.remove(self.queue,1)
      if self.job then
        local job=self.job;job.message_serial=self.message_serial or 0
        job.thread=coroutine.create(function()return self.engine:run(job.text,job.context)end)
      end
    end
    local job=self.job;if not job then break end
    if job.cancelled or not self:block_ticket_valid(job)then
      self:cancel_job(job.cancelled or 'command-block-changed');break
    end
    if job.transaction then
      -- Each call performs one bounded native phase in this registered state.
      if now<(job.next_world_step or 0)then break end
      local done,ok,value=self:step_world(job.transaction,job.transaction_owner)
      if not done then
        if job.transaction.blocked then
          job.next_world_step=now+.25
          if job.blocked_error~=tostring(job.transaction.blocked)then
            job.blocked_error=tostring(job.transaction.blocked)
            pcall(self.message,self,'chat','命令回滚受阻，请离开施工区域；完成前暂停 MC 保存。')
            self.log('command rollback waiting '..job.blocked_error)
          end
        end
        break
      end
      job.transaction=nil;job.transaction_owner=nil;job.response=table.pack(ok,value)
    elseif job.request then
      local ok,why=pcall(self.invoke_job_host,self,job)
      if not ok then job.request=nil;job.response=table.pack(false,tostring(why))end
      if job.transaction then break end
    end
    local response=job.response or {n=0};job.response=nil;job.started=true
    local ok,value=coroutine.resume(job.thread,table.unpack(response,1,response.n))
    if not ok or coroutine.status(job.thread)=='dead'then
      if not ok then
        self.engine.execution=nil
        value={success=false,result=0,success_count=0,error=tostring(value),message='命令失败 '..tostring(value)}
      end
      self:finish_job(job,value);completed=completed+1
      if not self.binding:is_current()then M.close();return end
    elseif type(value)=='table'and value.kind=='host'then job.request=value
    elseif type(value)=='table'and value.kind=='budget'then break
    else self:cancel_job('invalid-command-worker-yield');break end
  until completed>=8 or os.clock()>=self.deadline
end
function M:game_tick(tick)
  self.tick_id=tick
  if self.last_logical_tick~=tick then self.clock(1);self.last_logical_tick=tick end
  local slices=0
  repeat
    self.rules:step(tick)
    self:tick(self.game:GetTimeSeconds(self.binding.actor),true)
    slices=slices+1
  until not self.rules:pending_tick() or slices>=64 or os.clock()>=(self.deadline or 0)
  if self.closed or not self.binding:is_current()then return true end
  local scheduled=self:command_state().scheduled or {}
  for i=#scheduled,1,-1 do
    local row=scheduled[i]
    if row.at<=self.clock()then
      local ok,id=self:submit('function '..row.name,{pos={x=0,y=0,z=0},yaw=0,pitch=0,anchor='feet',dimension=self:dimension(),source='server'})
      if ok then
        local committed,why=pcall(self.engine.edit,self.engine,function(s)table.remove(s.scheduled,i)end)
        if not committed then
          -- Enqueue and consume the saved schedule are one local transaction.
          -- No yield occurs here; a rejected store write cannot run a duplicate.
          for q=#self.queue,1,-1 do if self.queue[q].id==id then table.remove(self.queue,q);break end end
          if self.schedule_error~=tostring(why)then self.schedule_error=tostring(why);self.log('schedule waiting '..self.schedule_error)end
        else self.schedule_error=nil end
      end
    end
  end
  return not self.rules:pending_tick()
end
function M:changed(changes)
  for _,row in ipairs(changes)do
    local a,b=row.before,row.after
    if a and Blocks.get(a.content_id).command_block and(not b or not Blocks.get(b.content_id).command_block)then self.rules:remove(a)end
    if b and Blocks.get(b.content_id).command_block then self.rules:upsert(b)end
  end
end
function M:edit_block(record,patch)
  local old=self.build.session.data.buildings[record.id]
  if not old or not Blocks.get(old.content_id).command_block then return false,'command-block-removed'end
  local after=copy(old);after.properties=copy(old.properties)
  if patch.mode then after.content_id=assert(modes[patch.mode],'invalid-command-block-mode')end
  for _,key in ipairs({'command','conditional','auto','track_output'})do if patch[key]~=nil then after.properties[key]=patch[key]end end
  Props.validate(after.properties)
  return self.build.mechanisms:commit({{before=old,after=after}},{source='command-editor'},true)
end
function M:outcome(record,count,output)
  local old=self.build.session.data.buildings[record.id]
  if not old or not Blocks.get(old.content_id).command_block then return false,'command-block-removed'end
  local p=old.properties or {};count=math.max(0,math.min(2147483647,math.floor(count or 0)))
  local value=type(output)=='string'and output or output and output.message or ''
  if count>0 and self:command_state().rules.send_command_feedback==false then value=''end
  if value~=''then value='['..os.date('%H:%M:%S')..'] '..value end
  while #value>2048 do value=value:sub(1,2048);while not utf8.len(value)do value=value:sub(1,-2)end end
  if p.success_count==count and (p.track_output==false and p.last_output==nil or p.last_output==value)then return true end
  local after=copy(old);after.properties=copy(p);after.properties.success_count=count
  after.properties.last_output=p.track_output~=false and value or nil
  local ok,why=self.build.mechanisms:commit({{before=old,after=after}},{source='command-result'},true)
  if not ok then self.log('command result commit rejected '..tostring(why))end
  return ok,why
end
function M:read_block(p)return self.world:read_block(p)end
function M:write_blocks(rows)return self.world:write_blocks(rows)end
function M:block_data(p)return self.world:block_data(p)end
function M:write_block_data(p,value,expected)return self.world:write_block_data(p,value,expected)end
function M:game_mode(player,mode)
  assert(player.player,'only-player-game-mode');return campaign.set_game_mode(self.binding,mode)
end
function M:give(player,id,count)
  assert(player.player,'only-player-inventory')
  return campaign.command_items(self.binding,function(c,g,p)return require('rules.commands.inventory').give(c,id,count,g,p)end)
end
function M:clear_items(player,id,count)
  assert(player.player,'only-player-inventory')
  return campaign.command_items(self.binding,function(c)return require('rules.commands.inventory').clear(c,id,count)end)
end
function M:replace_item(player,slot,id,count)
  assert(player.player,'entity-equipment-unavailable')
  return campaign.command_items(self.binding,function(c,g,p)return require('rules.commands.inventory').replace(c,slot,id,count,g,p)end)
end
function M:enchant_items(targets,id,level)return self:gameplay_component():enchant_items(targets,id,level)end
function M:play_sound(request)return self:presentation_component():play_sound(request)end
function M:stop_sound(request)return self:presentation_component():stop_sound(request)end
function M:particle(request)return self:presentation_component():particle(request)end
function M:swing(request)return self:presentation_component():swing(request)end
function M:message(kind,value,context)
  self.message_serial=(self.message_serial or 0)+1
  self.last_message={kind=kind,text=value,time=self:wall_clock()}
  if self.feedback then self.feedback(value,kind,self.title_duration)end
  if context and context.source~='block'then self.log('command '..kind..' '..value)end
  return true
end
function M:title_times(fade,stay,out)self.title_duration=(fade+stay+out)/20;return true end
function M:wall_clock()
  if self.binding:is_current()then return self.game:GetRealTimeSeconds(self.binding.actor)end
  return os.clock()
end
function M:dimension()return 'pbz:current_world'end
function M:game_time()return self.clock()end
function M:version()
  if not self.version_text then
    local file=assert(io.open(self.directory..'/../../../../../../PBZMC/release.json','rb'),'installed-release-manifest-missing')
    local raw=file:read(65537);file:close();assert(#raw<=65536,'release-manifest-too-large')
    local value=assert(require('dkjson').decode(raw));assert(type(value.version)=='string','release-version-missing')
    self.version_text='PBZMC '..value.version..' / Minecraft rules '..require('content.command_catalogue').version
  end
  return self.version_text
end
function M:is_loaded(p)
  return math.abs(p.x)<30000000 and math.abs(p.y)<30000000 and math.abs(p.z)<30000000
end
function M:function_lines(id)
  local space,name=id:match('^([a-z0-9_.%-]+):([a-z0-9_/%.%-]+)$')
  assert(space and not name:find('..',1,true),'invalid-function-path')
  local path=self.directory..'/pbzmc-data/functions/'..space..'/'..name..'.mcfunction'
  local file=assert(io.open(path,'rb'),'function-not-found:'..id);local raw=file:read(1024*1024+1);file:close()
  assert(#raw<=1024*1024,'function-file-too-large')
  local lines={};for line in (raw..'\n'):gmatch('(.-)\n')do
    line=line:gsub('\r$',''):match('^%s*(.-)%s*$')
    if line~=''and line:sub(1,1)~='#'then lines[#lines+1]=line end
  end
  return lines
end
function M:schedule(name,ticks,mode)
  self:function_lines(name)
  local at=self.clock()+ticks
  return self.engine:edit(function(s)
    s.scheduled=s.scheduled or {}
    if mode=='replace'then for i=#s.scheduled,1,-1 do if s.scheduled[i].name==name then table.remove(s.scheduled,i)end end end
    for _,r in ipairs(s.scheduled)do if r.name==name and r.at==at then return true end end
    assert(#s.scheduled<1024,'schedule-queue-full')
    s.scheduled[#s.scheduled+1]={name=name,at=at};return true
  end)
end
function M:clear_schedule(name)
  return self.engine:edit(function(s)
    local n=0;s.scheduled=s.scheduled or {}
    for i=#s.scheduled,1,-1 do if s.scheduled[i].name==name then table.remove(s.scheduled,i);n=n+1 end end
    return n
  end)
end
function M:completion_ids(kind)
  self.completions=self.completions or {}
  if not self.completions[kind]then
    local ids={}
    if kind=='summon'then for _,row in ipairs(require('content.summon_mobs').list())do ids[#ids+1]='minecraft:'..row.name end
    elseif kind=='give'then for id in pairs(require('content.items').all())do ids[#ids+1]=id:gsub('^pbzmc:','minecraft:')end
    else for _,id in ipairs(Blocks.catalogue())do ids[#ids+1]=id:gsub('^pbzmc:','minecraft:')end end
    table.sort(ids);self.completions[kind]=ids
  end
  return self.completions[kind]
end
return M
