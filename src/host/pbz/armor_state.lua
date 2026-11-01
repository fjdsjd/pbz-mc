-- Inventory tables are immutable after a successful transaction. Cache only
-- the four armor slots; hotbar changes never rebuild equipment/model state.
local rules=require('rules.armor')
local M={}
local empty={}
local snapshots=setmetatable({},{__mode='k'})
function M.get(slots)
  slots=slots or empty
  local cached=snapshots[slots]
  if not cached then cached=rules.snapshot(slots);snapshots[slots]=cached end
  return cached
end
return M
