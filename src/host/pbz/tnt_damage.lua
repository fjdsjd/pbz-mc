-- TNT and ground fire use the same PBZ damage/health gates as real attacks.
-- No HP writes, gameplay timer or input lives here. The effect adapter keeps
-- an active player potion lease out of MC explosion damage normalization.
local UE=require('UEHelpers')
local json=require('dkjson')
local identity=require('host.pbz.object_identity')
local valid=require('host.pbz.appearance').valid
local rules=require('rules.tnt')
local guard=require('host.pbz.weapon_guard')
local M={};M.__index=M
local capabilities,capability_error,capability_checked
local color={R=0,G=0,B=0,A=0}
-- User-requested extreme TNT damage: 20 times the previous 80 base. Native
-- shields, resistance and player defenses still settle the one real hit.
local attack_base={explosion=1600,fire=80}
local function finite(n)return type(n)=='number' and n==n and math.abs(n)<math.huge end
local function vector(p)
  assert(p and finite(p.X) and finite(p.Y) and finite(p.Z)
    and math.abs(p.X)<1e9 and math.abs(p.Y)<1e9 and math.abs(p.Z)<1e9,'tnt-damage-position')
  return {X=p.X,Y=p.Y,Z=p.Z}
end
local function path(o)return assert(o:GetFullName():match('^[^ ]+ (.+)$'),'tnt-damage-object-path')end
local function native(request)
  local raw,why=PBZMC_NativeHit(json.encode(request))
  if not raw then return nil,why end
  local result,_,err=json.decode(raw)
  if type(result)~='table' then return nil,err or 'tnt-damage-native-receipt' end
  return result
end
function M.ready()
  if not capability_checked then
    capability_checked=true
    local ok,result,why=pcall(function()
      assert(type(PBZMC_NativeHit)=='function','tnt-native-hit-bridge-required')
      return native({phase='capabilities'})
    end)
    if ok and result and type(result.kinds)=='table' then
      local kinds={}
      for key,value in pairs(result.kinds or {})do
        if type(key)=='number' then kinds[value]=true elseif value==true then kinds[key]=true end
      end
      if result.api==2 and result.self_damage==true and kinds.explosion and kinds.fire then capabilities=result end
    end
    if not capabilities then capability_error=not ok and tostring(result) or why or 'tnt-native-hit-api-2-required' end
  end
  return capabilities~=nil,capability_error
end
local function component(actor,class)
  local list=actor:K2_GetComponentsByClass(StaticFindObject(class))
  local result=#list==1 and list[1]:get() or nil
  if not valid(result) or not identity.matches(result:GetOwner(),identity.capture(actor)) then return nil end
  return result
end
local function health(actor)
  local attributes=actor.AttributeSetBase
  if not valid(attributes) then return nil end
  local hp=attributes.Health.CurrentValue
  return finite(hp) and hp or nil
end
local function native_shield(actor)
  local ok,value=pcall(function()return actor.AttributeSetBase.Shield.CurrentValue end)
  return ok and finite(value) and value>=0 and value or nil
end
function M.new(binding,log)
  assert(binding and valid(binding.actor),'tnt-damage-player-unavailable')
  local self=setmetatable({binding=binding,log=log or function()end,pawn=binding.actor,
    pawn_id=identity.capture(binding.actor),world_id=identity.capture(binding.actor:GetWorld()),
    events={},targets={},next_scan=0,report={},guard_classes={}},M)
  self.character=StaticFindObject('/Script/ProjectPBZ.PBZCharacter')
  self.faction=StaticFindObject('/Script/SGameCombatSystem.Default__FactionUtils')
  self.clock=StaticFindObject('/Script/Engine.Default__GameplayStatics')
  self.flash=require('host.pbz.hit_flash').new(binding)
  return self
end
function M:is_current()
  if self.closed then return false end
  local ok,current=pcall(function()
    return self.binding:is_current() and identity.matches(self.binding.actor,self.pawn_id)
      and valid(self.pawn) and identity.matches(self.pawn:GetWorld(),self.world_id)
      and (health(self.pawn) or 0)>0
  end)
  return ok and current or false
