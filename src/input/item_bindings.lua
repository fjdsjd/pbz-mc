-- Logical bit order is the native item-input protocol, not a saved item enum.
-- Only physical bindings are configurable; context decides the resulting action.
local M={}
M.actions={'inventory','close','offhand','drop','slot_1','slot_2','slot_3','slot_4','slot_5','slot_6','slot_7','slot_8','slot_9','camera',
  'forward','left','back','right','jump','sneak','sprint','chain_mine'}
M.defaults={inventory='B',close='Escape',offhand='F',drop='Q',slot_1='1',slot_2='2',slot_3='3',slot_4='4',slot_5='5',slot_6='6',slot_7='7',slot_8='8',slot_9='9',camera='F5'}
local fixed={camera=116,forward=87,left=65,back=83,right=68,jump=32,sneak=16,sprint=17,chain_mine=192}
M.defaults.forward='W';M.defaults.left='A';M.defaults.back='S';M.defaults.right='D'
M.defaults.jump='Space';M.defaults.sneak='Shift';M.defaults.sprint='Control'
M.defaults.chain_mine='`'
local allowed={};for _,name in ipairs(M.actions) do allowed[name]=true end
function M.code(name)
  assert(type(name)=='string','invalid-item-binding-name')
  if name=='Escape' then return 27 end
  if name:match('^[A-Z0-9]$') then return name:byte() end
  local n=tonumber(name:match('^F(%d+)$'))
  if n and n>=1 and n<=12 and n~=5 and tostring(n)==name:sub(2) then return 111+n end
  error('unsupported-or-reserved-item-key:'..name)
end
function M.compile(overrides)
  overrides=overrides or {};assert(type(overrides)=='table','invalid-item-bindings')
  for key in pairs(overrides) do assert(allowed[key],'unknown-item-binding:'..tostring(key)) end
  local result={names={},codes={},bits={}}
  local seen={}
  for i,action in ipairs(M.actions) do
    local name=overrides[action] or M.defaults[action]
    assert(action~='close' or name=='Escape','escape-must-remain-close')
    assert(not fixed[action] or name==M.defaults[action],'fixed-first-person-key:'..action)
    local code=fixed[action] or M.code(name)
    assert(not seen[code],'conflicting-item-key:'..name)
    seen[code]=true;result.names[action]=name;result.codes[i]=code;result.bits[action]=i-1
  end
  result.csv=table.concat(result.codes,',')
  return result
end
return M
