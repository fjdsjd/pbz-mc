-- Command-owned scoreboard and team metadata. Every batch commits once.
local syntax = require('rules.commands.syntax')
local state = require('storage.state')
local encode = require('storage.canonical_json')
local M = {}
local MIN, MAX = -2147483648, 2147483647
local colors = {}
for name in ('black dark_blue dark_green dark_aqua dark_red dark_purple gold gray dark_gray blue green aqua red light_purple yellow white reset'):gmatch('%S+') do
  colors[name] = true
end

local function count(map)
  local result = 0
  for _ in pairs(map or {}) do result = result + 1 end
  return result
end

local function names(map)
  local result = {}
  for key in pairs(map or {}) do result[#result + 1] = key end
  table.sort(result)
  return result
end

local function integer(raw, minimum)
  return assert(math.tointeger(syntax.number(raw, minimum or MIN, MAX, true)), 'invalid-score-integer')
end

local function wrap(value)
  -- All operands are Lua integers. Even an int32 product fits in int64.
  return (value + 2147483648) % 4294967296 - 2147483648
end

local function identifier(raw, kind)
  assert(type(raw) == 'string' and #raw > 0 and #raw <= 128
    and raw:match('^[%w_.+%-]+$'), 'invalid-' .. kind .. '-name')
  return raw
end

local function component(raw)
  assert(raw, 'text-component-required')
  local value = syntax.snbt(raw)
  assert(type(value) == 'string' or type(value) == 'table', 'invalid-text-component')
  assert(#encode(value) <= 32767, 'text-component-too-large')
  return value
end

local function same(a, b)
  if a == nil or b == nil then return a == b end
  return encode(a) == encode(b)
end

local function objective(s, name)
  return assert(s.objectives[assert(name, 'objective-required')], 'unknown-objective:' .. tostring(name))
end

local function holders(engine, raw, context, multiple)
  local result = engine:score_holder(assert(raw, 'score-holder-required'), context, multiple)
  assert(#result > 0, 'no-score-holders-found')
  assert(multiple or #result == 1, 'expected-one-score-holder')
  return result
end

local function writable(s, name)
  local row = objective(s, name)
  assert(row.criteria == 'dummy' or row.criteria == 'trigger', 'objective-read-only:' .. name)
  return row
end

local function score(s, holder, name)
  local row = s.scores[holder]
  if not row then row = {}; s.scores[holder] = row end
  if row[name] == nil then row[name] = 0 end
  row[name] = integer(row[name])
  return row
end

local function number_format(args, index)
  local kind = args[index]
  if not kind then return nil end
  assert(kind == 'blank' or kind == 'fixed' or kind == 'styled', 'invalid-score-number-format')
  if kind == 'blank' then
    assert(not args[index + 1], 'scoreboard-extra-arguments')
    return {type = kind}
  end
  assert(args[index + 1] and not args[index + 2], 'score-number-format-value-required')
  local value = kind == 'fixed' and component(args[index + 1]) or syntax.snbt(args[index + 1])
  assert(kind ~= 'styled' or type(value) == 'table' and state.json_kind(value) == 'object', 'score-style-compound-required')
  return {type = kind, value = value}
end

local function objectives(engine, args)
  local action, name = args[2], args[3]
  if action == 'list' then
    assert(not name, 'scoreboard-extra-arguments')
    local list = names(engine:state().objectives)
    return #list, table.concat(list, ', '), true
  end
  if action == 'setdisplay' then
    local slot = assert(name, 'score-display-slot-required')
    local color = slot:match('^sidebar%.team%.(.+)$')
    assert(slot == 'list' or slot == 'sidebar' or slot == 'belowname'
      or color and colors[color] and color ~= 'reset', 'invalid-score-display-slot')
    assert(not args[5], 'scoreboard-extra-arguments')
    local result = engine:edit(function(s)
      if args[4] then objective(s, args[4]) end
      s.score_display = s.score_display or {}
      assert(s.score_display[slot] ~= args[4], 'score-display-unchanged')
      s.score_display[slot] = args[4]
      return 1
    end)
    return result, '记分板显示设置已记录', true
  end
  identifier(name, 'objective')
  if action == 'add' then
    local criteria = assert(args[4], 'objective-criteria-required')
    assert(criteria == 'dummy' or criteria == 'trigger', 'objective-criteria-requires-unavailable-system:' .. criteria)
    assert(not args[6], 'scoreboard-extra-arguments')
    local display = args[5] and component(args[5]) or name
    local result = engine:edit(function(s)
      assert(not s.objectives[name], 'objective-already-exists:' .. name)
      s.objectives[name] = {criteria = criteria, display_name = display,
        render_type = 'integer', display_auto_update = false, enabled = {}}
      return count(s.objectives)
    end)
    return result, nil, true
  end
  if action == 'remove' then
    assert(not args[4], 'scoreboard-extra-arguments')
    return engine:edit(function(s)
      objective(s, name)
      s.objectives[name] = nil
      for holder, row in pairs(s.scores) do
        engine:spend()
        row[name] = nil
        if not next(row) then s.scores[holder] = nil end
      end
      for slot, selected in pairs(s.score_display or {}) do
        if selected == name then s.score_display[slot] = nil end
      end
      return count(s.objectives)
    end), nil, true
  end
  assert(action == 'modify', 'unknown-scoreboard-objectives-action:' .. tostring(action))
  local option, field, value = args[4]
  if option == 'displayname' then field, value = 'display_name', component(args[5])
  elseif option == 'rendertype' then
    assert(args[5] == 'integer' or args[5] == 'hearts', 'invalid-score-render-type')
    field, value = 'render_type', args[5]
  elseif option == 'displayautoupdate' then
    assert(args[5] == 'true' or args[5] == 'false', 'invalid-boolean')
    field, value = 'display_auto_update', args[5] == 'true'
  elseif option == 'numberformat' then field, value = 'number_format', number_format(args, 5)
  else error('score-objective-option-unavailable:' .. tostring(option), 0) end
  assert(option == 'numberformat' or not args[6], 'scoreboard-extra-arguments')
  return engine:edit(function(s)
    local row = objective(s, name)
    assert(not same(row[field], value), 'objective-option-unchanged')
    row[field] = value
    return 1
  end), '记分板显示元数据已更新', true
end

local operations = {
  ['='] = function(_, b) return b end,
  ['+='] = function(a, b) return wrap(a + b) end,
  ['-='] = function(a, b) return wrap(a - b) end,
  ['*='] = function(a, b) return wrap(a * b) end,
  ['/='] = function(a, b) assert(b ~= 0, 'score-division-by-zero'); return wrap(a // b) end,
  ['%='] = function(a, b) assert(b ~= 0, 'score-division-by-zero'); return a % b end,
  ['<'] = math.min,
  ['>'] = math.max,
}

local function players(engine, args, context)
  local action = args[2]
  if action == 'list' then
    assert(not args[4], 'scoreboard-extra-arguments')
    if not args[3] then
      local list = names(engine:state().scores)
      return #list, table.concat(list, ', '), true
    end
    local target = holders(engine, args[3], context, false)[1]
    local scores = engine:state().scores[target] or {}
    local list = {}
    for _, name in ipairs(names(scores)) do list[#list + 1] = name .. '=' .. scores[name] end
    return #list, target .. ': ' .. table.concat(list, ', '), true
  end
  assert(action == 'get' or action == 'set' or action == 'add' or action == 'remove'
    or action == 'reset' or action == 'enable' or action == 'operation', 'score-player-action-unavailable:' .. tostring(action))
  local selected = holders(engine, args[3], context, action ~= 'get')
  local name = args[4]
  if action == 'get' then
    assert(not args[5], 'scoreboard-extra-arguments')
    objective(engine:state(), name)
    local value = (engine:state().scores[selected[1]] or {})[name]
    assert(value ~= nil, 'score-not-set:' .. selected[1] .. ':' .. name)
    return integer(value), selected[1] .. ' ' .. name .. ' = ' .. value, true
  end
  if action == 'reset' then
    assert(not args[5], 'scoreboard-extra-arguments')
    return engine:edit(function(s)
      if name then objective(s, name) end
      for _, holder in ipairs(selected) do
        engine:spend()
        if not name then s.scores[holder] = nil
        elseif s.scores[holder] then
          s.scores[holder][name] = nil
          if not next(s.scores[holder]) then s.scores[holder] = nil end
        end
        for objective_name, row in pairs(s.objectives) do
          if not name or objective_name == name then (row.enabled or {})[holder] = nil end
        end
      end
      return #selected
    end), nil, true
  end
  if action == 'enable' then
    assert(not args[5], 'scoreboard-extra-arguments')
    return engine:edit(function(s)
      local row = objective(s, name)
      assert(row.criteria == 'trigger', 'objective-is-not-trigger')
      row.enabled = row.enabled or {}
      local changed = 0
      for _, holder in ipairs(selected) do
        engine:spend()
        score(s, holder, name)
        if not row.enabled[holder] then row.enabled[holder] = true; changed = changed + 1 end
      end
      assert(changed > 0, 'trigger-already-enabled')
      return changed
    end), nil, true
  end
  if action == 'operation' then
    assert(args[7] and not args[8], 'usage:scoreboard players operation targets objective operation source sourceObjective')
    local operation, source_name = args[5], args[7]
    assert(operations[operation] or operation == '><', 'invalid-score-operation')
    local sources = holders(engine, args[6], context, true)
    return engine:edit(function(s)
      writable(s, name)
      if operation == '><' then writable(s, source_name) else objective(s, source_name) end
      local total = 0
      for _, holder in ipairs(selected) do
        local target = score(s, holder, name)
        for _, source_holder in ipairs(sources) do
          engine:spend()
          local source = score(s, source_holder, source_name)
          if operation == '><' then target[name], source[source_name] = source[source_name], target[name]
          else target[name] = operations[operation](target[name], source[source_name]) end
        end
        total = wrap(total + target[name])
      end
      return total
    end), nil, true
  end
  local amount = integer(assert(args[5], 'score-value-required'), action == 'set' and MIN or 0)
  assert(not args[6], 'scoreboard-extra-arguments')
  return engine:edit(function(s)
    writable(s, name)
    local total = 0
    for _, holder in ipairs(selected) do
      engine:spend()
      local row = score(s, holder, name)
      if action == 'set' then row[name] = amount
      elseif action == 'add' then row[name] = wrap(row[name] + amount)
      else row[name] = wrap(row[name] - amount) end
      total = wrap(total + row[name])
    end
    return total
  end), nil, true
end

function M.scoreboard(engine, args, context)
  if args[1] == 'objectives' then return objectives(engine, args) end
  assert(args[1] == 'players', 'usage:scoreboard objectives|players')
  return players(engine, args, context)
end

local function team(s, name)
  return assert(s.teams[assert(name, 'team-required')], 'unknown-team:' .. tostring(name))
end

function M.team(engine, args, context)
  local action, name = args[1], args[2]
  if action == 'list' then
    assert(not args[3], 'team-extra-arguments')
    local list = {}
    if name then
      team(engine:state(), name)
      for member, selected in pairs(engine:state().members) do
        if selected == name then list[#list + 1] = member end
      end
      table.sort(list)
    else list = names(engine:state().teams) end
    return #list, table.concat(list, ', '), true
  end
  if action == 'add' then
    identifier(name, 'team')
    assert(not args[4], 'team-extra-arguments')
    local display = args[3] and component(args[3]) or name
    return engine:edit(function(s)
      assert(not s.teams[name], 'team-already-exists:' .. name)
      s.teams[name] = {display_name = display, color = 'reset', prefix = '', suffix = ''}
      return count(s.teams)
    end), nil, true
  end
  if action == 'remove' or action == 'empty' then
    assert(not args[3], 'team-extra-arguments')
    return engine:edit(function(s)
      team(s, name)
      local changed = 0
      for member, selected in pairs(s.members) do
        engine:spend()
        if selected == name then s.members[member] = nil; changed = changed + 1 end
      end
      if action == 'remove' then s.teams[name] = nil; return count(s.teams) end
      assert(changed > 0, 'team-already-empty')
      return changed
    end), nil, true
  end
  if action == 'join' or action == 'leave' then
    assert(not args[action == 'join' and 4 or 3], 'team-extra-arguments')
    local raw = action == 'join' and (args[3] or '@s') or assert(name, 'team-members-required')
    local selected = holders(engine, raw, context, true)
    return engine:edit(function(s)
      if action == 'join' then team(s, name) end
      local changed = 0
      for _, member in ipairs(selected) do
        engine:spend()
        local destination = action == 'join' and name or nil
        if s.members[member] ~= destination then
          s.members[member] = destination; changed = changed + 1
        end
      end
      assert(changed > 0, 'team-membership-unchanged')
      return changed
    end), nil, true
  end
  assert(action == 'modify', 'unknown-team-action:' .. tostring(action))
  assert(args[4] and not args[5], 'usage:team modify team option value')
  local option, field, value = args[3]
  if option == 'color' then
    assert(colors[args[4]], 'invalid-team-color'); field, value = 'color', args[4]
  elseif option == 'displayName' then field, value = 'display_name', component(args[4])
  elseif option == 'prefix' or option == 'suffix' then field, value = option, component(args[4])
  else error('team-option-requires-unavailable-host-system:' .. tostring(option), 0) end
  return engine:edit(function(s)
    local row = team(s, name)
    assert(not same(row[field], value), 'team-option-unchanged')
    row[field] = value
    return 1
  end), '队伍显示元数据已更新', true
end

return M
