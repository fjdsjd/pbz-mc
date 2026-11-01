-- Render suppression is independent of sequence-authored visibility tracks.
-- Keep native animation/collision alive and restore every acquired render flag.
local M={}
local flags={
  {field='bRenderInMainPass',method='SetRenderInMainPass'},
  {field='bRenderInDepthPass',method='SetRenderInDepthPass'},
  {field='CastShadow',method='SetCastShadow'},
}
function M.capture(component)
  local result={hidden=component.bHiddenInGame,render={}}
  for _,flag in ipairs(flags)do
    local value=component[flag.field]
    assert(type(value)=='boolean','appearance-render-flag-unavailable:'..flag.field)
    result.render[flag.field]=value
  end
  return result
end
function M.hide(component,saved)
  assert(saved and saved.render,'appearance-render-lease-required')
  -- Cinematic visibility sections may write bHiddenInGame after our pose tick.
  -- Excluding the original from render passes prevents a one-frame reappearance.
  for _,flag in ipairs(flags)do
    if component[flag.field]then component[flag.method](component,false)end
  end
  if not component.bHiddenInGame then component:SetHiddenInGame(true,false)end
end
function M.restore(component,saved)
  for _,flag in ipairs(flags)do
    local value=saved.render[flag.field]
    if component[flag.field]~=value then component[flag.method](component,value)end
  end
  component:SetHiddenInGame(saved.hidden,false)
end
return M
