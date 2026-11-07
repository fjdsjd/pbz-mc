-- Focused first-person sword/bow adapter. Rules and animation share one action
-- instance; projectiles keep their original source after a hotbar/F5 change.
local identity=require('host.pbz.object_identity')
local valid=require('host.pbz.appearance').valid
local slots=require('rules.container_slots')
local profiles=require('content.combat_profiles')
local bundle=require('host.pbz.mesh_bundle')
local M={};M.__index=M
local function vec(v) return {X=v.X,Y=v.Y,Z=v.Z} end
local function add(p,v,t) return {X=p.X+v.X*t,Y=p.Y+v.Y*t,Z=p.Z+v.Z*t} end
local function rotation(v) return {Pitch=math.deg(math.atan(v.Z,math.sqrt(v.X*v.X+v.Y*v.Y))),Yaw=math.deg(math.atan(v.Y,v.X)),Roll=0} end
local function transform() return {Rotation={X=0,Y=0,Z=0,W=1},Translation={X=0,Y=0,Z=0},Scale3D={X=1,Y=1,Z=1}} end
function M.new(binding,pc,epoch,log)
  local self=setmetatable({binding=binding,pc=pc,epoch=epoch,log=log,projectiles={},fired=0,hits=0,
    damage=require('host.pbz.minecraft_damage').new(binding),pointer=require('input.combat_pointer').new(),
    shield=require('host.pbz.minecraft_shield').new(binding,pc)},M)
  local host={handlers={}}
  function host:authorize(source)
    return self.owner.allowed and self.owner.binding:is_current() and self.owner.context
      and source.epoch==self.owner.context.epoch and source.input_epoch==self.owner.context.input_epoch
      and source.equipment_revision==self.owner.context.equipment_revision
  end
  function host:cancel()
    self.owner.shield:cancel()
    self.owner.spear_charge=nil
    local building=require('host.pbz.building_service').get(binding)
    if building then building:cancel() end
  end
  host.owner=self
  for _,name in ipairs({'mine','interact','recall_trident','tool_use','growth','eat_feedback','consume','shield'}) do
    host.handlers[name]=function() return false end
  end
  function host.handlers.melee(_,record) return self:melee(record) end
  function host.handlers.mace(_,record) return require('host.pbz.mace').strike(self,record) end
  function host.handlers.spear_jab(_,record) return self:spear(record,false) end
  function host.handlers.spear_charge(_,record) return self:spear(record,true) end
  function host.handlers.deflect()
    if not self.wind or #self.wind.charges==0 then return false end
    local origin,dir=self:aim()
    return self.wind:melee(origin,dir,0,300)
  end
  function host.handlers.consume(_,record)
    if record.kind=='drink'then return self:potion_service():drink(record)end
    local status=binding.mc_status_service
    return status and status:consume(record) or false
  end
  function host.handlers.eat_feedback(_,record)
    if record.kind=='drink'then return self:potion_service():sound('drink',binding.actor:K2_GetActorLocation())end
    local status=binding.mc_status_service
    if status then status:sound('eat');return true end
    return false
  end
  function host.handlers.mine(_,record)
    local building=require('host.pbz.building_service').get(binding)
    record.chain_mining=self.chain_mining
    return building and building:mine(record,function() return self:aim() end) or false
  end
  function host.handlers.interact()
    local build=require('host.pbz.building_service').get(binding)
    if build and build.commands then
      local hit,handle=build:target(function()return self:aim()end)
      local block=handle and build.session.data.buildings[handle.id]
      if block and require('content.blocks').get(block.content_id).command_block then
        binding.command_block_edit=block.id;return true,'consume'
      end
    end
    if build and build.mechanisms then
      local ok,status=build.mechanisms:interact(function()return self:aim()end)
      if ok then return true,status end
    end
    local boat=require('host.pbz.boat_service').get(binding)
    if boat and boat:interact(function() return self:aim() end) then return true,'consume' end
    return false,'pass'
  end
  function host.handlers.attack_target(_,record)
    local tnt=require('host.pbz.tnt_service').get(binding)
    if tnt and tnt:extinguish(function()return self:aim()end) then return true,'success' end
    local boat=require('host.pbz.boat_service').get(binding)
    if not boat then return false,'pass' end
    local consumed,hit=boat:attack(record,function() return self:aim() end)
    if consumed then return true,hit and 'success' or 'consume' end
    return false,'pass'
  end
  function host.handlers.use(_,record)
    return self:use(record)
  end
  self.actions=require('runtime.minecraft_actions').new(host)
  return self