end
function M:eligible(row)
  local target=row.actor
  if self:is_current() and identity.matches(target,row.id)
    and require('host.pbz.mob_living').alive(self.binding,target) then return true end
  if not self:is_current() or not valid(target) or not identity.matches(target,row.id)
    or not identity.matches(target:GetWorld(),self.world_id) or not target:IsA(self.character)
    or not target.bCanBeDamaged or (health(target) or 0)<=0 then return false end
  -- Player self-damage is deliberately checked before the hostile filter.
  return row.player or self.faction:GetFactionRelation(self.pawn,target)==2
end
function M:candidates(kind,center)
  local stamp=self.clock:GetTimeSeconds(self.pawn)
  assert(finite(stamp),'tnt-damage-clock')
  local local_blast=kind=='explosion' and center
  if local_blast or stamp>=self.next_scan or stamp<(self.scanned_at or 0) then
    local out,seen={},{}
    local candidates
    if local_blast then
      candidates={}
      UE.GetKismetSystemLibrary():SphereOverlapActors(self.pawn,center,rules.blast_radius,
        require('host.pbz.build_world').object_types,self.character,{self.pawn},candidates)
    else candidates=FindAllOf('PBZCharacter') or {} end
    for _,item in ipairs(candidates)do
      local ok,row=pcall(function()
        local actor=item.GetFullName and item or item:get()
        if not valid(actor) or not actor:IsA(self.character) or identity.matches(actor,self.pawn_id)
          or not identity.matches(actor:GetWorld(),self.world_id) then return nil end
        return {actor=actor,id=identity.capture(actor),player=false}
      end)
      if ok and row then
        local key=tostring(row.id.address)..'/'..row.id.name
        if not seen[key] then seen[key]=true;out[#out+1]=row end
      end
    end
    local group=self.binding.mc_summons
    if group then for _,m in ipairs(group.mobs) do
      if m.health>0 and not m.removed then out[#out+1]={actor=m.actor,id=m.id,mc=true} end
    end end
    -- Apply self-damage last: a fatal self-hit must not retire the source
    -- halfway through dispatching this explosion to its other targets.
    out[#out+1]={actor=self.pawn,id=self.pawn_id,player=true}
    if local_blast then return out end
    self.targets=out;self.scanned_at=stamp;self.next_scan=stamp+rules.fire_interval
  end
  return self.targets
end
function M:clear_line(center,finish,target,source)
  if center.X==finish.X and center.Y==finish.Y and center.Z==finish.Z then return true end
  local ignored={self.pawn};local seen={[self.pawn_id.address]=true}
  for _,actor in ipairs({target,source})do
    if valid(actor) and not seen[actor:GetAddress()] then
      seen[actor:GetAddress()]=true;ignored[#ignored+1]=actor
    end
  end
  local hit={}
  local lib=UE.GetKismetSystemLibrary()
  for _=1,24 do
    local blocked=lib:LineTraceSingle(self.pawn,center,finish,0,false,ignored,0,hit,true,color,color,0)
    assert(type(blocked)=='boolean','tnt-damage-trace-result')
    if not blocked then return true end
    local handle=self.build_world and self.build_world:hit_handle(hit)
    local def=handle and require('content.blocks').get(handle.content_id)
    if not def or def.collision~=false or seen[handle.actor:GetAddress()]then return false end
    seen[handle.actor:GetAddress()]=true;ignored[#ignored+1]=handle.actor
  end
  return false
end
-- A bounded set of points over the TNT body gives partial cover a fractional
-- impulse; wholly enclosed bodies cannot receive a launch through the wall.
local exposure_points={{0,0,0},{-32,-32,-32},{32,32,-32},{-32,32,32},{32,-32,32}}
function M:tnt_exposure(center,state,target)
  local visible=0
  for _,p in ipairs(exposure_points)do
    if self:clear_line(center,{X=state.x+p[1],Y=state.y+p[2],Z=state.z+p[3]},target)then visible=visible+1 end
  end
  return visible/#exposure_points
end
function M:player_gate()
  local status=self.binding.mc_status_service
  assert(status and status:current() and status.binding==self.binding,'tnt-player-status-unavailable')
  local session=status.session
  assert(session and not session.restart_frozen and session.session and not session.session.busy,
    'tnt-player-status-transaction-unavailable')
  assert(type(PBZMC_PollHealth)=='function','tnt-player-health-gate-unavailable')
  local raw,why=PBZMC_PollHealth(status.asc_path);assert(raw,why or 'tnt-player-health-gate-rejected')
  local gate=json.decode(raw)
  assert(type(gate)=='table' and gate.active==true,'tnt-player-health-gate-inactive')
  return status
end
function M:hit(row,amount,action_id,kind,location,direction)
  assert(self:eligible(row),'tnt-damage-target-changed')
  if require('host.pbz.mob_living').find(self.binding,row.actor) then
    local accepted,result=require('host.pbz.mob_living').hit(self.binding,row.actor,
      amount/(kind=='explosion' and 1600/65 or 20),action_id,{direction=direction,knockback=false})
    return result or {dispatched=false,hurt=false,route='mc-living'}
  end
  assert(type(IsInGameThread)=='function' and IsInGameThread(),'tnt-damage-game-thread-required')
  local target=row.actor
  local damage=component(target,'/Script/SGameAttributes.AttributeComponent')
  local reaction=component(target,'/Script/SGameCombatSystem.HitreactComponent')
  assert(valid(damage),'tnt-damage-component-unavailable')
  local status=row.player and self:player_gate() or nil
  local prior_status=status and status.report.last_damage
  local attack=self.pawn.AttributeSetBase.Attack.CurrentValue
  assert(finite(attack) and attack>0 and finite(amount) and amount>0 and amount<=10000
    and amount/attack<=1000,'tnt-damage-attack-snapshot')
  local source=StaticConstructObject(StaticFindObject('/Script/SGameCombatSystem.DamageSource_GameplayEffect'),self.pawn)
  assert(valid(source),'tnt-damage-source-allocation')
  assert(self:eligible(row),'tnt-damage-target-changed-before-dispatch')
  local request={phase='damage',kind=kind,pawn=path(self.pawn),target=path(target),source=path(source),
    component=path(damage),reaction=valid(reaction) and path(reaction) or nil,coefficient=amount/attack,
    location=location,direction=direction,normal={X=-direction.X,Y=-direction.Y,Z=-direction.Z}}
  local result={action_id=action_id,target=row.id.name,player=row.player,requested=amount,before=health(target),
    native_shield_before=native_shield(target)}
  local shachi_before
  if kind=='explosion' and not row.player then shachi_before=guard.prepare(self.guard_classes,target,self.pawn,request,amount) end
  -- The event is already claimed before this call. Never retry native damage
  -- merely because readback, native feedback, red materials or launch failed.
  local receipt,why=native(request)
  result.dispatched=receipt and receipt.dispatched==true or false;result.error=why
  result.blocked=receipt and receipt.blocked==true or false
  if valid(target) and identity.matches(target,row.id) then
    result.after=health(target);result.native_shield_after=native_shield(target)
  end
  if result.before and result.after then result.observed_delta=result.before-result.after end
  if result.native_shield_before and result.native_shield_after then
    result.native_shield_delta=result.native_shield_before-result.native_shield_after
  end
  if status and status.report.last_damage~=prior_status then
    local observed=status.report.last_damage
    if observed then
      result.health_delta=observed.health_delta;result.absorbed=observed.absorbed
      result.totem=observed.totem;result.damage_cause=observed.cause
    end
  end
  local changed=(result.observed_delta or 0)>0 or (result.absorbed or 0)>0 or result.totem==true
  result.health_hit=result.dispatched and not result.blocked and changed or false
  result.native_shield_hit=result.dispatched and not result.blocked and (result.native_shield_delta or 0)>0 or false
  guard.observe(result,shachi_before,target)
  result.hurt=result.health_hit or result.native_shield_hit or result.native_shachi_hit or false
  if not result.hurt or not valid(target) or not identity.matches(target,row.id) then return result end
  if kind=='explosion' and request.phase~='shachi' and (result.after or 0)>0 and valid(reaction) and self:is_current() then
    request.phase='feedback'
    local ok,feedback,err=pcall(native,request)
    result.feedback=ok and feedback and feedback.dispatched==true or false
    result.feedback_error=not ok and tostring(feedback) or err
  end
  -- Upstream ground fire uses weight zero. TakeDamage owns its native events;
  -- do not add a half-second forced flinch by calling PlayHitreact for fire.
  if self:is_current() then
    local ok,shown=pcall(self.flash.show,self.flash,target)
    result.flash=ok and shown or false;result.flash_error=not ok and tostring(shown) or nil
  end
  return result
end
function M:run(kind,center,source,action_id,power,underwater,allied)
  return require('host.pbz.entity_effects').with_attack_base(self.binding,self._run,self,kind,center,source,action_id,power,underwater,allied)
end
function M:_run(kind,center,source,action_id,power,underwater,allied)
  local report={kind=kind,action_id=action_id,considered=0,occluded=0,dispatched=0,hurt=0,
    knocked_back=0,targets={},errors={}}
  self.report=report
  local ok,err=pcall(function()
    assert(type(IsInGameThread)=='function' and IsInGameThread(),'tnt-damage-game-thread-required')
    local ready,why=M.ready();assert(ready,why)
    assert(self:is_current(),'tnt-damage-source-stale')
    assert(type(action_id)=='string' and #action_id>0 and #action_id<=512,'tnt-damage-action-id')
    center=vector(center)
    if kind=='explosion' then assert(power==nil or power==4,'tnt-damage-power-unsupported') end
    if source then
      assert(valid(source) and identity.matches(source:GetWorld(),self.world_id),'tnt-damage-source-actor-stale')
    end
    if self.events[action_id] then report.duplicate=true;return end
    self.events[action_id]=true -- Claim the complete event before any external call.
    local boats=kind=='explosion' and require('host.pbz.boat_service').get(self.binding)
    for _,row in ipairs(self:candidates(kind,center))do
      local eligible_ok,eligible=pcall(self.eligible,self,row)
      if eligible_ok and eligible and not (allied and row.player) then
        local target_ok,target_error=pcall(function()
          local location=vector(row.actor:K2_GetActorLocation())
          local offset={x=location.X-center.X,y=location.Y-center.Y,z=location.Z-center.Z}
          local distance=math.sqrt(offset.x^2+offset.y^2+offset.z^2)
          local blast=kind=='explosion' and rules.blast(distance) or nil
          local coefficient=blast and blast.coefficient or kind=='fire' and rules.fire_damage(distance)
          if not coefficient then return end
          report.considered=report.considered+1
          if not self:clear_line(center,location,row.actor,source) then report.occluded=report.occluded+1;return end
          local direction={X=0,Y=0,Z=1}
          if kind=='explosion' and distance>1e-6 then
            direction={X=offset.x/distance,Y=offset.y/distance,Z=offset.z/distance}
          end
          local result=self:hit(row,attack_base[kind]*coefficient,action_id,kind,location,direction)
          result.distance=distance;result.coefficient=coefficient;result.exposure=blast and blast.exposure
          report.targets[#report.targets+1]=result
          if result.dispatched then report.dispatched=report.dispatched+1 end
          if result.hurt then report.hurt=report.hurt+1 end
          if result.error then report.errors[#report.errors+1]=row.id.name..': '..tostring(result.error) end
          -- A native shield-only hit is real, but its armor/poise response
          -- remains PBZ's. Do not turn this feedback repair into forced launch.
          if (result.health_hit or underwater) and blast and blast.impulse>0 and self:eligible(row)
              and not (boats and boats:piston_rider(row.actor)) then
            local impulse=rules.knockback(offset,blast.impulse)
            local launch_ok,launch_error=pcall(row.actor.LaunchCharacter,row.actor,
              {X=impulse.x,Y=impulse.y,Z=impulse.z},false,false)
            result.knockback=launch_ok;result.knockback_error=not launch_ok and tostring(launch_error) or nil
            if launch_ok then report.knocked_back=report.knocked_back+1 end
          end
        end)
        if not target_ok then report.errors[#report.errors+1]=row.id.name..': '..tostring(target_error) end
      end
    end
  end)
  if not ok then report.error=tostring(err) end
  if kind=='explosion' or report.error or #report.errors>0 then
    pcall(self.log,'MC '..kind..' action='..tostring(action_id)..' dispatched='..report.dispatched
      ..' hurt='..report.hurt..' occluded='..report.occluded..' knockback='..report.knocked_back
      ..' errors='..#report.errors..(report.error and ' error='..report.error or ''))
  end
  return report
end
function M:explode(center,source_actor,action_id,power,underwater,allied)
  return self:run('explosion',center,source_actor,action_id,power,underwater,allied)
end
function M:burn(center,action_id)return self:run('fire',center,nil,action_id)end
function M:close()
  if self.closed then return end
  self.closed=true;self.events={};self.targets={}
  self.flash:close()
end
return M
