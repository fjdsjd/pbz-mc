local defs=require('content.summon_mobs')
local attacks=require('rules.summon_attacks')
local world=require('host.pbz.undead_world')
local models=require('host.pbz.undead_models')
local ids=require('host.pbz.object_identity')
local follow=require('rules.mob_follow')
local ai=require('rules.mob_ai')
local valid=require('host.pbz.appearance').valid
local M={};M.__index=M
local function distance(a,b)
  return (a.X-b.X)^2+(a.Y-b.Y)^2+(a.Z-b.Z)^2
end
local function remove(list,index)
  local item=table.remove(list,index)
  if ids.matches(item.actor,item.id) then item.actor:K2_DestroyActor() end
end
function M.new(combat)
  local self=setmetatable({combat=combat,binding=combat.binding,world=world.new(combat),by_actor={},
    clock=StaticFindObject('/Script/Engine.Default__GameplayStatics'),
    mobs={},shots={},serial=0,attack_serial=0,report={spawned=0,dismissed=0,melee=0,launched=0,hits=0,scans=0,exploded=0}},M)
  combat.binding.mc_summons=self
  self.sounds=require('host.pbz.mob_sounds').new(combat.binding)
  return self
end
function M:ignored()
  local list={self.binding.actor}
  for _,m in ipairs(self.mobs) do if ids.matches(m.actor,m.id) then list[#list+1]=m.actor end end
  return list
end
function M:start()
  if self.loop then return end
  local loop
  loop=LoopInGameThreadAfterFrames(1,function()
    if self.loop~=loop then return end
    local ok,why=pcall(self.tick,self)
    if not ok then
      self.report.error=tostring(why);self.combat.log('MC summon update failed: '..self.report.error);self:close()
    end
  end)
  self.loop=loop
end
function M:use(record)
  local stack=record.equipment[record.hand]
  local def=stack and defs.egg(stack.content_id)
  local pawn=self.binding.actor
  if not def or not self.binding:is_current() or pawn.AttributeSetBase.Health.CurrentValue<=0 then return false,'fail' end
  local source=record.source..'/'..record.action_id
  if source==self.request then return false,'fail' end
  self.request=source
  local aims=function()return self.combat:aim()end
  local build=require('host.pbz.building_service').get(self.binding)
  if build and build.spawners then
    local handled,status=build.spawners:use_egg(def,aims)
    if handled~=nil then return handled,status end
  end
  if self.combat.context and self.combat.context.sneaking then
    local p,d=aims();local yes,_,actor=self.combat:trace(p,world.offset(p,d,600),3)
    if yes and valid(actor) then
      for i,m in ipairs(self.mobs) do
        if ids.matches(actor,m.id) then
          self:remove_mob(m,'dismissed');self.report.dismissed=self.report.dismissed+1;self.next_scan=0
          return true,'success'
        end
      end
    end
  end
  if #self.mobs>=defs.limit then return false,'fail' end
  local point=self.world:spawn_point(def,aims,self:ignored())
  if not point then return false,'fail' end
  return self:spawn(def,point)
end
function M:spawn(def,point,options)
  if #self.mobs>=defs.limit or not self.binding:is_current()
      or self.binding.actor.AttributeSetBase.Health.CurrentValue<=0 then return false,'fail' end
  self.serial=self.serial+1
  local ok,m=pcall(self.world.create,self.world,def,point,self.serial,options and options.exact)
  if not ok then
    local message=tostring(m)
    if self.report.spawn_error~=message then self.combat.log('MC summon creation failed: '..message) end
    self.report.spawn_error=message
    return false,'fail'
  end
  if not m then return false,'fail' end
  if options and options.command then m.command_home=world.copy(m.position) end
  self.mobs[#self.mobs+1]=m
  self.by_actor[m.id.address]=m
  self.report.spawned=self.report.spawned+1;self.next_scan=0;self.next_think=0
  self:start()
  return true,'success',m
end
-- Authoritative command hooks keep the same list, AI and owned actor cleanup.
function M:contains(m)
  if not m or not ids.matches(m.actor,m.id) then return false end
  for _,entry in ipairs(self.mobs)do if entry==m then return true end end
  return false
end
function M:remove_mob(m,reason)
  for i,entry in ipairs(self.mobs)do
    if entry==m then
      m.health=0;m.removed=true;m.steer=nil;m.target=nil;m.path=nil
      self.by_actor[m.id.address]=nil
      remove(self.mobs,i);self.next_scan=0;self.next_think=0
      self.report.last_removed={serial=m.serial,reason=reason or 'command'}
      return true
    end
  end
  return false,'summon-not-owned'
end
function M:command_move(m,position,yaw)
  assert(self:contains(m),'summon-command-stale')
  m.position=world.copy(position);m.command_home=world.copy(position);m.yaw=yaw
  m.target=nil;m.path=nil;m.steer=nil;m.last_progress=nil;m.repath=nil
  m.move:StopMovementImmediately();self.next_think=0;self.next_scan=0
end
function M:target(m,ignore)
  if m.target and (m.can_see or m.ai and m.ai.sonic) and ids.matches(m.target.actor,m.target.id)
      and self.combat and self.combat.damage:eligible(m.target.actor)
      and distance(m.position,m.target.actor:K2_GetActorLocation())<=defs.detection^2 then
    return m.target
  end
  local choices={}
  for _,e in ipairs(self.candidates) do
    local d=distance(m.position,e.pos)
    if d<=defs.detection^2 then choices[#choices+1]={enemy=e,distance=d} end
  end
  table.sort(choices,function(a,b)return a.distance<b.distance end)
  -- A nearby visible enemy wins. If a crowd is behind cover, rotate through
  -- the remaining candidates next scan instead of tracing the whole crowd.
  local rest=math.max(0,#choices-2)
  for i=1,math.min(5,#choices) do
    if self.sight_budget and self.sight_budget<=0 then return nil,true end
    if self.sight_budget then self.sight_budget=self.sight_budget-1 end
    local index=i<=2 and i or 3+((m.sight_cursor or 0)+i-3)%rest
    local e=choices[index].enemy
    if ids.matches(e.actor,e.id) and (m.ai and m.ai.sonic or self.world:sight(m.position,e.pos,e.actor,ignore)) then return e end
  end
  if rest>0 then m.sight_cursor=((m.sight_cursor or 0)+3)%rest end
end
function M:hit(def,target,position,dir,mode,serial,amount)
  -- Recheck faction on contact. Allegiance can change after the shot is fired.
  if not self.combat.damage:eligible(target) then return false end
  if (amount or def.damage)<=0 then return false end
  local melee=attacks.contact(mode) or mode=='fang'
  local hit=self.combat.damage:hit(target,amount or def.damage,'summon/'..serial,
    {kind=melee and 'sword' or 'arrow',weapon_id=melee and 'pbzmc:wooden_sword' or 'pbzmc:bow',
     direction=dir,location=position})
  if hit then
    self.report.hits=self.report.hits+1
    self.report.last_hit={species=def.name,target=target:GetFullName(),kind=mode,
      hp=self.combat.damage.report.observed_delta,shield=self.combat.damage.report.native_shield_delta}
    local effect=require('rules.mob_effects').contact(def.name)
    if effect then
      local service=require('host.pbz.command_service').get(self.binding)
      if service then service.entities:apply_actor(target,effect[1],effect[2],effect[3]or 0)end
    end
  end
  return hit
end
function M:area(def,kind,serial,point,radius,impulse,ignore)
  for _,row in ipairs(self.world:enemies(point,radius,ignore)) do
    local dir,range=world.direction(point,row.pos)
    local exposure=1-range/radius
    if exposure>0 and self.world:sight(point,row.pos,row.actor,ignore) then
      local hit=self:hit(def,row.actor,row.pos,dir,kind,serial,math.max(1,def.damage*exposure))
      if hit and impulse and ids.matches(row.actor,row.id) then
        row.actor:LaunchCharacter({X=dir.X*impulse*exposure,Y=dir.Y*impulse*exposure,
          Z=math.max(.25,dir.Z)*impulse*exposure},false,false)
      end
    end
  end
end
function M:ignite(aim)
  local p,d=aim()
  local yes,_,actor=self.combat:trace(p,world.offset(p,d,500),3)
  if yes and valid(actor) then
    for _,m in ipairs(self.mobs) do
      if m.def.attack=='creeper' and ids.matches(actor,m.id) then m.lit=true;return true end
    end
  end
  return false
end
function M:creeper(m,target,now,ignore)
  local progress=m.fuse or 0
  local pos=m.position
  local dest=target and world.copy(target.actor:K2_GetActorLocation())
  local range=dest and math.sqrt(distance(pos,dest))
  local visible=false
  if range and range<=600 then
    if now>=(m.next_sight or 0) and self.sight_budget>0 then
      self.sight_budget=self.sight_budget-1;m.next_sight=now+.15;m.sight_time=now
      m.can_see=self.world:sight(pos,dest,target.actor,ignore)
    end
    visible=m.can_see and now-(m.sight_time or 0)<=.3
  end
  local next_fuse=attacks.fuse(progress,now-(m.fuse_time or now),range,visible,m.lit)
  m.fuse_time=now;m.fuse=next_fuse
  local tnt=require('host.pbz.tnt_service').get(self.binding)
  if progress==0 and next_fuse>0 and tnt then tnt:sound('fuse',{x=pos.X,y=pos.Y,z=pos.Z}) end
  models.fuse(m,next_fuse,self.binding.material)
  if next_fuse>=1.5 then
    m.exploded=true;self.report.exploded=self.report.exploded+1
    self.attack_serial=self.attack_serial+1
    local origin={X=pos.X,Y=pos.Y,Z=pos.Z-m.def.height/2+16}
    if tnt then tnt:blast_world({x=origin.X,y=origin.Y,z=origin.Z},3,true) end
    self:area(m.def,'blast',self.attack_serial,origin,600,950,ignore)
  end
  return next_fuse>0
end
function M:attack(m,target,now,ignore,selected_kind)
  if now<(m.next_attack or 0) or not self.combat.damage:eligible(target) then return end
  local p=m.position
  local start={X=p.X,Y=p.Y,Z=p.Z+m.def.height*.20}
  local finish=world.copy(target:K2_GetActorLocation())
  local kind=selected_kind or m.def.attack
  local visible=kind=='sonic' or m.can_see and now-(m.sight_time or 0)<=.25
  if not visible then return end
  local dir,range=world.direction(start,finish)
  if kind=='flame' and range<200 then kind='melee' end
  local charging=m.charge_started
  m.charging_kind=kind
  local ready=ai.ready(m,now,target:GetAddress(),range,visible,attacks.contact(kind))
  if not charging and m.charge_started then self.sounds:play(m,'charge',now)end
  if not ready then return end
  if not attacks.contact(kind) and #self.shots>=24 then return end
  m.last_attack=now;m.last_attack_kind=kind;m.charging_kind=nil
  self.sounds:play(m,attacks.contact(kind) and 'attack' or 'shoot',now)
  self.attack_serial=self.attack_serial+1
  if attacks.contact(kind) then
    self.report.melee=self.report.melee+1
    local hit=self:hit(m.def,target,finish,dir,kind,self.attack_serial,m.attack_damage or m.ai.damage or m.def.damage)
    if hit and valid(target) then
      if kind=='ram' then target:LaunchCharacter({X=dir.X*520,Y=dir.Y*520,Z=180},false,false)
      elseif kind=='tongue' then target:LaunchCharacter({X=-dir.X*240,Y=-dir.Y*240,Z=70},false,false)
      elseif kind=='pounce' then m.actor:LaunchCharacter({X=dir.X*180,Y=dir.Y*180,Z=125},false,false) end
    end
    return
  end
  local spec=assert(attacks.projectile(kind),kind)
  if spec.delay then
    local at=start
    if kind=='fang' then
      local excluded={table.unpack(ignore)};excluded[#excluded+1]=target
      at=self.world:ground(finish,excluded,20,target.CapsuleComponent:GetScaledCapsuleHalfHeight()+100)
    end
    if not at then return end
    local shot=models.projectile(self.combat,self.world.models,kind,at,kind=='fang' and {Pitch=0,Yaw=0,Roll=0} or world.rotation(dir))
    if kind=='beam' then shot.actor:SetActorScale3D({X=range/9,Y=1,Z=1}) end
    shot.effect=true;shot.position=at;shot.def=m.def;shot.kind=kind;shot.serial=self.attack_serial
    shot.target=target;shot.target_id=ids.capture(target);shot.aim=finish;shot.origin=start;shot.direction=dir
    shot.impact_at=now+(kind=='sonic'and 0 or spec.delay);shot.expires=shot.impact_at+.35
    if kind=='sonic'then shot.sonic=m.ai.sonic end
    self.shots[#self.shots+1]=shot;self.report.launched=self.report.launched+1
    return
  end
  local speed,gravity=spec.speed,spec.gravity or 0
  local velocity=attacks.launch(start,finish,target:GetVelocity(),speed,gravity)
  if not velocity then return end
  local shot=models.projectile(self.combat,self.world.models,kind,start,world.rotation(velocity))
  shot.position=start;shot.velocity=velocity
  shot.gravity=gravity;shot.def=m.def;shot.kind=kind;shot.serial=self.attack_serial;shot.expires=now+4
  if kind=='potion'then
    local entities=self.combat:potion_service():entities();local h=entities:actor_handle(target)
    local active=entities.effects[h.id];local effects=active and active.values or {}
    local hp=target.AttributeSetBase.Health.CurrentValue/target.AttributeSetBase.Health_Max.CurrentValue*20
    shot.potion='pbzmc:splash_potion_'..require('rules.mob_effects').witch(range,hp,effects,math.random)
  end
  if spec.homing then shot.target=target;shot.target_id=ids.capture(target) end
  self.shots[#self.shots+1]=shot;self.report.launched=self.report.launched+1
end
function M:flight(now,dt,ignore)
  if dt<=0 then return end
  for i=#self.shots,1,-1 do
    local s=self.shots[i]
    if not ids.matches(s.actor,s.id) then remove(self.shots,i)
    elseif s.effect then
      if s.impact_at and now>=s.impact_at then
        s.impact_at=nil
        if ids.matches(s.target,s.target_id) then
          local dest=world.copy(s.target:K2_GetActorLocation())
          local within=s.kind=='sonic'and (dest.X-s.origin.X)^2+(dest.Y-s.origin.Y)^2<=1500^2
            and math.abs(dest.Z-s.origin.Z)<=2000 or s.kind~='sonic'and distance(dest,s.origin)<=1600^2
          if (s.kind~='fang' or distance(dest,s.aim)<=130^2) and within
              and (s.kind=='sonic'or self.world:sight(s.origin,dest,s.target,ignore)) then
            local hit=self:hit(s.def,s.target,dest,s.direction,s.kind,s.serial,s.sonic and s.sonic.attack_damage)
            if hit and s.sonic and ids.matches(s.target,s.target_id)then
              s.target:LaunchCharacter({X=s.direction.X*(s.sonic.knockback_horizontal_strength or 2.5)*100,
                Y=s.direction.Y*(s.sonic.knockback_horizontal_strength or 2.5)*100,
                Z=s.direction.Z*(s.sonic.knockback_vertical_strength or .5)*100},false,false)
            end
          end
        end
      end
      if now>=s.expires then remove(self.shots,i) end
    elseif now>s.expires then remove(self.shots,i)
    else
      local spec=attacks.projectile(s.kind)
      if spec.homing and ids.matches(s.target,s.target_id) and self.combat.damage:eligible(s.target) then
        local dir=world.direction(s.position,s.target:K2_GetActorLocation())
        s.velocity=world.offset({X=0,Y=0,Z=0},dir,spec.speed)
      end
      local dest=world.offset(s.position,s.velocity,dt)
      dest.Z=dest.Z-.5*s.gravity*dt*dt;s.velocity.Z=s.velocity.Z-s.gravity*dt
      local hit,contact,actor=self.combat:trace(s.position,dest,4,nil,ignore)
      if hit then
        local point=world.copy(contact.ImpactPoint)
        if s.potion then self.combat:potion_service():impact(require('rules.potions').get(s.potion),point,valid(actor)and ids.capture(actor),true)
        elseif spec.splash then self:area(s.def,s.kind,s.serial,point,spec.splash,spec.impulse,ignore)
        elseif valid(actor) then self:hit(s.def,actor,point,s.velocity,s.kind,s.serial) end
        remove(self.shots,i)
      else
        s.position=dest
        s.actor:K2_SetActorLocationAndRotation(dest,world.rotation(s.velocity),false,{},true)
      end
    end
  end
end
function M:think(m,now,player,scan,ignore)
  local aura=require('rules.mob_effects').aura[m.def.name]
  if aura and now>=(m.effect_aura_at or 0)then
    m.effect_aura_at=now+aura.interval
    local service=require('host.pbz.command_service').get(self.binding)
    if service then
      for _,row in ipairs(self.world:enemies(m.position,aura.radius,ignore))do
        service.entities:apply_actor(row.actor,aura.id,aura.ticks,aura.amplifier)
      end
    end
  end
  m.position=world.copy(m.actor:K2_GetActorLocation())
  self.sounds:tick(m,now,player)
  if m.no_ai then m.steer=nil;m.target=nil;m.path=nil;return end
  local kind=m.def.attack
  local fluid=self.binding.mc_fluid_sampler
  if m.def.aquatic and now>=(m.sample_fluid or 0) then
    m.sample_fluid=now+.25
    local pos=m.position
    local wet=m.move.MovementMode==4 or (fluid and fluid:water_at(pos.X,pos.Y,pos.Z)) or false
    if wet~=m.swimming then
      if wet then m.move:SetMovementMode(5,0) elseif m.swimming then m.move:SetMovementMode(3,0) end
      m.swimming=wet;m.path=nil
    end
  end
  local home=m.command_home or {X=player.X,Y=player.Y,Z=player.Z-self.binding.actor.CapsuleComponent:GetScaledCapsuleHalfHeight()+m.def.height/2}
  local home_distance=math.sqrt(distance(home,m.position))
  local walking,recover=follow.goal(m,home_distance,m.target~=nil)
  m.following=walking
  if recover then
    m.target=nil;m.path=nil
    if now>=(m.next_teleport or 0) and (self.world.teleport_budget or 0)>0 then
      self.world.teleport_budget=self.world.teleport_budget-1
      local attempt=m.teleport_attempt or 0
      local feet={X=home.X,Y=home.Y,Z=home.Z-m.def.height/2}
      local point=self.world:follow_position(m,feet,attempt)
      m.teleport_attempt=attempt+1
      if point and m.actor:K2_SetActorLocation(point,false,{},true) then
        m.move:StopMovementImmediately();m.position=point;m.steer=nil;m.path=nil;m.last_progress=nil;m.stuck_since=nil
        m.teleports=(m.teleports or 0)+1;m.teleport_attempt=0;m.next_teleport=now+follow.retry
        self.sounds:play(m,'teleport',now,player)
        return
      elseif m.teleport_attempt>=follow.attempts then m.teleport_attempt=0;m.next_teleport=now+follow.retry end
    end
  elseif kind~='passive' and now>=(m.next_target_scan or 0) and (self.target_budget or 0)>0 then
    self.target_budget=self.target_budget-1
    local chosen,deferred=self:target(m,ignore)
    if not deferred then m.next_target_scan=now+.45+(m.serial%7)*.03 end
    if chosen then m.target=chosen;m.target_seen=now
    elseif not deferred and now-(m.target_seen or 0)>(m.ai and m.ai.forget or 3) then m.target=nil end
  end
  local target=m.target
  if target and (not ids.matches(target.actor,target.id) or not self.combat.damage:eligible(target.actor)) then target=nil;m.target=nil end
  if kind=='creeper' and self:creeper(m,target,now,ignore) then
    m.steer=nil;m.path=nil
    return
  end
  local destination=target and world.copy(target.actor:K2_GetActorLocation()) or home
  m.look_at=destination
  local range=target and attacks.reach(kind,m.def.radius,target.actor.CapsuleComponent:GetScaledCapsuleRadius())
    or m.command_home and 120 or follow.stop
  if target and m.ai and m.ai.range then range=m.ai.range end
  local flying_attack=true
  if target and m.ai and (m.ai.swoop or m.ai.charge) then
    local prior=m.flight_progress
    local stalled=prior and m.steer and now-prior.at>.5 and distance(prior.pos,m.position)<20^2
    if not prior or now-prior.at>.5 then m.flight_progress={at=now,pos=world.copy(m.position)} end
    destination,flying_attack=ai.fly_goal(m,now,destination,stalled)
  end
  local dx,dy=destination.X-m.position.X,destination.Y-m.position.Y
  local dz=destination.Z-m.position.Z
  local selected_kind
  if target and m.ai.sonic then
    local reach=attacks.reach('melee',m.def.radius,target.actor.CapsuleComponent:GetScaledCapsuleRadius())
    selected_kind=ai.sonic_kind(m,now,target.id.address,math.sqrt(dx*dx+dy*dy),math.abs(dz),reach)
    range=selected_kind=='sonic'and 1500 or reach
  end
  if m.def.flies then destination.Z=destination.Z+(attacks.contact(kind) and 25 or 125) end
  local high=target and attacks.projectile(kind) and range or m.def.height/2+110
  if selected_kind=='sonic'then high=2000 end
  local in_range=not target and not m.following or dx*dx+dy*dy<=range*range and math.abs(dz)<high
  if m.ai.sonic and m.charging_kind=='sonic'and m.charge_started then in_range=true end
  if kind=='creeper' and target then in_range=distance(m.position,destination)<=range*range end
  if target and in_range and selected_kind~='sonic' then
    if now>=(m.next_sight or 0) and self.sight_budget>0 then
      self.sight_budget=self.sight_budget-1
      m.next_sight=now+.15;m.sight_time=now;m.can_see=self.world:sight(m.position,destination,target.actor,ignore)
    end
    if not m.can_see or now-(m.sight_time or 0)>.3 then
      in_range=false;ai.ready(m,now,target.id.address,range,false,false)
    end
  end
  if in_range then
    m.steer=nil;m.path=nil;m.last_progress=nil
    if target then
      local dir=world.direction(m.position,destination)
      local yaw=world.rotation(dir).Yaw
      if not m.ai.stationary and (not m.yaw or math.abs((yaw-m.yaw+180)%360-180)>2)then
        m.actor:K2_SetActorRotation({Pitch=0,Yaw=yaw,Roll=0},false);m.yaw=yaw
      end
      if kind~='creeper' and flying_attack and (not m.ai.sonic or selected_kind)then self:attack(m,target.actor,now,ignore,selected_kind) end
      if not m.ai.stationary and m.ai.follow_target and dx*dx+dy*dy>(m.ai.minimum+100)^2 then
        self.world:move_to(m,destination,now)
      end
    end
  else
    if m.ai.stationary then m.steer=nil;m.path=nil
    else self.world:move_to(m,destination,now)end
    if target then ai.ready(m,now,target.id.address,range,false,false) end
    if target and m.ai and m.ai.leap and m.move.MovementMode==1 and now>=(m.next_leap or 0)
        and dx*dx+dy*dy>=200^2 and dx*dx+dy*dy<=400^2 and m.steer then
      m.next_leap=now+.5
      if math.random(1,5)==1 then
        m.actor:LaunchCharacter({X=m.steer.X*400,Y=m.steer.Y*400,Z=(m.ai.leap.yd or .4)*1000},false,true)
      end
    end
    if m.def.aquatic and not m.def.amphibious and not m.swimming and m.move.MovementMode==1
        and now>=(m.next_flop or 0) and m.steer then
      m.next_flop=now+1.1;m.actor:LaunchCharacter({X=m.steer.X*85,Y=m.steer.Y*85,Z=135},false,false)
      self.sounds:play(m,'flop',now,player)
    end
  end
  if m.ai and m.ai.slime and m.move.MovementMode==1 and now>=(m.next_hop or 0) then
    local d=m.steer or {X=0,Y=0};local speed=m.move.MaxWalkSpeed
    local boost=require('rules.status_effects').level(m.status,'jump_boost')
    m.actor:LaunchCharacter({X=d.X*speed,Y=d.Y*speed,Z=420+200*boost},true,true)
    m.next_hop=now+(m.target and .4 or 1)+math.random()*.5
    self.sounds:play(m,'jump',now,player)
  end
end
function M:tick()
  local began=os.clock()
  if not self.binding:is_current() or self.binding.actor.AttributeSetBase.Health.CurrentValue<=0 then self:close();return end
  if #self.mobs==0 and #self.shots==0 then self:stop_loop();return end
  local pawn=self.binding.actor
  local now=self.clock:GetTimeSeconds(pawn)
  local elapsed=math.max(0,now-(self.last_tick or now));self.last_tick=now
  if elapsed==0 then return end
  local think=now>=(self.next_think or 0)
  if think then
    self.world.path_budget=1;self.world.probe_budget=2;self.world.teleport_budget=1
    self.sight_budget=8;self.target_budget=2
    local camera=require('host.pbz.first_person_camera').get()
    self.suspended=camera and (camera.inventory or camera:native_takeover()) or false
    self.next_think=now+.075
  end
  if self.suspended then
    if think then for _,m in ipairs(self.mobs) do m.fuse_time=nil end end
    return
  end
  if think then
    local player=world.copy(pawn:K2_GetActorLocation())
    self.player_position=player
    local rotation=self.combat.pc and self.combat.pc:GetControlRotation()
    if rotation then self.sounds.yaw=rotation.Yaw end
    for i=#self.mobs,1,-1 do
      if not ids.matches(self.mobs[i].actor,self.mobs[i].id) then self:remove_mob(self.mobs[i],'stale') end
    end
    self.ignore=self:ignored()
    local scan=now>=(self.next_scan or 0)
    if scan then
      self.candidates={}
      for _,m in ipairs(self.mobs) do
        if m.def.attack~='passive' then
          self.candidates=self.world:enemies(player,defs.leash+defs.detection,self.ignore)
          self.report.scans=self.report.scans+1;break
        end
      end
      -- Command-created/teleported creatures keep a world home. Scan their
      -- remote neighborhoods too, bounded by the existing twelve-creature cap.
      local seen={};for _,e in ipairs(self.candidates)do seen[e.id.address]=true end
      for _,m in ipairs(self.mobs)do
        if m.command_home and m.def.attack~='passive'and not m.no_ai and distance(player,m.position)>defs.leash^2 then
          for _,e in ipairs(self.world:enemies(m.position,defs.detection,self.ignore))do
            if not seen[e.id.address]then seen[e.id.address]=true;self.candidates[#self.candidates+1]=e end
          end
          self.report.scans=self.report.scans+1
        end
      end
      self.next_scan=now+.5
    end
    for i=#self.mobs,1,-1 do
      local m=self.mobs[i]
      if (m.health or 20)<=0 then
        if not m.dying_until or now>=m.dying_until then self:remove_mob(m,'health');self.ignore=self:ignored()
        else m.actor:K2_SetActorRotation({Pitch=0,Yaw=m.yaw or 0,Roll=math.min(90,90*(1-(m.dying_until-now)/.6))},false) end
      else
        self:think(m,now,player,scan,self.ignore)
        if m.exploded then self:remove_mob(m,'exploded');self.ignore=self:ignored() end
      end
    end
  end
  for _,m in ipairs(self.mobs) do
    if m.steer and valid(m.actor) then m.actor:AddMovementInput(m.steer,1,true) end
    if (m.health or 1)>0 and not m.removed and now>=(m.next_pose or 0)then
      local d=distance(m.position,self.player_position or m.position)
      m.next_pose=now+(d<800^2 and 1/30 or d<2400^2 and .05 or .1)
      if not think then m.position=world.copy(m.actor:K2_GetActorLocation())end
      models.pose(m,now,m.steer~=nil)
    end
  end
  -- Sweep the whole elapsed segment so a low frame rate never tunnels through a wall.
  self:flight(now,math.min(.25,elapsed),self.ignore or {})
  local ms=(os.clock()-began)*1000
  local perf=self.report.performance or {frames=0,total_ms=0,max_ms=0,over_4ms=0}
  perf.frames=perf.frames+1;perf.total_ms=perf.total_ms+ms;perf.max_ms=math.max(perf.max_ms,ms)
  if ms>4 then perf.over_4ms=perf.over_4ms+1 end
  self.report.performance=perf
end
function M:stop_loop()
  if self.loop then CancelDelayedAction(self.loop);self.loop=nil end
  self.last_tick=nil;self.ignore=nil;self.candidates=nil
end
function M:close()
  self:stop_loop()
  if self.sounds then self.sounds:close() end
  for i=#self.shots,1,-1 do remove(self.shots,i) end
  for i=#self.mobs,1,-1 do remove(self.mobs,i) end
  self.by_actor={};if self.binding.mc_summons==self then self.binding.mc_summons=nil end
end
return M
