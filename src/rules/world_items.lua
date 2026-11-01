-- World items and containers are one candidate state. Host objects and durable
-- commit are deliberately outside these rules; a returned plan is not a spawn.
local state=require('storage.state')
local stacks=require('rules.item_stack')
local transfer=require('rules.container_transfer')
local slots=require('rules.container_slots')
local json=require('dkjson')
local native_slot=require('rules.native_slot_reference')
local M={lifetime_ticks=6000,thrown_delay_ticks=40,mined_delay_ticks=10,ticks_per_second=20}
local function shallow(value)
  local result=state.object();for k,v in pairs(value) do result[k]=v end;return result
end
local function edit(data)
  local result=shallow(data);result.world_items=shallow(data.world_items);return result
end
local function number(n) return type(n)=='number' and n==n and math.abs(n)<math.huge end
local function integer(n) return number(n) and n%1==0 and n>=0 and n<2^53 end
local function vector(p)
  assert(type(p)=='table' and number(p.x) and number(p.y) and number(p.z),'invalid-world-item-vector')
end
function M.validate(record,definitions)
  assert(type(record)=='table' and type(record.id)=='string' and #record.id>0,'invalid-world-item-id')
  assert(type(record.world)=='string' and #record.world>0,'invalid-world-item-map')
  stacks.validate(record.stack,definitions,{unknown=true})
  assert(not native_slot.is(record.stack),'native-slot-world-item-forbidden')
  vector(record.position);vector(record.velocity)
  assert(integer(record.remaining_ticks) and record.remaining_ticks>0 and record.remaining_ticks<=M.lifetime_ticks,'invalid-world-item-lifetime')
  assert(integer(record.pickup_delay) and record.pickup_delay<=M.thrown_delay_ticks,'invalid-world-item-delay')
  assert(record.origin=='thrown' or record.origin=='mined','invalid-world-item-origin')
  state.validate_value(record);return true
end
function M.validate_state(data,definitions)
  slots.validate(data.containers,definitions)
  assert(type(data.world_items)=='table' and data.world_items~=json.null and
    state.json_kind(data.world_items)=='object','invalid-world-items-map')
  local instances={}
  local function own(value)
    if value.instance_id then
      assert(not instances[value.instance_id],'duplicate-owned-item-instance')
      instances[value.instance_id]=true
    end
  end
  slots.visit(data.containers,function(_,value) own(value) end)
  for id,record in pairs(data.world_items) do
    assert(type(id)=='string' and record.id==id,'world-item-id-mismatch')
    M.validate(record,definitions);own(record.stack)
  end
  state.validate_value(data);return true
end
function M.create(id,value,world,position,velocity,origin,definitions)
  stacks.validate(value,definitions)
  local result={id=id,stack=stacks.copy(value),world=world,position=state.clone(position),velocity=state.clone(velocity),
    origin=origin,remaining_ticks=M.lifetime_ticks,pickup_delay=origin=='thrown' and M.thrown_delay_ticks or M.mined_delay_ticks}
  M.validate(result,definitions);return result
end
function M.throw(data,source,count,id,world,position,velocity,definitions)
  assert(not data.world_items[id],'duplicate-world-item-id')
  local containers,value=transfer.extract(data.containers,source,count,definitions)
  if not value then return data,nil end
  local record=M.create(id,value,world,position,velocity,'thrown',definitions)
  local result=edit(data);result.containers=containers;result.world_items[id]=record
  return result,record
end
function M.pickup(data,id,world,definitions)
  local record=data.world_items[id]
  if not record or record.world~=world or record.pickup_delay>0 then return data,0 end
  local containers,remainder,moved=transfer.offer(data.containers,record.stack,'player',definitions)
  if moved==0 then return data,0 end
  local result=edit(data);result.containers=containers
  if remainder then
    local rest=state.clone(record);rest.stack=remainder;result.world_items[id]=rest
  else result.world_items[id]=nil end
  return result,moved
end
function M.merge(data,target_id,source_id,world,distance,definitions)
  assert(number(distance) and distance>=0,'invalid-merge-distance')
  if target_id==source_id then return data,0 end
  local target,source=data.world_items[target_id],data.world_items[source_id]
  if not target or not source or target.world~=world or source.world~=world or
      not stacks.compatible(target.stack,source.stack) then return data,0 end
  local d2=0
  for _,axis in ipairs({'x','y','z'}) do d2=d2+(target.position[axis]-source.position[axis])^2 end
  if d2>distance^2 then return data,0 end
  local n=math.min(source.stack.count,stacks.limit(target.stack,definitions)-target.stack.count)
  if n<=0 then return data,0 end
  local result=edit(data)
  local merged=state.clone(target)
  merged.stack.count=merged.stack.count+n
  merged.remaining_ticks=math.max(target.remaining_ticks,source.remaining_ticks)
  merged.pickup_delay=math.max(target.pickup_delay,source.pickup_delay)
  result.world_items[target_id]=merged
  if source.stack.count>n then
    local rest=state.clone(source);rest.stack.count=rest.stack.count-n;result.world_items[source_id]=rest
  else result.world_items[source_id]=nil end
  return result,n
end
function M.advance(data,world,ticks,active,paused)
  assert(integer(ticks),'invalid-active-ticks')
  if paused or ticks==0 then return data,{} end
  local result,expired=nil,{}
  -- active is an explicit set of currently simulated native entities, not all
  -- records on disk. Unloaded maps/regions and unsupported content do not age.
  for id in pairs(active) do
    local record=data.world_items[id]
    if active[id] and record and record.world==world then
      result=result or edit(data)
      if ticks>=record.remaining_ticks then result.world_items[id]=nil;expired[#expired+1]=id
      else
        local next_record=state.clone(record)
        next_record.remaining_ticks=record.remaining_ticks-ticks
        next_record.pickup_delay=math.max(0,record.pickup_delay-ticks)
        result.world_items[id]=next_record
      end
    end
  end
  table.sort(expired);return result or data,expired
end
return M
