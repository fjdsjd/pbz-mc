-- Session-only help. Only visible gameplay time consumes its brief lifetime.
local M={};M.__index=M
M.duration=12
M.lines={
  '[B] 打开背包',
  '[F5] 切换视角',
  '攀岩：请切换到影之刃主武器',
  '马车战：建议使用影之刃原版武器',
  '[H] 关闭提示 / 再次查看',
}
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
