-- A stack is a full value, not an item-count pair or an award operation.
local state=require('storage.state')
local json=require('dkjson')
local native_slot=require('rules.native_slot_reference')
local M={}
local function equal(a,b,ignore_count)
  if a==b then return true end
  if type(a)~=type(b) or type(a)~='table' or a==json.null or b==json.null then return false end
  if state.json_kind(a)~=state.json_kind(b) then return false end
  for k,v in pairs(a) do if not (ignore_count and k=='count') and not equal(v,b[k],false) then return false end end
  for k in pairs(b) do if not (ignore_count and k=='count') and a[k]==nil then return false end end
  return true
end
function M.compatible(a,b)
  if native_slot.is(a) or native_slot.is(b) then return false end
  return a and b and equal(a,b,true) or false
end
function M.copy(stack,count)
  if not stack or count==0 then return nil end
  if native_slot.is(stack) then
    native_slot.validate(stack);assert(count==nil or count==1,'native-slot-count-change')
  end
  local result=state.clone(stack);if count then result.count=count end;return result
end
function M.validate(stack,definitions,options)
  options=options or {}
  assert(type(stack)=='table' and stack~=json.null,'invalid-stack')
  if native_slot.is(stack) then return native_slot.validate(stack) end
  native_slot.assert_unreserved(stack)
  assert(type(stack.content_id)=='string' and stack.content_id:match('^[a-z][a-z0-9_]*:[a-z0-9_/.-]+$'),'invalid-stack-id')
  assert(type(stack.count)=='number' and stack.count%1==0 and stack.count>0 and stack.count<2^53,'invalid-stack-count')
  assert(type(stack.metadata)=='table' and stack.metadata~=json.null,'invalid-stack-metadata')
  state.validate_value(stack)
  local definition=definitions.get(stack.content_id)
  if not definition then assert(options.unknown,'unknown-stack-content');return true end
  assert(definition.kind~='balance','balance-is-not-container-item')
  assert(options.batch or stack.count<=definition.stack_limit,'stack-limit-exceeded')
  if definition.instance then
    assert(stack.count==1 and type(stack.instance_id)=='string' and #stack.instance_id>0,'equipment-instance-required')
  end
  return true
end
function M.limit(stack,definitions)
  if native_slot.is(stack) then native_slot.validate(stack);return 1 end
  local definition=assert(definitions.get(stack.content_id),'unknown-stack-content')
  assert(definition.kind~='balance','balance-is-not-container-item')
  return definition.stack_limit
end
return M
