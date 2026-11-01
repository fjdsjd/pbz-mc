-- Java mining progress, evaluated only for registered MC building records.
-- Tool.speed and correct-for-drops are separate: an under-tier pick still
-- mines at its material speed, but uses divisor 100 instead of 30.
local blocks=require('content.blocks')
local tools=require('content.tools')
local M={ticks_per_second=20,break_delay_ticks=5,max_ticks_per_advance=256}
local function finite(value)return type(value)=='number' and value==value and math.abs(value)<math.huge end
local function number(value,fallback,minimum)
  if value==nil then return fallback end
  assert(finite(value) and value>=minimum,'block-mining-state-invalid')
  return value
end
local function f(value)return (string.unpack('<f',string.pack('<f',value)))end
local timing_cache,timing_order={},{}
local function completion_ticks(progress)
  if progress<=0 then return false end
  if progress>=1 then return 0 end
  if timing_cache[progress]~=nil then return timing_cache[progress] end
  local accumulated,result=0,false
  -- Ordinary mining results are cached. Extreme status attributes may take
  -- hours; their diagnostic is explicitly unknown rather than an expensive
  -- speculative loop. Actual advance still uses the precise float operation.
  for tick=1,2048 do
    accumulated=f(accumulated+progress)
    if accumulated>=1 then result=tick;break end
  end
  if #timing_order>=64 then timing_cache[table.remove(timing_order,1)]=nil end
  timing_order[#timing_order+1]=progress;timing_cache[progress]=result
  return result
end
function M.evaluate(definition,tool_id,state)
  assert(type(definition)=='table' and finite(definition.hardness) and definition.hardness>=-1,'block-mining-definition-invalid')
  state=state or {};local tool=tools.get(tool_id)
  local tags=definition.mineable_tags or {}
  local effective=tool~=nil and tags[tool.mineable_tag]==true
  local correct=not definition.requires_correct_tool
  if not correct and effective then
    correct=true
    for tag in pairs(definition.harvest_tags or {})do
      if tool.incorrect_for_drops[tag] then correct=false;break end
    end
  end
  local speed=effective and tool.mining_speed or 1
  if speed>1 then speed=f(speed+f(number(state.mining_efficiency,0,0)))end
  local haste=number(state.haste_level,0,0);local fatigue=number(state.fatigue_level,0,0)
  assert(haste%1==0 and fatigue%1==0,'block-mining-effect-level-invalid')
  if haste>0 then speed=f(speed*f(1+f(haste*f(.2))))end
  if fatigue>0 then speed=f(speed*f(.3^fatigue))end
  speed=f(speed*f(number(state.block_break_speed,1,0)))
  if state.submerged==true then speed=f(speed*f(number(state.submerged_mining_speed,.2,0)))end
  if state.on_ground==false then speed=f(speed/5)end
  assert(finite(speed),'block-mining-speed-overflow')
  local hardness=f(definition.hardness);local divisor=correct and 30 or 100
  local breakable=hardness>=0 and speed>0
  local progress=not breakable and 0 or hardness==0 and 1 or f(f(speed/hardness)/divisor)
  -- A finite, exceptionally large attribute can overflow Java's intermediate
  -- float; it is still just an instant accepted hit, never a non-JSON infinity.
  if progress==math.huge then progress=1 end
  local ticks=completion_ticks(progress)
  return {content_id=definition.id,tool_id=tool and tool.id or false,hardness=hardness,speed=speed,
    effective_tool=effective,correct_for_drops=correct,divisor=divisor,progress_per_tick=progress,
    instant=progress>=1,breakable=breakable,ticks=ticks,seconds=ticks and ticks/M.ticks_per_second or false,
    nominal_ticks=progress>0 and math.ceil(1/progress) or false,
    break_delay_ticks=progress>=1 and 0 or M.break_delay_ticks}
end
function M.sample(block_id,tool_id,state)
  local definition=blocks.get(block_id)
  if not definition or not definition.available then return nil,'block-mining-unavailable' end
  return M.evaluate(definition,tool_id,state)
end
function M.new()return {progress=0,remainder=0,ticks=0,pending_ticks=0}end
function M.advance(run,dt,sample)
  assert(type(run)=='table' and finite(run.progress) and run.progress>=0 and run.progress<=1
    and finite(run.remainder) and run.remainder>=0 and run.remainder<1
    and finite(run.ticks) and run.ticks>=0 and run.ticks%1==0
    and finite(run.pending_ticks or 0) and (run.pending_ticks or 0)>=0
    and (run.pending_ticks or 0)%1==0,'block-mining-run-invalid')
  assert(finite(dt) and dt>=0,'block-mining-delta-invalid')
  assert(type(sample)=='table' and finite(sample.progress_per_tick) and sample.progress_per_tick>=0,'block-mining-sample-invalid')
  if run.progress>=1 then return 1,true end
  -- Zero-hardness/fast tools break on the initial accepted hit, not after a
  -- frame or a fake durability step. Pauses should not call this function.
  if sample.instant then run.progress=1;return 1,true end
  local elapsed=run.remainder+dt*M.ticks_per_second
  assert(finite(elapsed),'block-mining-time-overflow')
  local ticks=math.floor(elapsed+1e-9);run.remainder=math.max(0,elapsed-ticks)
  ticks=ticks+(run.pending_ticks or 0)
  local processed=math.min(ticks,M.max_ticks_per_advance)
  run.pending_ticks=ticks-processed
  -- Match Java's float accumulator at each mining tick. Stop at completion;
  -- a large host frame cannot create a catch-up loop over unbounded seconds.
  if sample.progress_per_tick>0 then
    for _=1,processed do
      run.ticks=run.ticks+1
      run.progress=math.min(1,f(run.progress+sample.progress_per_tick))
      if run.progress>=1 then break end
    end
  else
    run.ticks=run.ticks+processed
  end
  if run.progress>=1 then run.pending_ticks=0 end
  return run.progress,run.progress>=1
end
return M
