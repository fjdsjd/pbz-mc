-- Independent of inventory state; a failed first registration must be visible
-- even when the normal hotbar and help cannot bind. No gameplay input lease.
local M={};M.__index=M
function M.new(directory,log)
  return setmetatable({directory=directory,log=log,next_check=0},M)
end
function M:close()
  if self.ui then self.ui:close();self.ui=nil end
  self.binding=nil;self.next_check=0;self.reason=nil;self.until_time=nil
end
function M:update(binding,reason,allowed,now)
  if not reason or not binding then self:close();return end
  if self.binding~=binding then self:close();self.binding=binding end
  local recovered=reason:find('MC 数据已自动重建',1,true)~=nil
  if recovered and self.reason~=reason then self.until_time=now+20 end
  self.reason=reason
  if recovered and now>=self.until_time then if self.ui then self.ui:set_visible(false)end;return end
  if not allowed then if self.ui then self.ui:set_visible(false)end;return end
  if now<self.next_check then return end
  self.next_check=now+1
  local ok,why=pcall(function()
    if self.ui and not self.ui:valid()then self.ui:close();self.ui=nil end
    if not self.ui then self.ui=require('host.pbz.item_ui').new(self.directory..'/pbzmc-assets/ui',self.log)end
    local message=recovered and reason or require('storage.file_io').is_error(reason)
      and 'MC 存档读写失败，请保留存档并完整更新模组。详情：UE4SS.log (PBZMC-IO)'
      or 'MC 读档失败，请保留存档并查看 UE4SS.log 中的具体原因。'
    self.ui:show_message(message,now)
  end)
  if not ok then
    self.next_check=now+5
    if self.last_error~=tostring(why)then self.last_error=tostring(why);self.log('MC load notice unavailable: '..self.last_error)end
  end
end
return M
