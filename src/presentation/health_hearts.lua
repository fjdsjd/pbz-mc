-- MC 1.21.1 InGameHud.renderStatusBars/renderHealthBar and
-- ClientPlayerEntity.updateHealth, adapted to a normalized 20-point HUD.
-- This module never writes gameplay health, invulnerability or regeneration.
local M={};M.__index=M
local function finite(v)return type(v)=='number' and v==v and math.abs(v)<math.huge end
function M.units(hp,maximum)
  assert(finite(hp) and finite(maximum) and maximum>0,'invalid-heart-health')
  return hp<=0 and 0 or math.max(1,math.ceil(20*math.min(1,hp/maximum)))
end
function M.new()return setmetatable({},M)end
function M:update(snapshot,now)
  assert(snapshot.health_authoritative==true and finite(now) and now>=0,'invalid-heart-snapshot')
  local units=M.units(snapshot.hp,snapshot.max_hp);local tick=math.floor(now*20+1e-6)
  if self.epoch~=snapshot.epoch or not self.last_time or now<self.last_time or self.maximum~=snapshot.max_hp then
    self.epoch=snapshot.epoch;self.maximum=snapshot.max_hp;self.last=units;self.display=units;self.changed_at=now;self.blink_end=0
  end
  -- Vanilla computes this flag before processing this frame's health change.
  local blinking=self.blink_end>tick and math.floor((self.blink_end-tick)/3)%2==1
  if units<self.last then self.changed_at=now;self.blink_end=tick+20
  elseif units>self.last then self.changed_at=now;self.blink_end=tick+10 end
  if now-self.changed_at>1 then self.display=units;self.changed_at=now end
  self.last=units;self.last_time=now
  local gold=snapshot.absorption_authoritative and math.ceil(20*math.max(0,snapshot.absorption or 0)/snapshot.max_hp) or 0
  local frame={units=units,gold=gold,previous=self.display,blinking=blinking,tick=tick,
    low=units+gold<=4,regenerating=snapshot.regenerating==true,kind=snapshot.heart_kind or ''}
  self.frame=frame;return frame
end
local function random_two(tick)
  -- CheckedRandom/java.util.Random 48-bit LCG; nextInt(2), seeded per HUD tick.
  local mask=(1<<48)-1;local seed=((tick*312871)~25214903917)&mask
  return function()seed=(seed*25214903917+11)&mask;return ((seed>>17)*2)>>31 end
end
function M.draw(frame,sprites,left,top,scale)
  assert(scale>=1 and scale%1==0,'invalid-heart-scale')
  local draw={};local random=random_two(frame.tick);local wave=frame.regenerating and frame.tick%25 or -1
  local kind=frame.kind
  assert(kind=='' or kind=='poisoned_' or kind=='withered_' or kind=='frozen_','invalid-heart-kind')
  local function image(key,index,y)
    draw[#draw+1]={texture=assert(sprites['heart/'..key],'missing-original-heart:'..key),
      x=left+(index%10)*8*scale,y=y,w=9*scale,h=9*scale}
  end
  local total=10+math.ceil((frame.gold or 0)/2);local rows=math.ceil(total/10);local gap=math.max(10-(rows-2),3)
  for i=total-1,0,-1 do
    local y=top-math.floor(i/10)*gap*scale+(frame.low and random()*scale or 0)-(i==wave and 2*scale or 0)
    image(frame.blinking and 'container_blinking' or 'container',i,y)
    if i>=10 then
      image((kind=='withered_' and kind or 'absorbing_')..((i-10)*2+1==frame.gold and 'half' or 'full'),i,y)
    end
    if frame.blinking and i*2<frame.previous then
      image(kind..(i*2+1==frame.previous and 'half_blinking' or 'full_blinking'),i,y)
    end
    if i*2<frame.units then image(kind..(i*2+1==frame.units and 'half' or 'full'),i,y) end
  end
  return draw
end
return M
