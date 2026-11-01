-- Pure display projection. The caller supplies current, authoritative values;
-- this module never reads native objects or changes health, effects or defense.
local M={}
local DEFENSE_PER_HALF=10.28196
local RED_KEYS={'heart/container','heart/full','heart/half'}
local HEART_KEYS={'heart/container','heart/full','heart/half','heart/absorbing_full','heart/absorbing_half'}
local ARMOR_KEYS={'armor_full','armor_half','armor_empty'}
local function finite(value)
  return type(value)=='number' and value==value and math.abs(value)<math.huge
end
local function integer(value)
  return finite(value) and value%1==0 and math.abs(value)<2^53
end
local function unavailable(reason) return {valid=false,drawable=false,reason=reason} end
local function result(reason)
  return {drawable=false,suppressed=false,partial=false,full_health_replacement_ready=false,
    replace_native_health=false,replace_native_armor=false,red_health=unavailable(reason),
    absorption=unavailable(reason),health=unavailable(reason),armor=unavailable(reason)}
end
function M.project(snapshot,expected_epoch)
  local out=result('status-snapshot-unavailable')
  if type(snapshot)~='table' then return out end
  if not integer(expected_epoch) or expected_epoch<0 then
    return result('current-status-epoch-required')
  end
  if not integer(snapshot.epoch) or snapshot.epoch~=expected_epoch then return result('stale-status-snapshot') end
  if snapshot.mode=='creative' or snapshot.creative==true or snapshot.invulnerable==true then
    out=result('status-mode-hidden');out.suppressed=true;return out
  end
  if type(snapshot.creative)~='boolean' or type(snapshot.invulnerable)~='boolean' then
    return result('status-visibility-authority-required')
  end
  if snapshot.health_authoritative~=true then out.red_health=unavailable('health-authority-required')
  elseif not finite(snapshot.hp) or not finite(snapshot.max_hp) or snapshot.max_hp<=0 then
    out.red_health=unavailable('invalid-health-values')
  else
    -- Use the actual valid max_hp, never replace missing/zero maximum with one.
    local red=math.ceil(20*math.max(0,math.min(1,snapshot.hp/snapshot.max_hp)))
    if snapshot.hp>0 then red=math.max(1,red) end -- positive subnormal ratios too
    out.red_health={valid=true,drawable=false,half_units=red}
  end
  if not out.red_health.valid then out.absorption=unavailable('health-context-unavailable')
  elseif snapshot.absorption_authoritative~=true then out.absorption=unavailable('absorption-authority-required')
  elseif not finite(snapshot.absorption_hp) or snapshot.absorption_hp<0 then
    out.absorption=unavailable('invalid-absorption-value')
  else
    -- Fixed upstream gold display: max(1,max_hp), at most four gold hearts.
    local ratio=snapshot.absorption_hp/math.max(1,snapshot.max_hp)
    local gold=math.ceil(20*math.min(.4,ratio))
    if snapshot.absorption_hp>0 then gold=math.max(1,gold) end
    out.absorption={valid=true,drawable=false,half_units=gold,capped=ratio>.4}
  end
  if out.red_health.valid and out.absorption.valid then
    out.health={valid=true,drawable=false,red_half_units=out.red_health.half_units,
      gold_half_units=out.absorption.half_units,gold_capped=out.absorption.capped}
  else out.health=unavailable(out.red_health.reason or out.absorption.reason) end
  out.partial=out.red_health.valid and not out.health.valid
  if snapshot.mode~='adventure' then out.armor=unavailable('defense-mapping-unverified')
  elseif snapshot.defense_authoritative~=true then out.armor=unavailable('defense-authority-required')
  elseif not finite(snapshot.defense) then out.armor=unavailable('invalid-defense-value')
  else
    local units=math.ceil(math.max(0,math.min(20,snapshot.defense/DEFENSE_PER_HALF)))
    if snapshot.defense>0 then units=math.max(1,units) end
    out.armor={valid=true,drawable=false,half_units=units,visible=units>0,
      capped=snapshot.defense>20*DEFENSE_PER_HALF}
  end
  return out
