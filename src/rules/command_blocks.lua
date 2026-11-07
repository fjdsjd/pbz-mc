-- Vanilla command-block scheduling on explicit logical ticks. Host commands may
-- finish asynchronously; callbacks enqueue work and never recurse into execute.
local directions = require('rules.block_directions')
local M = {}
local Scheduler = {}; Scheduler.__index = Scheduler
local modes = {command_block = 'impulse', repeating_command_block = 'repeat', chain_command_block = 'chain',
  impulse = 'impulse', ['repeat'] = 'repeat', chain = 'chain'}

local function properties(record) return record.properties or record end
local function mode(record)
  return record and modes[record.kind or (record.content_id or ''):match(':(.+)$') or record.content_id]
end
local function integer(value, minimum, maximum)
  return type(value) == 'number' and value % 1 == 0 and value >= minimum and value <= maximum
end
local function before(a, b)
  return a.due < b.due or a.due == b.due and a.serial < b.serial
end
local function push(heap, event)
  local index = #heap + 1
  while index > 1 do
    local parent = index // 2
    if not before(event, heap[parent]) then break end
    heap[index] = heap[parent]; index = parent
  end
  heap[index] = event
end
local function pop(heap)
  local first, last = heap[1], table.remove(heap)
  if #heap > 0 then
    local index = 1
    while index * 2 <= #heap do
      local child = index * 2
      if heap[child + 1] and before(heap[child + 1], heap[child]) then child = child + 1 end
      if not before(heap[child], last) then break end
      heap[index] = heap[child]; index = child
    end
    heap[index] = last
  end
  return first
end

function M.new(adapter, options)
  options = options or {}
  assert(type(adapter) == 'table' and type(adapter.get) == 'function'
    and type(adapter.execute) == 'function' and type(adapter.outcome) == 'function', 'command-block-adapter-required')
  local budget, maximum = options.budget or 128, options.max_nodes or 8192
  assert(integer(budget, 1, 65536) and integer(maximum, 1, 65536), 'invalid-command-block-limits')
  return setmetatable({adapter = adapter, vectors = adapter.vectors or directions.vectors,
    budget = budget, max_nodes = maximum, max_pending = options.max_pending or maximum * 2,
    max_chain = options.max_chain or 65536, tick = options.tick or 0, spent = 0, serial = 0,
    nodes = {}, count = 0, heap = {}, ready = {}, head = 1, tail = 0, inflight = 0,
    epoch = 0, executed = 0, last_error = nil}, Scheduler)
end

function Scheduler:_cell(record)
  local source = self.adapter.cell and self.adapter.cell(record) or record.cell or record
  assert(source and directions.integer(source.x) and directions.integer(source.y)
    and directions.integer(source.z), 'command-block-cell-required')
  return {x = source.x, y = source.y, z = source.z}
end

function Scheduler:_facing(record)
  local facing = properties(record).facing or 'north'
  assert(self.vectors[facing], 'invalid-command-block-facing')
  return facing
end

function Scheduler:_relative(cell, facing, amount)
  local vector = assert(self.vectors[facing], 'invalid-command-block-facing')
  amount = amount or 1
  return {x = cell.x + vector.x * amount, y = cell.y + vector.y * amount, z = cell.z + vector.z * amount}
end

function Scheduler:_resolve(node)
  if self.nodes[node.id] ~= node then return nil end
  local record = self.adapter.get(node.cell)
  if not record or record.id ~= node.id or not mode(record) then return nil end
  node.record = record
  return record
end

function Scheduler:_powered(record)
  if self.adapter.powered then return self.adapter.powered(record) == true end
  return properties(record).powered == true
end

function Scheduler:_condition(record)
  if properties(record).conditional ~= true then return true end
  local behind = self.adapter.get(self:_relative(self:_cell(record), self:_facing(record), -1))
  if not mode(behind) then return false end
  local node = self.nodes[behind.id]
  local count = node and node.success_count or tonumber(properties(behind).success_count) or 0
  return count > 0
end

