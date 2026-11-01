-- MC mouse/keyboard state. Never infer an edge from a context/focus baseline.
local M={};M.__index=M
local function down(keys,bit) return ((keys or 0)&(1<<bit))~=0 end
function M.new(rotation)
  return setmetatable({yaw=rotation.Yaw,pitch=(rotation.Pitch+180)%360-180,keys=0,jumps=0},M)
end
function M:reset() self.keys=0;self.jumps=0;self.sprinting=false;self.armed=false;self.stamp=nil;self.center=nil;self.cursor_time=nil;self.native_pending=nil;self.native_time=nil end
function M:look(dx,dy)
  assert(type(dx)=='number' and type(dy)=='number' and math.abs(dx)<2^31 and math.abs(dy)<2^31,'invalid-mc-mouse-delta')
  if dx==0 and dy==0 then return end
  self.look_serial=(self.look_serial or 0)+1
  self.yaw=(self.yaw+dx*.15+180)%360-180
  self.pitch=math.max(-89.9,math.min(89.9,self.pitch-dy*.15))
end
function M:sample(pointer,allowed,blocked_keys)
  local stamp=tostring(pointer.epoch)
  if not allowed or not pointer.focused then self:reset();return end
  local baseline=self.stamp~=stamp
  if baseline then self:reset();self.stamp=stamp end
  if self.seq and pointer.seq and pointer.seq<=self.seq and self.sequence_epoch==stamp then return end
  self.seq=pointer.seq;self.sequence_epoch=stamp
  local dx,dy=pointer.look_dx or 0,pointer.look_dy or 0
  assert(type(dx)=='number' and type(dy)=='number' and math.abs(dx)<2^31 and math.abs(dy)<2^31,'invalid-mc-mouse-delta')
  if not baseline then
    self:look(dx,dy)
  end
  -- The native queue distinguishes accepted held WASD from quarantined input.
  -- Continuous directions survive gameplay handoffs; inherited jump, mouse,
  -- menu/focus/overflow presses still cannot create action edges.
  if not self.armed then
    local directions=blocked_keys and ((pointer.keys or 0)&(0xf<<14)&~blocked_keys) or 0
    self.armed=((pointer.keys or 0)&0x1fc000&~directions)==0 and (pointer.buttons or 0)==0
    self.keys=directions;return
  end
  if down(pointer.keys,18) and not down(self.keys,18) then self.jumps=self.jumps+1 end
  self.keys=pointer.keys or 0
  -- Sprint is a state, not the current state of Ctrl. Retain it through a
  -- released Ctrl and jumps; stop when forward movement or eligibility ends.
  if not down(self.keys,14) or down(self.keys,16) or down(self.keys,19) then self.sprinting=false
  elseif down(self.keys,20) then self.sprinting=true end
end
-- Some PBZ/Windows input paths deliver only legacy cursor motion. The host
-- recentres the eligible viewport immediately after this batch; never derive
-- motion across focus, epoch or size changes. Raw and cursor motion must not
-- both rotate the same frame, including a raw packet delayed past a poll.
function M:sample_batch(batch,allowed)
  local pointer=batch.latest
  local raw=false
  for _,sample in ipairs(batch.samples or {}) do
    local value=sample
    if (sample.look_dx or 0)~=0 or (sample.look_dy or 0)~=0 then
      raw=true
      if self.cursor_time and (sample.time_ms or 0)<=self.cursor_time then
        value={};for k,v in pairs(sample) do value[k]=v end;value.look_dx=0;value.look_dy=0
      else self.look_backend='raw' end
    end
    self:sample(value,allowed and not batch.overflow,batch.blocked_keys)
  end
  self:sample(pointer,allowed and not batch.overflow,batch.blocked_keys)
  if not allowed or not pointer.focused or batch.overflow then self.center=nil;return end
  if not pointer.width or pointer.width<320 or not pointer.height or pointer.height<240 then self.center=nil;return end
  local x,y=math.floor(pointer.width/2),math.floor(pointer.height/2)
  local prior=self.center
  if prior and prior.epoch==pointer.epoch and prior.width==pointer.width and prior.height==pointer.height
      and pointer.time_ms~=prior.time and not raw then
    local dx,dy=pointer.x-x,pointer.y-y
    -- PBZ's native viewport may recenter before the polling snapshot. Its
    -- queued legacy message still records the real pre-warp position.
    if dx==0 and dy==0 then
      for _,sample in ipairs(batch.samples or {}) do
        if sample.epoch==pointer.epoch and (sample.seq or 0)>(prior.seq or 0)
            and (sample.time_ms or 0)>(self.cursor_time or -1)
            and sample.x and sample.y and (sample.x~=x or sample.y~=y) then dx=sample.x-x;dy=sample.y-y end
      end
    end
    if dx~=0 or dy~=0 then self:look(dx,dy);self.cursor_time=pointer.time_ms;self.look_backend='viewport-relative' end
  end
  self.center={epoch=pointer.epoch,width=pointer.width,height=pointer.height,time=pointer.time_ms,seq=pointer.seq}
  return x,y
end
-- Native PBZ keeps its camera and movement. Give its input path one frame to
-- consume a mouse packet, then supply only an unhandled delta. Never keep a
-- target yaw alive on idle/WASD frames or overwrite native camera corrections.
function M:native_sample(batch,allowed,current,dx,dy)
  local p=batch.latest
  if self.native_time==p.time_ms then return end
  local pending=self.native_pending;self.native_pending=nil
  local function angle(a,b) return (a-b+180)%360-180 end
  local result
  local eligible=allowed and p.focused and not batch.overflow
  if eligible and pending and p.epoch==pending.epoch and p.width==pending.width and p.height==pending.height
    and p.time_ms>pending.time and p.time_ms-pending.time<=150 and dx==0 and dy==0
    and math.abs(angle(current.Yaw,pending.base.Yaw))<.001 and math.abs(angle(current.Pitch,pending.base.Pitch))<.001 then
    result={Yaw=angle(current.Yaw+pending.yaw,0),Pitch=math.max(-80,math.min(80,angle(current.Pitch,0)+pending.pitch)),Roll=0}
    self.native_applied=(self.native_applied or 0)+1
  end
  local base=result or current
  self.yaw=base.Yaw;self.pitch=angle(base.Pitch,0)
  local serial=self.look_serial or 0
  local x,y=self:sample_batch(batch,eligible)
  if eligible and dx==0 and dy==0 and (self.look_serial or 0)~=serial then
    self.native_pending={epoch=p.epoch,width=p.width,height=p.height,time=p.time_ms,
      base={Yaw=base.Yaw,Pitch=base.Pitch},yaw=angle(self.yaw,base.Yaw),pitch=self.pitch-angle(base.Pitch,0)}
  end
  self.native_time=p.time_ms
  return x,y,result
end
function M:frame()
  local forward=(down(self.keys,14) and 1 or 0)-(down(self.keys,16) and 1 or 0)
  local right=(down(self.keys,17) and 1 or 0)-(down(self.keys,15) and 1 or 0)
  local length=math.max(1,math.sqrt(forward*forward+right*right));forward=forward/length;right=right/length
  local a=math.rad(self.yaw)
  local jump=self.jumps>0;self.jumps=0
  return {rotation={Pitch=self.pitch,Yaw=self.yaw,Roll=0},look_backend=self.look_backend,jump=jump,
    jump_held=down(self.keys,18),sneak=down(self.keys,19),
    sprint=self.sprinting==true and forward>0,
    direction={X=math.cos(a)*forward-math.sin(a)*right,Y=math.sin(a)*forward+math.cos(a)*right,Z=0}}
end
return M
