-- Shulker's native peek state, separate from the original Bedrock lid curves.
-- A fixed 20 Hz step and interpolation keep opening independent of render LOD.
local M={}
function M.update(m,now,random)
  random=random or math.random
  local s=m.shulker_pose
  if not s then
    s={at=now,accumulator=0,current=0,previous=0,raw=0,tick=0,revision=0}
    m.shulker_pose=s
  end
  local function target(raw)
    if s.raw==raw then return end
    s.raw=raw;s.revision=s.revision+1;s.event=raw==0 and 'close' or 'open'
  end
  local attacking=m.target~=nil and (m.health or 1)>0
  if attacking then s.idle_until=nil;target(100)
  elseif s.attacking then s.idle_until=nil;target(0)end
  s.attacking=attacking
  -- Do not replay a long pause/cutscene as hundreds of goal evaluations.
  s.accumulator=s.accumulator+math.max(0,math.min(.25,now-s.at));s.at=now
  while s.accumulator>=.05-1e-9 do
    s.accumulator=math.max(0,s.accumulator-.05);s.tick=s.tick+1
    if not attacking then
      if s.idle_until and s.tick>=s.idle_until then s.idle_until=nil;target(0)end
      -- ShulkerPeekGoal: reducedTickDelay(40) at the 10 Hz goal cadence;
      -- peek 30 percent for 20 * (1 + nextInt(3)) game ticks.
      if not m.no_ai and not s.idle_until and s.tick%2==0 and random(1,20)==1 then
        s.idle_until=s.tick+20*random(1,3);target(30)
      end
    end
    s.previous=s.current
    local goal=s.raw*.01
    s.current=s.current+math.max(-.05,math.min(.05,goal-s.current))
  end
  local alpha=s.accumulator/.05
  return s.previous+(s.current-s.previous)*alpha,s
end
return M