end
local function missing_sprite(sprites,keys)
  if type(sprites)~='table' then return 'player-status-sprites-unavailable' end
  for _,key in ipairs(keys) do
    local path=sprites[key]
    if type(path)~='string' or not path:match('%.png$') or path:find('\0',1,true)
        or path:find('..',1,true) or path:find(':',1,true) or path:match('^[/\\]') then
      return 'missing-or-invalid-status-sprite:'..key
    end
  end
end
function M.draw(snapshot,sprites,hotbar,scale,options)
  options=options or {}
  if type(options)~='table' then return {},result('invalid-status-options') end
  local out=M.project(snapshot,options.expected_epoch)
  if type(hotbar)~='table' or not integer(hotbar.left) or not integer(hotbar.top)
      or hotbar.left<0 or hotbar.top<0 or not integer(scale) or scale<1
      or not integer(hotbar.left+182*scale) or not integer(hotbar.top-46*scale) then
    out.reason='invalid-status-layout';return {},out
  end
  out.scale=scale;out.occupied_top=hotbar.top
  local function name_space()
    -- Eight pixels of text plus its one-pixel shadow, then three pixels clear.
    out.name_height=9*scale
    local top=out.occupied_top-12*scale
    out.name_fits=top>=0
    out.name_top=out.name_fits and top or nil
  end
  name_space()
  if options.visible==false then
    out.suppressed=true;out.reason='host-status-hidden';return {},out
  end
  local diagnostic=options.diagnostic_red_only==true
  if out.suppressed or not (diagnostic and out.red_health.valid or out.health.valid) then return {},out end
  local missing=missing_sprite(sprites,diagnostic and RED_KEYS or HEART_KEYS)
  if missing then out.reason=missing;out.red_health.reason=missing;out.health.reason=missing;return {},out end
  -- Zero here only omits a diagnostic row; an unknown absorption result stays
  -- invalid with no half_units field and never becomes an authoritative zero.
  local gold=not diagnostic and out.absorption.half_units or 0
  local armor_visible=not diagnostic and out.armor.valid and out.armor.visible
  if armor_visible then
    missing=missing_sprite(sprites,ARMOR_KEYS)
    if missing then out.armor.reason=missing;armor_visible=false end
  end
  local red_y=hotbar.top-14*scale
  local gold_y=hotbar.top-24*scale
  local armor_y=hotbar.top-(gold>0 and 34 or 24)*scale
  local top=armor_visible and armor_y or (gold>0 and gold_y or red_y)
  if top<0 then out.reason='status-layout-above-viewport';return {},out end
  local draw={}
  local function image(key,index,y)
    draw[#draw+1]={texture=sprites[key],x=hotbar.left+index*8*scale,y=y,w=9*scale,h=9*scale}
  end
  local function hearts(units,count,y,full,half)
    for i=0,count-1 do
      image('heart/container',i,y)
      if units>i*2 then image(units>i*2+1 and full or half,i,y) end
    end
  end
  hearts(out.red_health.half_units,10,red_y,'heart/full','heart/half')
  if gold>0 then
    hearts(gold,math.ceil(gold/2),gold_y,
      'heart/absorbing_full','heart/absorbing_half')
  end
  if armor_visible then
    for i=0,9 do
      image(out.armor.half_units>i*2+1 and 'armor_full' or
        (out.armor.half_units>i*2 and 'armor_half' or 'armor_empty'),i,armor_y)
    end
  end
  out.drawable=true;out.red_health.drawable=true
  if diagnostic then out.partial=true;out.diagnostic_red_only=true
  else
    -- Readiness describes these commands only. The host must confirm rendering
    -- and own a reversible visibility lease before hiding any native element.
    out.health.drawable=true;out.absorption.drawable=true;out.full_health_replacement_ready=true
    out.replace_native_health=true
    out.armor.drawable=out.armor.valid and not out.armor.reason
    out.replace_native_armor=out.armor.drawable
  end
  out.occupied_top=top
  out.bounds={x=hotbar.left,y=top,w=81*scale,h=red_y+9*scale-top}
  out.rows={red=red_y,gold=gold>0 and gold_y or nil,
    armor=armor_visible and armor_y or nil}
  name_space()
  return draw,out
end
return M
