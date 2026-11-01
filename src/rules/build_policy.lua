-- Current PBZ rule: building supplies are infinite; demolition never refunds.
local M={}
function M.cost(mode,creative)
  assert(mode=='free' or mode=='adventure','invalid-mode')
  return 0
end
function M.refund(mode,definition,cause)
  assert(mode=='free' or mode=='adventure','invalid-mode')
  return 0
end
function M.has_capacity(data,world,definition,registry)
  local count=0
  for _,record in pairs(data.buildings) do
    local other=registry.get(record.content_id)
    if record.world==world and other and other.group==definition.group then count=count+1 end
  end
  return count<definition.limit
end
return M
