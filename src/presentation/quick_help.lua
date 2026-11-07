-- Session-only help. Only visible gameplay time consumes its brief lifetime.
local M={};M.__index=M
M.duration=12
M.lines=require('content.quick_help')
function M.new()return setmetatable({remaining=M.duration},M)end
function M:update(now,eligible,epoch)
  if eligible and self.eligible and self.epoch==epoch and self.last_time and now>=self.last_time then
    self.remaining=math.max(0,self.remaining-(now-self.last_time))
  end
  self.last_time=now;self.eligible=eligible;self.epoch=epoch
  return eligible and self.remaining>0
end
function M:toggle()
  self.remaining=self.remaining>0 and 0 or M.duration
  return self.remaining>0
end
return M
