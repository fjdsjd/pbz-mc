-- The native input lease owns focus. Execution and block edits belong to the
-- command service; queue acceptance never becomes an execution result here.
local M={};M.__index=M
local function clock(binding)return StaticFindObject('/Script/Engine.Default__GameplayStatics'):GetRealTimeSeconds(binding.actor)end
local function report(self,message,is_error,pending)
 if self.editor.status then self.editor:status(tostring(message or ''),is_error,pending)
 else self.editor.error=is_error and tostring(message)or nil;self.editor.revision=self.editor.revision+1 end
end
function M.new(ui,binding,controls,camera,log,options)
 options=options or {};log=log or function()end
 assert(controls.last.command_controls,'command-input-native-restart-required')
 local service=options.service
 local self=setmetatable({binding=binding,controls=controls,camera=camera,ui=ui,log=log,
  service=service,block=options.block,mouse_armed=false,mouse_down=false},M)
 ui.command_history=ui.command_history or {}
 if service then
  self.editor=require('presentation.command_editor').new(options.engine or service.engine or service,
   {initial=options.initial,block=options.block,history=ui.command_history,context=function()
    if options.block and type(service.block_context)=='function'then return service:block_context(options.block)end
    return service:context()
   end})
 else
  assert(not options.block,'command-block-service-required')
  self.editor=require('presentation.gamemode_command').new()
  if options.initial then self.editor:edit(options.initial)end
 end
 local ok,why=pcall(function()
  ui.command_layer=ui.command_layer or require('host.pbz.command_ui').new(ui);self.layer=ui.command_layer
  camera.inventory=true;camera:release_movement();controls:set_context('command')
  self.lease=require('host.pbz.inventory_input').acquire(ui,binding,log,{external_events=true,
   pointer=function()return controls:read().latest end,
   quarantine_held=function()controls:set_context('inactive');return true end})
  assert(not self.lease.creation_failure,self.lease.creation_failure)
  self.layer:render(self.editor,clock(binding));log(options.block and 'MC command block editor opened' or 'MC command opened')
 end)
 if not ok then self.closing=true;self.error=tostring(why);log('MC command setup failed: '..self.error);pcall(self.close,self)end
 return self
end
function M:close()
 if self.closed then return true end
 self.closing=true;self.pending=nil
 if self.lease and not self.lease:release()then return false end
 self.controls:set_context('inactive');self.camera.inventory=false;self.closed=true
 if self.layer and self.binding:is_current()then pcall(self.layer.render,self.layer,nil,clock(self.binding),self.message)end
 self.log('MC command closed; gameplay input restored');return true
end
function M:feedback(message)
 self.message=tostring(message or '')
 self.ui.command_message=self.message;self.ui.command_message_until=clock(self.binding)+5
end
function M:submit(value)
 if self.pending or self.closed or self.closing then return end
 if not self.binding:is_current()then return self:close()end
 if not self.service then
  local ok,why=pcall(require('host.pbz.campaign_inventory').set_game_mode,self.binding,value)
  if ok and why~=false then
   self:feedback(value=='creative' and '已将游戏模式设置为创造模式' or '已将游戏模式设置为生存模式');return self:close()
  end
  report(self,'当前无法切换模式',true);self.log('gamemode rejected: '..tostring(why));return
 end
 if self.block then
  local ok,accepted,why=pcall(self.service.edit_block,self.service,self.block,self.editor:patch())
  if ok and accepted then self:feedback('命令方块设置已更新');return self:close()end
  report(self,ok and (why or '命令方块设置未更新')or accepted,true);return
 end
 local context_ok,context=pcall(self.service.context,self.service)
 if not context_ok then report(self,context,true);return end
 self.editor:remember()
 local token={};self.pending=token;report(self,'命令执行中…',false,true)
 local function done(outcome)
  if self.pending~=token or self.closed or self.closing or not self.binding:is_current()or not self.ui:valid()then return end
  self.pending=nil;self.result=outcome
  if type(outcome)~='table'then report(self,'命令执行未返回有效结果',true);return end
  local success=outcome.success==true
  local message=outcome.message
  if type(message)~='string' or message==''then
   message=outcome.error or (success and ('命令执行完成：'..tostring(outcome.result or 0))or '命令执行失败')
  end
  report(self,message,not success)
  if success then self:feedback(message);self:close()end
 end
 local ok,accepted,job=pcall(self.service.submit,self.service,value or self.editor.text,context,done)
 if self.pending==token then
  if not ok or not accepted then
   self.pending=nil;report(self,ok and (job or '命令未加入执行队列')or accepted,true)
  else self.job_id=job end
 end
end
function M:pointer(sample)
 if not self.layer.hit then return end
 local view=self.ui.viewport
 local down=((sample.buttons or 0)&1)~=0
 if (sample.buttons or 0)==0 then self.mouse_armed=true end
 local clicked=self.mouse_armed and down and not self.mouse_down;self.mouse_down=down
 if not view or not sample.inside or not sample.focused then return end
 local x=(sample.x or 0)*view.width/math.max(1,sample.width or view.width)
 local y=(sample.y or 0)*view.height/math.max(1,sample.height or view.height)
 local hit=self.layer:hit(x,y);local hover=hit and hit.id
 if self.editor.hover~=hover then self.editor.hover=hover;self.editor.revision=self.editor.revision+1 end
 if not clicked or not hit or self.editor.pending then return end
 if hit.id=='close'then return self:close()
 elseif hit.id=='submit'then return self:submit(self.editor.text)
 elseif hit.id=='field'then
  local layout=self.layer.layout;local position=require('presentation.command_line').cursor_at(self.editor,self.ui.assets,
   (x-hit.x)/layout.scale+(hit.scroll or 0))
  if self.editor.set_cursor then self.editor:set_cursor(position,sample.shift)
  else self.editor.cursor=position;self.editor.selected_all=nil;self.editor.revision=self.editor.revision+1 end
 elseif hit.id=='suggestion' and self.editor.choose then self.editor:choose(hit.index)
 elseif self.editor.configure then self.editor:configure(hit.id)end
end
function M:tick()
 if self.closed then return end
 if self.closing or not self.binding:is_current()or not self.ui:valid()then return self:close()end
 local batch=self.controls:read();self.camera:input(batch,false,0)
 if batch.overflow or batch.timed_out_since_read or not batch.latest or not batch.latest.focused then return self:close()end
 for _,sample in ipairs(batch.samples or {})do
  self:pointer(sample);if self.closed or self.closing then return end
  if sample.command_key and sample.command_key>0 then
   local action,value=self.editor:key(sample.command_key,sample.shift,sample.ctrl)
   if action=='submit'then self:submit(value)
   elseif action=='close'then return self:close()end
   if self.closed or self.closing then return end
  end
 end
 self:pointer(batch.latest);if self.closed or self.closing then return end
 self.layer:render(self.editor,clock(self.binding))
end
return M