end
function M:summon_group()
  if not self.summons then self.summons=require('host.pbz.undead_summons').new(self) end
  return self.summons
end
function M:potion_service()
  if not self.potions or self.potions.closed then self.potions=require('host.pbz.potion_service').new(self)end
  return self.potions
end
function M:use(record)
  if record.kind=='potion_throw'then return self:potion_service():throw(record)end
  if record.kind=='summon' then
    return self:summon_group():use(record)
  end
  if record.kind=='bow' then return self:shoot(record) end
  if record.kind=='wind' then
    if not self.wind or self.wind.closed then self.wind=require('host.pbz.wind_charge').new(self) end
    return self.wind:throw(record)
  end
  if record.kind=='pearl' then
    if not self.pearls or self.pearls.closed then self.pearls=require('host.pbz.ender_pearl').new(self) end
    return self.pearls:throw(record)
  end
  local stack=record.equipment[record.hand]
  if record.kind=='equipment' then return require('host.pbz.equipment_use').use(self.binding,record)end
  if stack and stack.content_id=='pbzmc:firework_rocket' then
    local rockets=self.binding.mc_fireworks
    if not rockets or rockets.closed then rockets=require('host.pbz.firework_service').new(self.binding,self.pc,self.log)end
    return rockets:use(record,function()return self:aim()end)
  end
  if stack and stack.content_id=='pbzmc:flint_and_steel' then
    if self.summons and #self.summons.mobs>0 and self.summons:ignite(function()return self:aim()end) then return true,'success' end
    local tnt=require('host.pbz.tnt_service').get(self.binding)
    if tnt then return tnt:ignite(function()return self:aim()end)end
    return false,'fail'
  end
  if stack and stack.content_id=='pbzmc:boat' then
    local boat=require('host.pbz.boat_service').get(self.binding)
    if boat and boat:place(function() return self:aim() end) then return true,'success' end
    return false,'fail'
  end
  local building=require('host.pbz.building_service').get(self.binding)
  if stack and building and building.mechanisms and (require('content.tools').get(stack.content_id) or {}).kind=='axe' then
    local _,h=building:target(function()return self:aim()end)
    local r=h and building.session.data.buildings[h.id]
    local id=r and require('host.pbz.construction_devices').scrape(r.content_id)
    if id and require('content.blocks').get(id)then
      local function change(old)
        local after={};for k,v in pairs(old)do after[k]=v end;after.content_id=id
        return {before=old,after=after}
      end
      local batch={change(r)}
      if require('content.blocks').get(r.content_id).family=='door' then
        local other=building.mechanisms:pair(r);if not other then return false,'fail'end
        batch[#batch+1]=change(other)
      end
      local ok=building.mechanisms:commit(batch)
      return ok,ok and 'success' or 'fail'
    end
  end
  if stack and building and require('content.blocks').get(stack.content_id) then
    if stack.content_id=='pbzmc:tnt' and not require('host.pbz.tnt_damage').ready()then return false,'fail'end
    return building:place(stack.content_id,function()return self:aim()end)
  end
  return false
end
function M:trace(start,finish,radius,ignored,ignore_list)
  local hit,color={},{R=0,G=0,B=0,A=0};local ignore=ignore_list or {self.binding.actor}
  if ignored then ignore[#ignore+1]=ignored end
  local yes=require('UEHelpers').GetKismetSystemLibrary():SphereTraceSingle(self.binding.actor,start,finish,
    radius,0,false,ignore,0,hit,true,color,color,0)
  local actor
  if yes then
    local ok,object=pcall(function() return hit.HitObjectHandle.ReferenceObject:Get() end)
    if ok and valid(object) then
      if object:IsA(StaticFindObject('/Script/Engine.Actor')) then actor=object else actor=object:GetOwner() end
    end
  end
  return yes,hit,actor
end
function M:spear(record,charged)
  return require('host.pbz.spear').strike(self,record,charged)
end
function M:aim()
  local manager=self.pc.PlayerCameraManager
  local direction=require('presentation.native_steve_pose').axes(manager.CameraCachePrivate.POV.Rotation)
  local camera=vec(manager.CameraCachePrivate.POV.Location)
  if identity.matches(manager.ViewTarget.Target,self.binding.actor_id) then
    -- A third-person camera is behind the pawn. Start weapon collision at the
    -- pawn's eye and converge toward its reticle ray; never spend melee reach
    -- on the camera boom, or spawn arrows behind the shooter.
    local pawn=self.binding.actor;local origin=vec(pawn:K2_GetActorLocation())
    origin.Z=origin.Z+pawn.CapsuleComponent:GetScaledCapsuleHalfHeight()*.74
    local finish=add(camera,direction,10000);local yes,hit=self:trace(camera,finish,.1)
    if yes then finish=vec(hit.ImpactPoint) end
    local x,y,z=finish.X-origin.X,finish.Y-origin.Y,finish.Z-origin.Z
    local length=math.sqrt(x*x+y*y+z*z)
    if length>1 and x*direction.X+y*direction.Y+z*direction.Z>0 then direction={X=x/length,Y=y/length,Z=z/length} end
    return origin,direction
  end
  return camera,direction
end
function M:melee(record)
  local start,direction=self:aim()
  local yes,result,target=self:trace(start,add(start,direction,300),18)
  local p=profiles.get(record.equipment.main and record.equipment.main.content_id)
  local pawn=self.binding.actor;local movement=pawn.CharacterMovement;local lease=self.binding.mc_movement_owner
  local camera=require('host.pbz.first_person_camera').get()
  local states=self.binding.mc_status or {}
  local critical=require('rules.jump_critical').allowed({strength=record.strength,fall_distance=self.fall_state and self.fall_state.distance or 0,
    grounded=movement.MovementMode~=3,climbing=camera and camera:traversal(self.binding)~=nil,water=movement.MovementMode==4,
    blind=states.blindness==true,riding=states.riding==true,sprinting=lease and lease.frame and lease.frame.sprint==true,
    living=valid(target) and self.damage:eligible(target)})
  local amount=require('rules.minecraft_combat').melee_damage(p.adventure_attack,record.strength,critical)
  local hit=yes and target and self.damage:hit(target,amount,record.action_id,
    {kind='sword',weapon_id=record.equipment.main and record.equipment.main.content_id,
      direction=direction,location=vec(result.ImpactPoint),normal=vec(result.ImpactNormal)}) or false
  self.last_melee={action_id=record.action_id,strength=record.strength,fall_distance=self.fall_state and self.fall_state.distance or 0,
    movement_mode=movement.MovementMode,sprinting=lease and lease.frame and lease.frame.sprint==true or false,
    critical=critical,hit=hit,requested=amount,target=valid(target) and target:GetFullName() or false}
  if p.kind=='sword' then
    self:sound(not hit and 'sword_miss' or record.strength>.9 and 'sword_strong' or 'sword_weak',start)
  end
  if hit then
    self.hits=self.hits+1;self.damage.report.critical=critical
    if critical then
      self.criticals=(self.criticals or 0)+1
      local ok,why=pcall(function()
        if not self.critical_fx then self.critical_fx=require('host.pbz.critical_particles').new(self.binding,self.pc) end
        self.critical_fx:burst(target)
      end)
      if not ok then self.critical_fx_error=tostring(why);self.log('MC critical particles failed: '..tostring(why)) end
    end
    self.log('MC melee HP delta='..tostring(self.damage.report.observed_delta)
      ..' native-shield delta='..tostring(self.damage.report.native_shield_delta or 0)..' critical='..tostring(critical)
      ..' feedback='..tostring(self.damage.report.feedback)..' flash='..tostring(self.damage.report.flash))
  end
  return hit
end
function M:sound(event,position,power)
  -- Building and weapons share the bounded original-resource audio backend.
  -- Sound failure must never cancel damage or duplicate an already fired arrow.
  local service=require('host.pbz.building_service').get(self.binding)
  if not service or not service.audio then return false end
  local ok,played=pcall(service.audio.combat,service.audio,event,position,self.pc,power)
  if not ok then self.audio_error=tostring(played);return false end
  return played
end
function M:arrow_part()
  if self.part then return self.part end
  local root=self.binding.item_models_root
  local catalog=require('host.pbz.item_models').new(root)
  local path=assert(catalog.manifest.projectiles.arrow,'original-arrow-model-required')
  local record=assert(catalog.records[path],'arrow-manifest-record-required')
  local f=assert(io.open(root..'/'..path,'rb'));local bytes=f:read('a');f:close()
  assert(#bytes==record.bytes and require('storage.sha256')(bytes)==record.sha256,'arrow-model-digest')
  self.part=assert(bundle.decode(bytes,5.625)[1])
  for _,uv in ipairs(self.part.uv) do uv.X=433.5/512;uv.Y=139.5/256 end
  return self.part
end
function M:shoot(record)
  assert(#self.projectiles<64,'arrow-budget-exhausted')
  local origin,direction=self:aim();origin=add(origin,direction,20)
  local pawn=self.binding.actor;local owner=pawn:GetWorld():SpawnActor(StaticFindObject('/Script/Engine.Actor'),origin,rotation(direction))
  assert(valid(owner),'arrow-create-failed')
  local arrow={actor=owner,id=identity.capture(owner),position=origin,age=0,accumulator=0,power=record.power,
    action_id=record.action_id,damage=math.max(.2,record.power*1.8)*profiles.get('pbzmc:bow').adventure_attack}
  local ok,why=pcall(function()
    local mesh=owner:AddComponentByClass(StaticFindObject('/Script/ProceduralMeshComponent.ProceduralMeshComponent'),true,transform(),false)
    assert(valid(mesh),'arrow-mesh-failed');arrow.mesh=mesh;mesh:SetCollisionEnabled(0)
    mesh:SetMaterial(0,self.binding.material);bundle.apply(mesh,self:arrow_part())
    local inherited=self.binding.mc_gliding and self.binding.mc_gliding.velocity or pawn:GetVelocity()
    arrow.velocity={X=direction.X*6000*record.power+inherited.X,Y=direction.Y*6000*record.power+inherited.Y,
      Z=direction.Z*6000*record.power+((self.binding.mc_gliding or pawn.CharacterMovement.MovementMode==3) and inherited.Z or 0)}
    mesh:K2_SetWorldLocationAndRotation(origin,rotation(arrow.velocity),false,{},true)
  end)
  if not ok then owner:K2_DestroyActor();error(why) end
  -- The current production mode is free: vanilla-baseline arrows are unlimited.
  self.projectiles[#self.projectiles+1]=arrow;self.fired=self.fired+1
  self:sound('bow_shoot',origin,record.power)
  self.log('MC bow fired id='..record.action_id..' power='..record.power);return true
end
function M:flight(dt)
  for i=#self.projectiles,1,-1 do
    local arrow=self.projectiles[i]
    arrow.age=arrow.age+dt
    if not valid(arrow.actor) or not identity.matches(arrow.actor,arrow.id) or arrow.age>20 then
      if valid(arrow.actor) and identity.matches(arrow.actor,arrow.id) then arrow.actor:K2_DestroyActor() end
      table.remove(self.projectiles,i)
    elseif not arrow.stuck then
      local remaining=dt
      while remaining>1e-8 do
        local step=math.min(.0125,remaining);remaining=remaining-step
        local finish=add(arrow.position,arrow.velocity,step)
        local hit,result,target=self:trace(arrow.position,finish,3,arrow.actor)
        if self.wind and #self.wind.charges>0 and self.wind:arrow(arrow.position,finish,arrow.velocity,
            self.now-remaining-step,self.now-remaining,hit and result.Time or nil) then
          arrow.actor:K2_DestroyActor();table.remove(self.projectiles,i);arrow.retired=true
          break
        end
        if hit then
          self:sound('arrow_hit',result.ImpactPoint)
          if target and self.damage:hit(target,arrow.damage,arrow.action_id,
            {kind='arrow',weapon_id='pbzmc:bow',direction=arrow.velocity,location=vec(result.ImpactPoint),normal=vec(result.ImpactNormal)}) then self.hits=self.hits+1 end
          -- Character contact consumes the projectile even when damage is
          -- rejected (dead/invulnerable). Terrain retains the stuck arrow.
          if valid(target) and target:IsA(StaticFindObject('/Script/Engine.Character')) then
            arrow.actor:K2_DestroyActor();table.remove(self.projectiles,i);arrow.retired=true
            self.arrows_consumed=(self.arrows_consumed or 0)+1
            break
          end
          arrow.position=vec(result.ImpactPoint);arrow.stuck=true;break
        end
        arrow.position=finish;arrow.accumulator=arrow.accumulator+step
        if arrow.accumulator>=.05-1e-8 then
          arrow.accumulator=arrow.accumulator-.05
          arrow.velocity={X=arrow.velocity.X*.99,Y=arrow.velocity.Y*.99,Z=arrow.velocity.Z*.99-100}
        end
      end
      if not arrow.retired then arrow.mesh:K2_SetWorldLocationAndRotation(arrow.position,rotation(arrow.velocity),false,{},true) end
    end
  end
end
function M:update(batch,data,revision,context,allowed)
  self.allowed=allowed and batch.raw_input_filtered==true
  self.chain_mining=self.allowed and batch.chain_mining_controls==true and batch.latest.focused
    and not batch.overflow and ((batch.latest.keys or 0)&(1<<21))~=0
  -- Building commits advance the shared store but do not change equipment.
  -- Keep held input across those commits; actual selection/stack changes still
  -- retire the source and require release before arming the new item.
  local main=slots.get(data,'player/hotbar/'..data.player.selected)
  local offhand=slots.get(data,'player/offhand')
  local mode=self.binding.mc_creative and 'creative' or 'free'
  local seen=self.equipment_seen
  if not seen or revision==nil or seen.revision~=revision or seen.selected~=data.player.selected
      or seen.main~=main or seen.offhand~=offhand or seen.mode~=mode then
    local signature=require('storage.canonical_json')({selected=data.player.selected,main=main,offhand=offhand,mode=mode})
    if signature~=self.equipment_signature then
      self.equipment_signature=signature;self.equipment_revision=(self.equipment_revision or 0)+1
      self.holding_mace=main and not require('rules.native_slot_reference').is(main) and profiles.get(main.content_id).kind=='mace'
    end
    self.equipment_seen={revision=revision,selected=data.player.selected,main=main,offhand=offhand,mode=mode}
  end
  local c={kind=self.allowed and 'game' or 'inactive',weapon_group='mc',allow_actions=self.allowed,
    epoch=self.epoch,input_epoch=batch.epoch,equipment_revision=self.equipment_revision,mode=mode,has_arrow=true,
    main=main,offhand=offhand,sneaking=((batch.latest.keys or 0)&(1<<19))~=0,
    gliding=self.binding.mc_gliding and self.binding.mc_gliding.active or false}
  local status=self.binding.mc_status_service
  c.item_cooldowns=status and status.value.cooldowns or {}
  self.context=c
  if require('rules.native_slot_reference').is(c.main) then
    if c.gliding and offhand and offhand.content_id=='pbzmc:firework_rocket' then c.main=nil;c.flight_use_only=true
    else c.kind='inactive';self.allowed=false end
  end
  if self.allowed and self.holding_mace then self.binding.mc_mace_owner=self
  elseif self.binding.mc_mace_owner==self then self.binding.mc_mace_owner=nil end
  -- Message timestamps describe queued events and can precede the preceding
  -- drain's snapshot. Cooldowns and charge use the world's monotonic clock.
  local game=StaticFindObject('/Script/Engine.Default__GameplayStatics')
  local now=math.max(self.now or 0,game:GetTimeSeconds(self.binding.actor))
  local elapsed=self.now and math.max(0,now-self.now) or 0
  local dt=math.min(elapsed,.1);self.now=now
  local pawn=self.binding.actor;local position=pawn:K2_GetActorLocation();local velocity=pawn:GetVelocity()
  self.fall_state=require('rules.jump_critical').fall(self.fall_state,position.Z,pawn.CharacterMovement.MovementMode==3,velocity.Z,elapsed)
  local events=self.pointer:update(batch,c)
  local ok,why=self.actions:step(now,c,events);assert(ok,why)
  self.presentation=self.actions:presentation(now,c)
  self.shield:update(self.presentation)
  self:flight(dt)
end
function M:cancel(reason)
  if self.binding.mc_mace_owner==self then self.binding.mc_mace_owner=nil end
  self.allowed=false;self.actions:cancel(reason);self.presentation=nil
end
function M:close()
  self:cancel('owner-retired')
  if self.summons then self.summons:close() end
  self.shield:close()
  self.damage:close()
  if self.critical_fx then self.critical_fx:close() end
  if self.mace_fx then self.mace_fx:close() end
  if self.pearls then self.pearls:close() end
  if self.wind then self.wind:close() end
  if self.potions then self.potions:close() end
  for _,arrow in ipairs(self.projectiles) do if valid(arrow.actor) and identity.matches(arrow.actor,arrow.id) then arrow.actor:K2_DestroyActor() end end
  self.projectiles={}
end
return M
