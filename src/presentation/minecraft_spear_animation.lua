-- MinecraftSpearAnimation.cs, wukong-steve 0.11.0, pinned commit 9f213556.
-- PolyForm Noncommercial 1.0.0; retain third_party/wukong-steve notices.
local M={}
function M.progress(t,start,finish) return math.max(0,math.min(1,(t-start)/math.max(.00001,finish-start))) end
function M.in_out_sine(x) return -(math.cos(math.pi*x)-1)/2 end
function M.out_cubic(x) return 1-(1-x)^3 end
function M.out_back(x) return 1+2.70158*(x-1)^3+1.70158*(x-1)^2 end
function M.out_circ(x) return math.sqrt(1-(x-1)^2) end
function M.in_circ(x) return 1-math.sqrt(1-x*x) end
function M.in_out_expo(x)
  if x==0 or x==1 then return x end
  return x<.5 and 2^(20*x-10)/2 or (2-2^(-20*x+10))/2
end
function M.in_out_elastic(x)
  if x==0 or x==1 then return x end
  if x<.5 then return -(2^(20*x-10)*math.sin((20*x-11.125)*2*math.pi/4.5))/2 end
  return 2^(-20*x+10)*math.sin((20*x-11.125)*2*math.pi/4.5)/2+1
end
function M.in_out_back(x)
  local c=1.70158*1.525
  if x<.5 then return (2*x)^2*((c+1)*2*x-c)/2 end
  return ((2*x-2)^2*((c+1)*(x*2-2)+c)+2)/2
end
function M.hit_feedback(ticks)
  return .4*((1-(1-M.progress(ticks,1,3))^4)-M.in_out_sine(M.progress(ticks,3,10)))
end
function M.solve(spear,seconds)
  local ticks,delay=seconds*20,spear.delay*20
  local dismount,knockback,damage=(spear.delay+spear.dismount)*20,
    (spear.delay+spear.knockback)*20,(spear.delay+spear.damage_seconds)*20
  local p={raise=M.progress(ticks,0,delay)}
  p.start=M.progress(p.raise,0,.5);p.middle=M.progress(p.raise,.5,.8);p.finish=M.progress(p.raise,.8,1)
  p.sway=M.progress(ticks,dismount-20,knockback-40)
  p.lower=M.out_cubic(M.in_out_elastic(M.progress(ticks-20,knockback-40,knockback)))
  p.back=M.progress(ticks,damage-5,damage)
  p.intensity=2*M.out_circ(p.sway)-2*M.in_circ(p.back)
  p.slow=math.sin(ticks*19*math.pi/180)*p.intensity;p.fast=math.sin(ticks*30*math.pi/180)*p.intensity
  return p
end
return M
