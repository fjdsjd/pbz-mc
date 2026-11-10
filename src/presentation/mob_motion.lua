-- Host equivalents of animation state normally supplied by Minecraft's native
-- entity tick: Squid.aiStep and AbstractCubeMob.tick.
-- All output feeds the original client controllers; no shared walk animation.
local M={}
local shulker=require('rules.shulker_pose')
function M.update(v,m,dt,speed,vertical,ground)
 local name=m.def.name;local q,vars=v.q,v.vars
 if name=='shulker'then
   vars['variable.shulker.peekamount']=shulker.update(m,v.now)
   vars['variable.shulker.facingdirection']=m.shulker_attach_face or 0
 end
 if name=='chicken'then
   -- Chicken.aiStep and ChickenModel: integrate at the original 20 Hz,
   -- interpolate for rendering, and let the vanilla wing channels pose it.
   local s=v.chicken or {phase=0,speed=0,flapping=0,accumulator=0};v.chicken=s
   s.accumulator=s.accumulator+dt
   while s.accumulator>=.05 do
     s.accumulator=s.accumulator-.05;s.old_phase=s.phase;s.old_speed=s.speed
     s.speed=math.max(0,math.min(1,s.speed+(ground and -1 or 4)*.3))
     if not ground and s.flapping<1 then s.flapping=1 end
     s.flapping=s.flapping*.9;s.phase=s.phase+s.flapping*2
   end
   local t=s.accumulator/.05
   local phase=(s.old_phase or s.phase)*(1-t)+s.phase*t
   local amplitude=(s.old_speed or s.speed)*(1-t)+s.speed*t
   vars['variable.wing_flap']=math.deg((math.sin(phase)+1)*amplitude)
 end
 if name=='wolf'then
   -- Native untamed wolf tail: neutral PI/5, angry 1.53938 radians.
   q.tail_angle=m.target and 1.5393804 or math.pi/5
 end
 if name=='squid'or name=='glow_squid'then
   local s=v.squid or {phase=0,rate=.2/(1+math.random()),roll=0,rotation_speed=0,pitch=0}
   v.squid=s;s.phase=(s.phase+s.rate*dt*20)%(2*math.pi)
   local angle
   if m.swimming then
     if s.phase<math.pi then
       local f=s.phase/math.pi;angle=math.sin(f*f*math.pi)*45
       s.rotation_speed=f>.75 and 1 or s.rotation_speed*.8^(dt*20)
     else angle=0;s.rotation_speed=s.rotation_speed*.99^(dt*20)end
     s.roll=s.roll+math.pi*s.rotation_speed*1.5*dt*20
     local pitch=-math.deg(math.atan(speed,vertical))
     s.pitch=s.pitch+(pitch-s.pitch)*(1-.9^(dt*20))
   else angle=math.abs(math.sin(s.phase))*45;s.pitch=s.pitch+(-90-s.pitch)*(1-.98^(dt*20))end
   vars['variable.squid.tentacle_angle']=angle;vars['variable.squid.swim_rotation']=s.roll
   q.body_x_rotation=s.pitch
 end
 if name=='slime'or name=='magma_cube'or name=='sulfur_cube'then
   local s=v.squish or {value=0,target=0,ground=ground,accumulator=0};v.squish=s
   if ground~=s.ground then s.target=ground and -.5 or 1;s.ground=ground end
   s.accumulator=s.accumulator+dt
   while s.accumulator>=.05 do
     s.accumulator=s.accumulator-.05;s.old=s.value
     s.value=s.value+(s.target-s.value)*.5;s.target=s.target*.6
   end
   q.previous_squish_value=s.old or s.value;q.current_squish_value=s.value;q.frame_alpha=s.accumulator/.05
   q.variant=1;q.fuse_time=-1
 end
end
return M
