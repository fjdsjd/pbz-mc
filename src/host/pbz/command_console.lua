local M={};M.__index=M
local function clock(binding)return StaticFindObject('/Script/Engine.Default__GameplayStatics'):GetRealTimeSeconds(binding.actor)end
function M.new(ui,binding,controls,camera,log)
 assert(controls.last.command_controls,'command-input-native-restart-required')
 local self=setmetatable({binding=binding,controls=controls,camera=camera,ui=ui,log=log,
  editor=require('presentation.gamemode_command').new()},M)
 ui.command_layer=ui.command_layer or require('host.pbz.command_ui').new(ui)
 self.layer=ui.command_layer
 local ok,why=pcall(function()
  camera.inventory=true;camera:release_movement()
  controls:set_context('command')
  self.lease=require('host.pbz.inventory_input').acquire(ui,binding,log,{external_events=true,
   pointer=function()return controls:read().latest end,
   quarantine_held=function()controls:set_context('inactive');return true end})
  assert(not self.lease.creation_failure,self.lease.creation_failure)
  self.layer:render(self.editor,clock(binding));log('MC command opened; gamemode only')
 end)
 if not ok then self.closing=true;self.error=tostring(why);log('MC command setup failed: '..self.error);pcall(self.close,self)end
 return self
end
function M:close()
 self.closing=true
 if self.lease and not self.lease:release()then return false end
 self.controls:set_context('inactive');self.camera.inventory=false
 self.closed=true
 if self.binding:is_current()then pcall(self.layer.render,self.layer,nil,clock(self.binding),self.message)end
 self.log('MC command closed; gameplay input restored');return true
end
function M:tick()
 if self.closed then return end
 if self.closing or not self.binding:is_current()or not self.ui:valid()then return self:close()end
 local batch=self.controls:read()
 self.camera:input(batch,false,0)
 if batch.overflow or batch.timed_out_since_read or not batch.latest.focused then return self:close()end
 for _,sample in ipairs(batch.samples)do
  if sample.command_key and sample.command_key>0 then
   local action,mode=self.editor:key(sample.command_key,sample.shift,sample.ctrl)
   if action=='submit'then
    local ok,why=pcall(require('host.pbz.campaign_inventory').set_game_mode,self.binding,mode)
    if ok then
     self.message=mode=='creative' and '已将游戏模式设置为创造模式' or '已将游戏模式设置为生存模式'
     self.ui.command_message=self.message;self.ui.command_message_until=clock(self.binding)+3
     return self:close()
    else self.editor.error='当前无法切换模式';self.editor.revision=self.editor.revision+1;self.log('gamemode rejected: '..tostring(why))end
   elseif action=='close'then return self:close()end
  end
 end
 self.layer:render(self.editor,clock(self.binding))
end
return M
