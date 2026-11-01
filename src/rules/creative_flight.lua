-- Vanilla 1.21.1 ClientPlayerEntity / PlayerEntity / LivingEntity: seven-tick
-- double tap, .05 air acceleration (sprint x2), .98 input, .91 horizontal
-- drag, .15 vertical input and .6 vertical drag. UE centimetres, 20 Hz.
local M={tick_seconds=.05,double_tap_seconds=.35}
local function finite(v)return type(v)=='number'and v==v and math.abs(v)<math.huge end
local function number(v)assert(finite(v),'invalid-creative-flight-number');return v end
local function f32(v)return string.unpack('<f',string.pack('<f',v))end
local friction,input_scale=f32(.91),f32(.98)
local function vec(x,y,z)return {X=x,Y=y,Z=z}end
function M.new(v)
 v=v or {};return {vx=number(v.X or 0),vy=number(v.Y or 0),vz=number(v.Z or 0),ticks=0}
end
function M.step(s,input)
 local d=assert(input.direction,'creative-flight-direction-required')
 local dx,dy=number(d.X),number(d.Y);local length=math.sqrt(dx*dx+dy*dy)
 local magnitude=math.min(1,number(input.input_length or length)*input_scale*(input.using_item and .2 or 1))
 if length>0 then dx,dy=dx/length,dy/length end
 local acceleration=f32(.05)*(input.sprint and 2 or 1)
 local x,y=number(s.vx)/2000,number(s.vy)/2000
 if math.abs(x)<.003 then x=0 end;if math.abs(y)<.003 then y=0 end
 x,y=x+dx*magnitude*acceleration,y+dy*magnitude*acceleration
 local lift=(input.jump_held and 1 or 0)-(input.sneak and 1 or 0)
 local z=number(s.vz)/2000+lift*f32(f32(.05)*3)
 if math.abs(z)<.003 then z=0 end
 -- Vanilla moves BEFORE drag. Keep the movement velocity separate from the
 -- state used by the next 20 Hz step; render rate must not apply drag twice.
 s.vx,s.vy,s.vz=x*friction*2000,y*friction*2000,z*.6*2000
 s.ticks=s.ticks+1
 return {delta=vec(x*100,y*100,z*100),travel_velocity=vec(x*2000,y*2000,z*2000),
  velocity=vec(s.vx,s.vy,s.vz),tick=s.ticks}
end
function M.project(v,n)
 local x,y,z=number(v.X),number(v.Y),number(v.Z)
 local nx,ny,nz=number(n.X),number(n.Y),number(n.Z)
 local length=nx*nx+ny*ny+nz*nz
 if length<1e-8 then return vec(0,0,0)end
 local dot=(x*nx+y*ny+z*nz)/length
 if dot<0 then return vec(x-dot*nx,y-dot*ny,z-dot*nz)end
 return vec(x,y,z)
end
function M.collide(s,n)
 local v=M.project(vec(s.vx,s.vy,s.vz),n);s.vx,s.vy,s.vz=v.X,v.Y,v.Z;return v
end
-- Receives genuine pressed/released edges only. Context/focus baselines and
-- held auto-jumps do not manufacture a double tap. Times are monotonic seconds.
function M.tap(s,held,epoch,time,eligible)
 number(time)
 if not eligible then s.down=nil;s.epoch=nil;s.first=nil;return false end
 if s.epoch~=epoch then s.epoch=epoch;s.down=held;s.first=nil;return false end
 local pressed=held and s.down==false;s.down=held
 if not pressed then return false end
 if s.first and time>=s.first and time-s.first<M.double_tap_seconds then s.first=nil;return true end
 s.first=time;return false
end
return M
