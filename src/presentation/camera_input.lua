-- F5 shares the native message queue but never produces an item/combat intent.
local M={};M.__index=M
function M.new() return setmetatable({armed=false},M) end
function M:update(pointer,allowed,epoch)
  local down=((pointer.keys or 0)&(1<<13))~=0
  local stamp=tostring(pointer.epoch)..'/'..tostring(epoch)..'/'..tostring(allowed)
  if not pointer.focused or not allowed or pointer.overflow or self.stamp~=stamp then
    self.stamp=stamp;self.armed=false;self.down=down
    if not pointer.focused or not allowed or pointer.overflow then return false end
  end
  if not down then self.armed=true;self.down=false;return false end
  local pressed=self.armed and not self.down
  self.down=true
  return pressed
end
return M