function Scheduler:_schedule(node, sample)
  local record = self:_resolve(node)
  if not record or mode(record) == 'chain' then return end
  if sample then node.condition_met = self:_condition(record) end
  if node.busy then node.retrigger = true; return end
  local due = self.tick + 1
  if node.event and node.event.due <= due then return end
  assert(#self.heap < self.max_pending, 'command-block-event-limit')
  self.serial = self.serial + 1
  local event = {node = node, due = due, serial = self.serial}
  node.event = event; push(self.heap, event)
end

function Scheduler:signal(record_or_id, powered)
  local id = type(record_or_id) == 'table' and record_or_id.id or record_or_id
  local node = self.nodes[id]
  if not node then return false end
  local record = self:_resolve(node)
  if not record then self:remove(id); return false end
  powered = powered == true
  local previous = node.powered
  node.powered = powered
  if powered and not previous and properties(record).auto ~= true and mode(record) ~= 'chain' then
    self:_schedule(node, true)
  end
  return previous ~= powered
end

function Scheduler:upsert(record)
  assert(type(record) == 'table' and type(record.id) == 'string' and #record.id > 0
    and mode(record), 'invalid-command-block-record')
  local cell = self:_cell(record)
  self:_facing(record)
  local node = self.nodes[record.id]
  if node and (node.cell.x ~= cell.x or node.cell.y ~= cell.y or node.cell.z ~= cell.z) then
    self:remove(record.id); node = nil
  end
  local fresh = node == nil
  if fresh then
    assert(self.count < self.max_nodes, 'command-block-node-limit')
    local p = properties(record)
    node = {id = record.id, cell = cell, record = record, powered = false, auto = false,
      mode = mode(record), success_count = tonumber(p.success_count) or 0,
      condition_met = p.condition_met == true, last_output = p.last_output,
      last_tick = tonumber(p.last_execution) or -1}
    self.nodes[node.id] = node; self.count = self.count + 1
  end
  local was_auto, was_mode = node.auto, node.mode
  node.record, node.auto, node.mode = record, properties(record).auto == true, mode(record)
  node.success_count = tonumber(properties(record).success_count) or 0
  local powered = self:_powered(record)
  self:signal(node.id, powered)
  if node.auto and not was_auto and not powered and node.mode ~= 'chain'
    or not fresh and was_mode ~= node.mode and node.mode == 'repeat' and (powered or node.auto)
    or fresh and node.mode == 'repeat' and node.auto then
    self:_schedule(node, true)
  end
  return node
end

function Scheduler:remove(record_or_id)
  local id = type(record_or_id) == 'table' and record_or_id.id or record_or_id
  local node = self.nodes[id]
  if not node then return false end
  self.nodes[id] = nil; self.count = self.count - 1
  node.event = nil
  if node.inflight then
    local chain = node.inflight.chain
    self.inflight = self.inflight - 1; node.inflight = nil
    self:_finish(chain)
  end
  return true
end

function Scheduler:_enqueue(chain)
  if chain.finished or chain.queued then return end
  if self.tail - self.head + 1 >= self.max_pending then
    self.last_error = 'command-block-ready-limit'; self:_finish(chain); return
  end
  chain.queued = true
  self.tail = self.tail + 1; self.ready[self.tail] = chain
end

function Scheduler:_finish(chain)
  if chain.finished then return end
  chain.finished = true
  local node = chain.root
  if chain.epoch ~= self.epoch or self.nodes[node.id] ~= node then return end
  node.busy = false
  local record = self:_resolve(node)
  if not record then self:remove(node.id); return end
  local repeat_active = mode(record) == 'repeat' and (self:_powered(record) or properties(record).auto == true)
  local retrigger = node.retrigger
  node.retrigger = false
  if repeat_active or retrigger and mode(record) ~= 'chain' then self:_schedule(node, false) end
end

function Scheduler:_publish(node, record, success_count, output, preserve_output)
  node.success_count = success_count
  if not preserve_output then node.last_output = output end
  if properties(record).track_output == false then node.last_output = nil end
  if type(node.last_output) == 'string' then node.last_output = node.last_output:sub(1, 32767) end
  local ok, result, why = pcall(self.adapter.outcome, record, success_count, node.last_output,
    {last_execution = node.last_tick, condition_met = node.condition_met, powered = node.powered})
  if not ok or result == false then
    self.last_error = tostring(not ok and result or why or 'command-block-outcome-failed')
    return false
  end
  return true
end

function Scheduler:_run(node, chain, record, root)
  local p = properties(record)
  local update_last = p.update_last_execution ~= false
  if node.inflight or update_last and (node.last_tick == self.tick or chain.visited[node.id]) then
    self:_finish(chain); return
  end
  local command = p.command or ''
  assert(type(command) == 'string' and #command <= 32767, 'invalid-command-block-command')
  -- Empty roots skip performCommand but still start a chain. Empty chain
  -- blocks do performCommand, including the once-per-tick execution guard.
  if not root or command ~= '' then
    if update_last then node.last_tick = self.tick; chain.visited[node.id] = true end
  end
  if command == '' then
    if self:_publish(node, record, 0, nil, true) then self:_enqueue(chain) else self:_finish(chain) end
    return
  end
  if not self:_publish(node, record, 0, nil) then self:_finish(chain); return end
  local token = {chain = chain}
  node.inflight = token; self.inflight = self.inflight + 1; self.executed = self.executed + 1
  local completed = false
  local function done(result, output)
    if completed then return end
    completed = true
    if chain.epoch ~= self.epoch then return end
    if node.inflight ~= token then self:_finish(chain); return end
    node.inflight = nil; self.inflight = self.inflight - 1
    if chain.epoch ~= self.epoch or not self:_resolve(node) or not self:_resolve(chain.root) then
      self:_finish(chain); return
    end
    local count
    if type(result) == 'table' then
      count = result.success_count
      if count == nil then count = result.success == true and 1 or 0 end
      output = result.message or result.output or result.error or output
    elseif type(result) == 'boolean' then count = result and 1 or 0
    else count = result end
    if not integer(count, 0, 2147483647) then count, output = 0, 'invalid-command-block-result' end
    if output ~= nil and type(output) ~= 'string' then output = tostring(output) end
    if self:_publish(node, node.record, count, output) then self:_enqueue(chain) else self:_finish(chain) end
  end
  local ok, accepted, why = pcall(self.adapter.execute, record, done)
  if not ok then done(0, tostring(accepted))
  elseif accepted == false then done(0, tostring(why or 'command-block-command-rejected')) end
end

function Scheduler:_root(node)
  local record = self:_resolve(node)
  if not record then self:remove(node.id); return end
  if mode(record) == 'chain' or node.busy then return end
  local maximum = type(self.max_chain) == 'function' and self.max_chain() or self.max_chain
  assert(integer(maximum, 0, 65536), 'invalid-command-chain-limit')
  local chain = {root = node, epoch = self.epoch, cell = node.cell, facing = self:_facing(record),
    remaining = maximum, visited = {}}
  node.busy = true
  local condition = node.condition_met
  if mode(record) == 'repeat' then node.condition_met = self:_condition(record) end
  if not condition then
    if properties(record).conditional == true then self:_publish(node, record, 0, nil, true) end
    self:_finish(chain); return
  end
  self:_run(node, chain, record, true)
end

function Scheduler:_advance(chain)
  if chain.finished or chain.epoch ~= self.epoch or not self:_resolve(chain.root) then self:_finish(chain); return end
  if chain.remaining <= 0 then
    self.last_error = 'command-chain-limit'; self:_finish(chain); return
  end
  chain.remaining = chain.remaining - 1
  local cell = self:_relative(chain.cell, chain.facing)
  local record = self.adapter.get(cell)
  if mode(record) ~= 'chain' then self:_finish(chain); return end
  local node = self:upsert(record)
  chain.cell, chain.facing = cell, self:_facing(record)
  if not node.powered and properties(record).auto ~= true then self:_enqueue(chain); return end
  node.condition_met = self:_condition(record)
  if not node.condition_met then
    if self:_publish(node, record, 0, nil, true) then self:_enqueue(chain) else self:_finish(chain) end
    return
  end
  self:_run(node, chain, record, false)
end

function Scheduler:step(tick)
  assert(integer(tick, self.tick, 9007199254740991), 'command-tick-must-be-monotonic-integer')
  if tick > self.tick then self.tick, self.spent = tick, 0 end
  local work, started = 0, self.executed
  -- A host can call step again after pumping its async command jobs while it
  -- holds this logical tick. The budget limits each slice, not the whole tick.
  while work < self.budget do
    local chain = self.ready[self.head]
    if chain then
      self.ready[self.head] = nil; self.head = self.head + 1; chain.queued = false
      if self.head > self.tail then self.head, self.tail = 1, 0 end
      self.spent, work = self.spent + 1, work + 1
      self:_advance(chain)
    elseif self.heap[1] and self.heap[1].due <= tick then
      local event = pop(self.heap)
      self.spent, work = self.spent + 1, work + 1
      if self.nodes[event.node.id] == event.node and event.node.event == event then
        event.node.event = nil; self:_root(event.node)
      end
    else break end
  end
  return {work = work, executed = self.executed - started, inflight = self.inflight,
    pending = self:pending_tick(), ready = self.tail - self.head + 1,
    scheduled = #self.heap, tick = self.tick, error = self.last_error}
end

function Scheduler:pending_tick()
  return self.inflight > 0 or self.head <= self.tail
    or self.heap[1] ~= nil and self.heap[1].due <= self.tick
end

function Scheduler:success(record_or_id)
  local id = type(record_or_id) == 'table' and record_or_id.id or record_or_id
  local node = self.nodes[id]
  return node and node.success_count or 0
end

function Scheduler:clear()
  self.epoch = self.epoch + 1
  self.nodes, self.heap, self.ready = {}, {}, {}
  self.count, self.inflight, self.head, self.tail = 0, 0, 1, 0
  self.tick, self.spent = 0, 0
  self.last_error = nil
end

return M
