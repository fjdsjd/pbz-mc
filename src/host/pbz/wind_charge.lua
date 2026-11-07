local rules=require('rules.wind_charge')
local burst=require('host.pbz.wind_burst')
local valid=require('host.pbz.appearance').valid
local M={};M.__index=M
local function clock(pawn)return StaticFindObject('/Script/Engine.Default__GameplayStatics'):GetTimeSeconds(pawn)end
local function copy(v)return {X=v.X,Y=v.Y,Z=v.Z}end
local function subtract(a,b)return {X=a.X-b.X,Y=a.Y-b.Y,Z=a.Z-b.Z}end
local function at(p,t)return rules.advance(p.position,p.velocity,t-p.time)end
local function along(a,b,t)return rules.advance(a,subtract(b,a),t)end
local zero={X=0,Y=0,Z=0}
local sword=require('content.combat_profiles').get('pbzmc:diamond_sword')
local direct_damage=sword.adventure_attack/sword.free_melee_damage
function M.new(combat)
  return setmetatable({combat=combat,binding=combat.binding,charges={},serial=0,
    report={thrown=0,burst=0,deflected=0,expired=0,peak=0}},M)
end
function M:sweep(p,start,finish)
  local ignored={self.binding.actor,p.handle.actor}
  for _=1,12 do
    local yes,hit,actor=self.combat:trace(start,finish,rules.hit_radius,nil,ignored)
    if not yes then return false end
    local build=require('host.pbz.building_service').get(self.binding)
    local handle=build and build.world:hit_handle(hit)
    local def=handle and require('content.blocks').get(handle.content_id)
    if not def or not def.fluid or not valid(actor) then return true,hit,actor end
    ignored[#ignored+1]=actor
  end
  -- Resume at the last proven position if an unusually long frame traverses
  -- more than twelve overlapping fluid proxies. Never pass an untested wall.
  return nil
end
function M:impact(p,hit,target)
  local where=hit.bStartPenetrating and p.position or copy(hit.ImpactPoint)
  local character=valid(target) and target:IsA(StaticFindObject('/Script/ProjectPBZ.PBZCharacter'))
  local center=character and where or rules.advance(where,hit.ImpactNormal,25)
  local report={id=p.id,hand=p.hand,direct=false,center=copy(center)}
  self.report.burst=self.report.burst+1;self.report.last_impact=report
  if character then
    report.direct=self.combat.damage:hit(target,direct_damage,p.id..'/impact',{
      kind='wind_charge',weapon_id=rules.id,direction=p.velocity,location=where})
    if report.direct then self.combat.hits=self.combat.hits+1 end
  end
  report.impulse=burst.apply(self.combat,center)
  if report.impulse.switch_error then self.combat.log('MC wind switch: '..tostring(report.impulse.switch_error)) end
  report.audio=self.combat:sound('mace_wind',center)
  local ok,result=pcall(require('host.pbz.sprite_particles').impact,self.combat,{wind=center,small=true})
  if ok then report.particles=result
  else self.combat.log('MC wind particles: '..tostring(result));report.fx_error=tostring(result) end
end
function M:tick()
  if self.closed or not self.binding:is_current() then self:close();return end
  local now=clock(self.binding.actor)
  if now<self.next_tick then return end
  self.next_tick=now+1/40
  local eye=self.combat.pc.PlayerCameraManager.CameraCachePrivate.POV.Location
  for i=#self.charges,1,-1 do
    local p=self.charges[i]
    local t=math.min(now,p.expires)
    local finish=at(p,t)
    local hit,result,target=self:sweep(p,p.position,finish)
    if hit or now>=p.expires then
      table.remove(self.charges,i);self.visual:release(p.handle)
      -- Retire before damage/knockback, including if a native callback fails.
      if hit then
        local ok,why=pcall(self.impact,self,p,result,target)
        if not ok then self.report.error=tostring(why);self.combat.log('MC wind impact: '..self.report.error) end
      else self.report.expired=self.report.expired+1 end
    elseif hit~=nil then
      p.position=finish;p.time=t
      self.visual:draw(p.handle,finish,t-p.born,eye)
    else
      p.time=t
    end
  end
  if #self.charges==0 and self.timer then CancelDelayedAction(self.timer);self.timer=nil end
end
function M:_throw(record)
  local status=self.binding.mc_status_service
  if self.closed or not self.binding:is_current() or not status or not status:current() or #self.charges>=rules.limit
    or self.binding.actor.AttributeSetBase.Health.CurrentValue<=0
    or require('rules.status_effects').remaining(status.value,rules.id)>0 then return false,'fail' end
  local now=clock(self.binding.actor)
  local src=record.source..'/'..record.action_id
  if self.last_request==src then return false,'fail' end
  local pawn=self.binding.actor;local pos,dir=self.combat:aim()
  local flight=self.binding.mc_gliding or self.binding.mc_creative_flight
  local inherited=flight and flight.velocity or pawn:GetVelocity()
  local velocity=rules.launch(dir,inherited,flight~=nil or pawn.CharacterMovement.MovementMode==3)
  if not self.visual then self.visual=require('host.pbz.wind_visuals').new(self.binding) end
  local handle=self.visual:acquire(pos)
  local p={position=copy(pos),velocity=velocity,handle=handle,born=now,time=now,armed=now+rules.deflect_delay,
    expires=now+rules.lifetime,id=src,hand=record.hand}
  local ok,why=pcall(function()
    self.visual:draw(handle,pos,0,self.combat.pc.PlayerCameraManager.CameraCachePrivate.POV.Location)
    if not self.timer then
      self.next_tick=now;self.timer=LoopInGameThreadAfterFrames(1,function()
        local ran,err=pcall(self.tick,self)
        if not ran then self.report.error=tostring(err);self.combat.log('MC wind flight: '..self.report.error);self:close() end
      end)
      assert(self.timer,'wind-flight-scheduler')
    end
    local committed,reason=status:projectile_cooldown(record,rules.id,status.mode=='adventure' and not self.binding.mc_creative)
    assert(committed,reason)
  end)
  if not ok then
    self.visual:release(handle)
    if #self.charges==0 and self.timer then CancelDelayedAction(self.timer);self.timer=nil end
    error(why)
  end
  self.last_request=src;self.charges[#self.charges+1]=p
  self.report.thrown=self.report.thrown+1;self.report.peak=math.max(self.report.peak,#self.charges)
  self.report.last_throw_audio=self.combat:sound('wind_throw',pos)
  return true,'success'
end
function M:throw(record)
  local ok,result,outcome=pcall(self._throw,self,record)
  if not ok then self.report.error=tostring(result);self.combat.log('MC wind throw: '..self.report.error);return false,'fail' end
  return result,outcome
end
function M:redirect(p,position,direction,now)
  local length=math.sqrt(direction.X^2+direction.Y^2+direction.Z^2)
  if length<=.01 then return false end
  p.position=position;p.time=now;p.velocity=rules.advance(zero,direction,rules.speed/length)
  p.armed=now+rules.deflect_delay;p.expires=now+rules.lifetime
  self.report.deflected=self.report.deflected+1;return true
end
function M:melee(origin,dir,near,far)
  if #self.charges==0 then return false end
  local now=clock(self.binding.actor)
  local start,finish=rules.advance(origin,dir,near),rules.advance(origin,dir,far)
  local best,point,first
  for _,p in ipairs(self.charges) do
    if now>=p.armed and now<p.expires then
      local pos=at(p,now)
      local t=rules.intercept(start,finish,pos,30)
      if t and (not first or t<first) and self:sweep(p,p.position,pos)==false
        and burst.clear(self.binding,origin,pos,{self.binding.actor,p.handle.actor}) then best,point,first=p,pos,t end
    end
  end
  if best and self:redirect(best,point,dir,now) then self.combat:sound('sword_weak',point);return true end
  return false
end
function M:arrow(start,finish,velocity,t0,t1,obstruction)
  if #self.charges==0 or t1<=t0 then return false end
  local best,best_pos,first
  for _,p in ipairs(self.charges) do
    local early=math.max(0,(p.armed-t0)/(t1-t0))
    local late=math.min(1,(p.expires-t0)/(t1-t0),obstruction or 1)
    if early<late then
      local a,b=at(p,t0+early*(t1-t0)),at(p,t0+late*(t1-t0))
      local t=rules.intercept(subtract(along(start,finish,early),a),subtract(along(start,finish,late),b),zero,rules.hit_radius+3)
      if t then
        local fraction=early+(late-early)*t
        if (not obstruction or fraction<obstruction) and (not first or fraction<first) then
          local contact=along(a,b,t)
          if self:sweep(p,p.position,contact)==false then best,best_pos,first=p,contact,fraction end
        end
      end
    end
  end
  return best~=nil and self:redirect(best,best_pos,velocity,t1)
end
function M:close()
  if self.closed then return end
  self.closed=true
  if self.timer then CancelDelayedAction(self.timer);self.timer=nil end
  if self.visual then self.visual:close() end
  self.charges={}
end
return M
