-- F5 and help share the native message queue without item/combat intents.
local M={};M.__index=M
function M.new(bit) return setmetatable({armed=false,bit=bit or 13},M) end
function M:update(pointer,allowed,epoch)
  local down=((pointer.keys or 0)&(1<<self.bit))~=0
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
