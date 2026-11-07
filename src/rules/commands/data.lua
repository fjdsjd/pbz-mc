-- Bounded NBT-like command data. Candidates are isolated until one host commit.
local syntax = require('rules.commands.syntax')
local state = require('storage.state')
local encode = require('storage.canonical_json')
local M = {}
local MAX_BYTES, MAX_DEPTH = 2 * 1024 * 1024, 16

local function kind(value)
  return type(value) == 'table' and state.json_kind(value) or type(value)
end

local function object() return state.object() end
local function array() return setmetatable({}, {__jsontype = 'array'}) end

local function equal(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= 'table' then return a == b end
  if kind(a) ~= kind(b) then return false end
  for key, value in pairs(a) do if not equal(value, b[key]) then return false end end
  for key in pairs(b) do if a[key] == nil then return false end end
  return true
end

local function validate(value)
  local seen = {}
  local function visit(node, depth)
    assert(depth < MAX_DEPTH, 'data-depth-limit')
    if type(node) ~= 'table' then return end
    assert(not seen[node], 'cyclic-command-data'); seen[node] = true
    for _, child in pairs(node) do
      -- Vanilla 26.3 ListTag permits heterogeneous elements.
      visit(child, depth + 1)
    end
    seen[node] = nil
  end
  visit(value, 0)
  assert(#encode(value) <= MAX_BYTES, 'command-data-limit')
  return value
end

local function literal(raw)
  assert(type(raw) == 'string' and #raw <= MAX_BYTES, 'data-value-required-or-too-large')
  -- The persisted JSON representation has no byte/int/long-array identity.
  -- Reject those explicitly rather than silently changing a typed NBT array.
  local quoted, escaped
  for index = 1, #raw do
    local char = raw:sub(index, index)
    if quoted then
      if escaped then escaped = false elseif char == '\\' then escaped = true elseif char == quoted then quoted = nil end
    elseif char == '"' or char == "'" then quoted = char
    elseif char == '[' then
      assert(not raw:sub(index + 1):match('^%s*[BIL]%s*;'), 'typed-nbt-arrays-unavailable')
    end
  end
  return validate(syntax.snbt(raw))
end

local function subset(pattern, value)
  if type(pattern) ~= 'table' then return pattern == value end
  if kind(pattern) ~= kind(value) then return false end
  if kind(pattern) == 'array' then
    if #pattern == 0 then return #value == 0 end
    for _, expected in ipairs(pattern) do
      local found = false
      for _, actual in ipairs(value) do if subset(expected, actual) then found = true; break end end
      if not found then return false end
    end
  else
    for key, expected in pairs(pattern) do if not subset(expected, value[key]) then return false end end
  end
  return true
end

local function balanced(raw, first, opening, closing)
  local depth, quote, escaped = 0
  for index = first, #raw do
    local char = raw:sub(index, index)
    if quote then
      if escaped then escaped = false elseif char == '\\' then escaped = true elseif char == quote then quote = nil end
    elseif char == '"' or char == "'" then quote = char
    elseif char == opening then depth = depth + 1
    elseif char == closing then
      depth = depth - 1
      if depth == 0 then return raw:sub(first, index), index + 1 end
    end
  end
  error('unfinished-data-path', 0)
end

local function quoted_key(raw, first)
  local quote, escaped = raw:sub(first, first)
  for index = first + 1, #raw do
    local char = raw:sub(index, index)
    if escaped then escaped = false elseif char == '\\' then escaped = true
    elseif char == quote then return syntax.string(raw:sub(first, index)), index + 1 end
  end
  error('unfinished-data-path-key', 0)
end

local function path(raw)
  assert(type(raw) == 'string' and #raw > 0 and #raw <= 32767, 'data-path-required')
  local nodes, index, expect_key = {}, 1, true
  while index <= #raw do
    local char = raw:sub(index, index)
    if char == '.' then
      assert(not expect_key and index < #raw, 'invalid-data-path-separator')
      expect_key = true; index = index + 1
    elseif char == '[' then
      assert(not expect_key, 'data-path-key-required')
      local token; token, index = balanced(raw, index, '[', ']')
      local body = token:sub(2, -2):match('^%s*(.-)%s*$')
      if body == '' then nodes[#nodes + 1] = {type = 'all'}
      elseif body:sub(1, 1) == '{' then
        local pattern = literal(body)
        assert(kind(pattern) == 'object', 'data-path-compound-required')
        nodes[#nodes + 1] = {type = 'list_match', pattern = pattern}
      else
        assert(body:match('^%-?%d+$'), 'invalid-data-path-index')
        nodes[#nodes + 1] = {type = 'index', index = syntax.number(body, -2147483648, 2147483647, true)}
      end
    elseif char == '{' then
      assert(not expect_key or #nodes == 0, 'data-path-key-required')
      local token; token, index = balanced(raw, index, '{', '}')
      local pattern = literal(token)
      assert(kind(pattern) == 'object', 'data-path-compound-required')
      nodes[#nodes + 1] = {type = 'match', pattern = pattern}; expect_key = false
    else
      assert(expect_key, 'data-path-separator-required')
      local key
      if char == '"' or char == "'" then key, index = quoted_key(raw, index)
      else
        local first = index
        while index <= #raw and not raw:sub(index, index):match('[%.%[%]{}%s"\']') do index = index + 1 end
        assert(index > first, 'invalid-data-path-key')
        key = raw:sub(first, index - 1)
      end
      assert(#key > 0, 'empty-data-path-key')
      nodes[#nodes + 1] = {type = 'key', key = key}; expect_key = false
    end
    assert(#nodes <= MAX_DEPTH, 'data-path-depth-limit')
  end
  assert(not expect_key and #nodes > 0, 'invalid-data-path')
  return nodes
end

local function default_value(next_node, final_kind)
  if next_node then
    if next_node.type == 'all' or next_node.type == 'index' or next_node.type == 'list_match' then return array() end
    if next_node.type == 'match' then return state.clone(next_node.pattern) end
    return object()
  end
  if final_kind == 'array' then return array() end
  if final_kind == 'object' then return object() end
end

local function references(engine, root, nodes, create, final_kind)
  local wrapper = {root = root}
  local current = {{parent = wrapper, key = 'root', value = root, root = true}}
  for position, node in ipairs(nodes) do
    local result = {}
    local function add(parent, key)
      result[#result + 1] = {parent = parent, key = key, value = parent[key]}
    end
    for _, reference in ipairs(current) do
      engine:spend()
      local value = reference.value
      if node.type == 'key' and kind(value) == 'object' then
        if value[node.key] == nil and create then value[node.key] = default_value(nodes[position + 1], final_kind) end
        if value[node.key] ~= nil or create and position == #nodes then add(value, node.key) end
      elseif node.type == 'match' then
        if subset(node.pattern, value) then result[#result + 1] = reference end
      elseif kind(value) == 'array' then
        if node.type == 'index' then
          local index = node.index < 0 and #value + node.index + 1 or node.index + 1
          if index >= 1 and index <= #value then add(value, index) end
        elseif node.type == 'all' then
          if #value == 0 and create then
            value[1] = default_value(nodes[position + 1], final_kind)
            add(value, 1)
          else
            for index in ipairs(value) do engine:spend(); add(value, index) end
          end
        elseif node.type == 'list_match' then
          local matched = false
          for index, item in ipairs(value) do
            engine:spend()
            if subset(node.pattern, item) then add(value, index); matched = true end
          end
          if not matched and create then
            value[#value + 1] = state.clone(node.pattern); add(value, #value)
          end
        end
      end
    end
    current = result
    if #current == 0 then break end
  end
  return current
end

local function resource_id(raw)
  assert(raw, 'data-storage-id-required')
  local id = syntax.id(raw)
  assert(id:match('^[a-z0-9_.%-]+:[a-z0-9_/.%-]+$'), 'invalid-storage-id')
  return id
end

local function accessor(engine, args, index, context)
  local target_type = args[index]
  if target_type == 'storage' then
    local id = resource_id(args[index + 1])
    return {
      read = function() return engine:state().storage[id] or object() end,
      write = function(value)
        engine:edit(function(s) s.storage[id] = state.clone(value); return 1 end)
      end,
    }, index + 2
  end
  if target_type == 'entity' then
    local target = engine:select(assert(args[index + 1], 'data-entity-required'), context, true)[1]
    return {
      read = function()
        local read = assert(engine.host.entities.read_data, 'entity-data-unavailable')
        local value, why = read(engine.host.entities, target)
        assert(type(value) == 'table', why or 'entity-data-unavailable')
        return value
      end,
      write = function(value)
        assert(not target.player, 'player-data-write-unavailable')
        engine:mutate('write_data', target, value, {replace = true})
      end,
    }, index + 2
  end
  if target_type == 'block' then
    local position, next_index = syntax.position(args, index + 1, context)
    for key, value in pairs(position) do position[key] = math.floor(value) end
      local expected
    return {
        read = function()
          local value;value,expected=engine:call('block_data', position);return value
        end,
        write = function(value) engine:call('write_block_data', position, value, expected) end,
    }, next_index
  end
  error('usage:data target must be storage|entity|block', 0)
end

local function read_target(target)
  local value = validate(target.read())
  assert(kind(value) == 'object', 'data-target-compound-required')
  return state.clone(value)
end

local function merge(destination, patch)
  assert(kind(destination) == 'object' and kind(patch) == 'object', 'data-merge-compound-required')
  for key, value in pairs(patch) do
    if kind(value) == 'object' and kind(destination[key]) == 'object' then merge(destination[key], value)
    else destination[key] = state.clone(value) end
  end
end

local function string_boundaries(value)
  local length, offsets = 0, {[0] = 1}
  for index, codepoint in utf8.codes(value) do
    offsets[length] = index
    length = length + (codepoint > 65535 and 2 or 1)
  end
  offsets[length] = #value + 1
  return length, offsets
end

local function substring(value, first, last)
  local length, offsets = string_boundaries(value)
  first, last = first or 0, last or length
  if first < 0 then first = length + first end
  if last < 0 then last = length + last end
  assert(first >= 0 and last >= first and last <= length, 'invalid-data-substring')
  assert(offsets[first] and offsets[last], 'data-substring-splits-surrogate-unavailable')
  return value:sub(offsets[first], offsets[last] - 1)
end

local function source_values(engine, args, index, context)
  local source_type = args[index]
  if source_type == 'value' then
    assert(args[index + 1] and not args[index + 2], 'data-value-required-or-extra-arguments')
    return {literal(args[index + 1])}
  end
  assert(source_type == 'from' or source_type == 'string', 'data-source-type-unavailable:' .. tostring(source_type))
  local source, next_index = accessor(engine, args, index + 1, context)
  local data, values = read_target(source), {}
  if args[next_index] then
    local found = references(engine, data, path(args[next_index]), false)
    assert(#found > 0, 'data-source-path-not-found')
    for _, item in ipairs(found) do values[#values + 1] = state.clone(item.value) end
    next_index = next_index + 1
  else values[1] = data end
  if source_type == 'from' then assert(not args[next_index], 'data-extra-arguments'); return values end
  local first = args[next_index] and syntax.number(args[next_index], -2147483648, 2147483647, true)
  local last = args[next_index + 1] and syntax.number(args[next_index + 1], -2147483648, 2147483647, true)
  assert(not args[next_index + 2], 'data-extra-arguments')
  for index, value in ipairs(values) do
    assert(type(value) ~= 'table', 'data-string-source-must-be-scalar')
    local text = type(value) == 'string' and value or encode(value)
    values[index] = substring(text, first, last)
  end
  return values
end

local function measured(value, scale)
  if scale then
    assert(type(value) == 'number' or type(value) == 'boolean', 'data-scale-requires-number')
  end
  if type(value) == 'number' or type(value) == 'boolean' then
    local number = type(value) == 'boolean' and (value and 1 or 0) or value
    number = number * (scale or 1)
    assert(number == number and math.abs(number) < math.huge, 'data-result-overflow')
    return math.max(-2147483648, math.min(2147483647, math.floor(number)))
  end
  if type(value) == 'string' then return string_boundaries(value) end
  local size = 0
  for _ in pairs(value) do size = size + 1 end
  return size
end

local function remove(found)
  local groups, changed = {}, 0
  for _, reference in ipairs(found) do
    if not reference.root then
      local group = groups[reference.parent]
      if not group then group = {}; groups[reference.parent] = group end
      group[reference.key] = true
    end
  end
  for parent, group in pairs(groups) do
    if kind(parent) == 'array' then
      local indices = {}
      for index in pairs(group) do indices[#indices + 1] = index end
      table.sort(indices, function(a, b) return a > b end)
      for _, index in ipairs(indices) do table.remove(parent, index); changed = changed + 1 end
    else
      for key in pairs(group) do parent[key] = nil; changed = changed + 1 end
    end
  end
  return changed
end

local function modify(engine, candidate, nodes, operation, values, insertion)
  local expected = operation == 'merge' and 'object' or operation ~= 'set' and 'array' or nil
  local found = references(engine, candidate, nodes, true, expected)
  assert(#found > 0, 'data-target-path-not-found')
  local changed = 0
  if operation == 'merge' then
    local combined = object()
    for _, value in ipairs(values) do merge(combined, value) end
    for _, reference in ipairs(found) do
      local before = state.clone(reference.value)
      merge(reference.value, combined)
      if not equal(before, reference.value) then changed = changed + 1 end
    end
  elseif operation == 'set' then
    local value = values[#values]
    for _, reference in ipairs(found) do
      assert(not reference.root, 'data-root-replacement-unavailable')
      if not equal(reference.value, value) then
        reference.parent[reference.key] = state.clone(value); changed = changed + 1
      end
    end
  else
    for _, reference in ipairs(found) do
      local list = reference.value
      assert(kind(list) == 'array', 'data-insert-list-required')
      local index = operation == 'append' and #list or operation == 'prepend' and 0 or insertion
      if index < 0 then index = #list + index + 1 end
      assert(index >= 0 and index <= #list, 'data-insertion-index-out-of-range')
      for offset, value in ipairs(values) do
        engine:spend(); table.insert(list, index + offset, state.clone(value))
      end
      if #values > 0 then changed = changed + 1 end
    end
  end
  return changed
end

function M.data(engine, args, context)
  local action = args[1]
  assert(action == 'get' or action == 'merge' or action == 'remove' or action == 'modify', 'unknown-data-action:' .. tostring(action))
  local target, index = accessor(engine, args, 2, context)
  local original = read_target(target)
  if action == 'get' then
    if not args[index] then return 1, encode(original), true end
    local found = references(engine, original, path(args[index]), false)
    assert(#found == 1, #found == 0 and 'data-path-not-found' or 'data-path-matches-multiple-values')
    local scale = args[index + 1] and syntax.number(args[index + 1])
    assert(not args[index + 2], 'data-extra-arguments')
    return measured(found[1].value, scale), encode(found[1].value), true
  end
  local candidate, changed = state.clone(original), 0
  if action == 'merge' then
    assert(args[index] and not args[index + 1], 'usage:data merge target compound')
    merge(candidate, literal(args[index]))
    changed = not equal(original, candidate) and 1 or 0
  elseif action == 'remove' then
    assert(args[index] and not args[index + 1], 'usage:data remove target path')
    changed = remove(references(engine, candidate, path(args[index]), false))
  else
    local nodes = path(args[index])
    local operation, insertion = args[index + 1]
    assert(operation == 'set' or operation == 'merge' or operation == 'append'
      or operation == 'prepend' or operation == 'insert', 'data-modification-unavailable:' .. tostring(operation))
    index = index + 2
    if operation == 'insert' then
      insertion = syntax.number(assert(args[index], 'data-insert-index-required'), -2147483648, 2147483647, true)
      index = index + 1
    end
    local values = source_values(engine, args, index, context)
    changed = modify(engine, candidate, nodes, operation, values, insertion)
  end
  assert(changed > 0 and not equal(original, candidate), 'data-unchanged')
  validate(candidate)
  target.write(candidate)
  return changed, nil, true
end

-- Execute conditions and result stores use the identical data boundary. The
-- engine omits underscore-prefixed exports from its command handler table.
M._accessor = accessor
M._read = read_target
M._path = path
M._references = references
M._validate = validate
function M._write_path(engine, target, raw_path, value)
  validate(value)
  local original = read_target(target)
  local candidate = state.clone(original)
  local changed = modify(engine, candidate, path(raw_path), 'set', {value})
  validate(candidate)
  if changed > 0 and not equal(original, candidate) then target.write(candidate); return changed end
  return 0
end

return M
