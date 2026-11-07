-- Command entity ownership. Native handles stay on the game thread and never
-- enter command storage/NBT. Listing is cached per command or world-clock frame;
-- tick visits only actors with active effects, never the world's actor array.
local identity=require('host.pbz.object_identity')
local state=require('storage.state')
local valid=require('host.pbz.appearance').valid
local M={supports_level=false};M.__index=M
local sessions=0
local function uuid()
  return string.format('%08x-%04x-4%03x-%04x-%012x',math.random(0,0x7fffffff)*2+math.random(0,1),
    math.random(0,0xffff),math.random(0,0xfff),math.random(0x8000,0xbfff),math.random(0,0xffffffffffff))
end
local function finite(n)return type(n)=='number'and n==n and math.abs(n)<1e9 end
local function vec(p)return {X=p.X,Y=p.Y,Z=p.Z}end
local function rot(p)return {Pitch=p.Pitch,Yaw=p.Yaw,Roll=p.Roll or 0}end
local function key(id)return tostring(id.address)..'/'..id.name end
local function path(o)return assert(o:GetFullName():match('^[^ ]+ (.+)$'),'command-object-path')end
local function short(id)return type(id)=='string'and id:gsub('^minecraft:',''):gsub('^generic%.','')or id end
local function checked_position(p)
  assert(type(p)=='table'and finite(p.x)and finite(p.y)and finite(p.z),'command-position-invalid')
  return p
end
local function checked_vector(p)
  assert(type(p)=='table'and finite(p[1])and finite(p[2])and finite(p[3])and #p==3,'command-vector-invalid')
  return p
end
local function health(actor)
  local ok,h,m=pcall(function()return actor.AttributeSetBase.Health.CurrentValue,actor.AttributeSetBase.Health_Max.CurrentValue end)
  if ok and finite(h)and finite(m)and m>0 then return h,m end
end
local function protected(fn,self,...)
  local ok,a,b=pcall(fn,self,...)
  if not ok then return false,tostring(a)end
  return a,b
end
local function result(fn,self,...)
  local ok,a,b=pcall(fn,self,...)
  if not ok then return nil,tostring(a)end
  return a,b
end
local function component(actor,class)
  local list=actor:K2_GetComponentsByClass(StaticFindObject(class))
  local value=#list==1 and list[1]:get()or nil
  assert(valid(value)and identity.matches(value:GetOwner(),identity.capture(actor)),'command-component-unavailable:'..class)
  return value
end
local function tags(value)
  assert(type(value)=='table'and #value<=1024,'command-tags-invalid')
  local out={}
  for k,v in pairs(value)do
    assert(type(k)=='number'and k%1==0 and k>=1 and k<=#value and type(v)=='string'and #v>0 and #v<=256,'command-tag-invalid')
    out[v]=true
  end
  return out
end
local function tag_list(map)
  local out=setmetatable({},{__jsontype='array'});for tag,yes in pairs(map or {})do if yes then out[#out+1]=tag end end;table.sort(out);return out
end
local function equal(a,b)
  if type(a)~=type(b)then return false end
  if type(a)~='table'then return a==b end
  for k,v in pairs(a)do if not equal(v,b[k])then return false end end
  for k in pairs(b)do if a[k]==nil then return false end end
  return true
end
function M.new(binding,options)
  options=options or {};assert(binding and binding:is_current(),'command-entity-binding-required')
  assert(type(options.origin)=='function','command-grid-origin-required')
  sessions=sessions+1
  return setmetatable({binding=binding,options=options,session=sessions,serial=0,rows={},by_id={},effects={},
    native_types={},log=options.log or function()end,clock=StaticFindObject('/Script/Engine.Default__GameplayStatics')},M)
end
function M:current()
  return not self.closed and self.binding:is_current()
end
function M:_time()return self.clock:GetTimeSeconds(self.binding.actor)end
function M:invalidate()self.cache=nil;self.cache_stamp=nil end
function M:begin_command(token)
  -- Multiple command blocks in one world frame share native enumeration.
  -- Mutations invalidate the snapshot; advancing world time expires it.
  self.command_token=token
end
function M:_origin()
  local p=self.options.origin();assert(p and finite(p.x)and finite(p.y)and finite(p.z),'command-grid-origin-unavailable');return p
end
function M:_mc(p,half)
  local o=self:_origin();return {x=.5+(p.X-o.x)/100,y=.5+(p.Z-o.z-(half or 0))/100,z=.5-(p.Y-o.y)/100}
end
function M:_ue(p,half)
  checked_position(p);local o=self:_origin()
  local v={X=o.x+(p.x-.5)*100,Y=o.y-(p.z-.5)*100,Z=o.z+(p.y-.5)*100+(half or 0)}
  assert(finite(v.X)and finite(v.Y)and finite(v.Z),'command-native-position-range');return v
end
function M:_group(create)
  if not self.summons and create and self.options.summons then self.summons=self.options.summons()end
  return self.summons
end
function M:_boats()
  local module=package.loaded['host.pbz.boat_service'];return module and module.get(self.binding)or nil
end
function M:_tags(h)
  return self.options.get_tags and self.options.get_tags(h.id)or h.tags
end
function M:_set_tags(h,value)
  if self.options.set_tags then
    local ok,why=self.options.set_tags(h.id,state.clone(value));assert(ok,why or 'command-tag-transaction-failed')
  end
  h.tags=value
end
function M:_admit(actor,kind,mob,owner)
  assert(valid(actor)and identity.matches(actor:GetWorld(),self.binding.world_id),'command-entity-world')
  local id=identity.capture(actor);local k=key(id);local h=self.rows[k]
  if not h then
    self.serial=self.serial+1
    h={owner=self,actor=actor,identity=id,world_id=self.binding.world_id,kind=kind,mob=mob,service=owner,
      id=kind=='player'and self.options.player_id or uuid(),tags={}}
    self.rows[k]=h;self.by_id[h.id]=h
  end
  if kind=='mc' then
    h.type='minecraft:'..mob.def.name;h.name=mob.def.name;h.mob=mob;h.service=owner
  elseif kind=='boat' then h.type='minecraft:oak_boat';h.name='oak_boat';h.boat=mob;h.service=owner
  elseif kind=='player' then h.type='minecraft:player';h.name='Steve';h.player=true
  else
    local class=actor:GetClass();local class_path=path(class)
    local name=class:GetFName():ToString():lower():gsub('_c$','')
    assert(name:match('^[a-z0-9_]+$'),'command-native-type-name')
    h.type='pbz:'..name;h.name=name;h.class_path=class_path
    local previous=self.native_types[h.type]
    if previous==false or previous and previous~=class_path then self.native_types[h.type]=false else self.native_types[h.type]=class_path end
  end
  return h
end
function M:_resolve(e)
  assert(type(IsInGameThread)=='function'and IsInGameThread(),'command-entity-game-thread-required')
  assert(self:current(),'command-entity-owner-stale')
  local h=type(e)=='table'and e.handle or type(e)=='string'and self.by_id[e]
  assert(h and h.owner==self and self.by_id[h.id]==h and identity.matches(h.actor,h.identity)
    and identity.matches(h.actor:GetWorld(),self.binding.world_id),'command-entity-stale')
  if h.kind=='mc'then assert(h.service:contains(h.mob),'command-summon-retired')end
  if h.kind=='boat'then assert(h.service.boats[h.boat.handle.id]==h.boat and not h.boat.retired,'command-boat-retired')end
  return h
end
function M:_dimensions(h)
  if h.kind=='boat'then return 0,68.75,56.25 end
  local cap=h.actor.CapsuleComponent;assert(valid(cap),'command-entity-capsule-required')
  local half,radius=cap:GetScaledCapsuleHalfHeight(),cap:GetScaledCapsuleRadius()
  assert(finite(half)and half>0 and finite(radius)and radius>0,'command-entity-size-invalid')
  return half,radius,half*2
end
function M:_descriptor(h)
  local half,radius,height=self:_dimensions(h)
  local p,r=h.actor:K2_GetActorLocation(),h.actor:K2_GetActorRotation()
  if h.player and valid(h.actor.Controller)then r=h.actor.Controller.ControlRotation end
  local hp,max
  if h.kind=='mc'then hp,max=h.mob.health or 20,h.mob.max_health or 20
  elseif h.kind~='boat'then hp,max=health(h.actor)end
  return {id=h.id,type=h.type,name=h.custom_name or h.name,player=h.player==true,
    gamemode=h.player and (self.binding.mc_creative and 'creative' or 'survival')or nil,
    alive=h.kind=='boat'and not h.boat.state.destroyed or hp~=nil and hp>0,
    pos=self:_mc(p,half),yaw=(-r.Yaw+90)%360-180,pitch=-r.Pitch,radius=radius/100,height=height/100,
    tags=self:_tags(h),data={Health=hp,MaxHealth=max},handle=h}
end
function M:list()
  assert(type(IsInGameThread)=='function'and IsInGameThread(),'command-entity-game-thread-required')
  assert(self:current(),'command-entity-owner-stale')
  local stamp=self:_time();if self.cache and self.cache_stamp==stamp then return self.cache end
  local out,seen={},{}
  local function add(actor,kind,mob,owner)
    local ok,e=pcall(function()
      if not valid(actor)or not identity.matches(actor:GetWorld(),self.binding.world_id)then return end
      local k=key(identity.capture(actor));if seen[k]then return end
      local row=self:_descriptor(self:_admit(actor,kind,mob,owner));seen[k]=true;return row
    end)
    if ok and e then out[#out+1]=e end
  end
  add(self.binding.actor,'player')
  -- The callback is a lazy acquisition, not a world scan. Existing spawn-egg
  -- creatures must be visible even before the first /summon command.
  local group=self:_group(true)
  if group then for _,m in ipairs(group.mobs)do add(m.actor,'mc',m,group)end end
  local class=StaticFindObject('/Script/ProjectPBZ.PBZCharacter')
  for _,raw in ipairs(FindAllOf('PBZCharacter')or {})do
    local actor=raw.GetFullName and raw or raw:get()
    if valid(actor)and actor:IsA(class)then add(actor,'native')end
  end
  local boats=self:_boats()
  if boats then for _,boat in pairs(boats.boats)do if not boat.retired then add(boat.handle.actor,'boat',boat,boats)end end end
  for k,h in pairs(self.rows)do
    if not identity.matches(h.actor,h.identity)or not identity.matches(h.actor:GetWorld(),self.binding.world_id)then
      self.rows[k]=nil;self.by_id[h.id]=nil;self.effects[h.id]=nil
    end
  end
  self.cache=out;self.cache_stamp=stamp;return out
end
function M:player()
  assert(self:current(),'command-player-stale');return self:_descriptor(self:_admit(self.binding.actor,'player'))
end
function M:_release_seat(h,reason)
  local boats=self:_boats();if not boats then return end
  local boat,rider=boats:spear_seat(h.actor)
  if boat then local ok,why=boats:release(boat,rider,reason,false);assert(ok,why)end
end
function M:_teleport(e,pos,yaw,pitch)
  local h=self:_resolve(e);checked_position(pos)
  assert(yaw==nil or finite(yaw),'command-yaw-invalid');assert(pitch==nil or finite(pitch)and pitch>=-90 and pitch<=90,'command-pitch-invalid')
  local half=self:_dimensions(h);local target=self:_ue(pos,half)
  local old=vec(h.actor:K2_GetActorLocation());local before=rot(h.actor:K2_GetActorRotation())
  local control=h.player and valid(h.actor.Controller)and rot(h.actor.Controller.ControlRotation)or before
  local r={Pitch=pitch~=nil and -pitch or control.Pitch,Yaw=yaw~=nil and -yaw-90 or control.Yaw,Roll=0}
  if h.kind=='boat'then
    assert(r.Pitch==0,'command-boat-pitch-unsupported')
    local boat,service=h.boat,h.service;assert(not boat.dormant_reason,'command-boat-dormant')
    local pose={x=target.X,y=target.Y,z=target.Z,yaw=r.Yaw}
    assert(service.world:fits(pose,boat.handle),'command-boat-destination-occupied')
    local riders={};for id in pairs(boat.leases)do riders[#riders+1]=id end
    for _,id in ipairs(riders)do local ok,why=service:release(boat,id,'command-teleport',false);assert(ok,why)end
    local actual=service.world:external_push_apply(boat.handle,pose)
    boat.state.x,boat.state.y,boat.state.z,boat.state.yaw=actual.x,actual.y,actual.z,actual.yaw
    local record=assert(service.records[boat.handle.id]);record.x,record.y,record.z,record.yaw=actual.x,actual.y,actual.z,actual.yaw
    boat.resting=false;boat.surface=nil;boat.ground_surface=nil;boat.next_sim_at=0;boat.support_at=0;boat.pin_at=0;service.dirty=true
  else
    local moved,why=pcall(function()
      local body={Pitch=h.player and before.Pitch or r.Pitch,Yaw=r.Yaw,Roll=0}
      assert(h.actor:K2_SetActorLocationAndRotation(target,body,false,{},true)==true,'command-teleport-rejected')
      local after=h.actor:K2_GetActorLocation()
      assert(math.abs(after.X-target.X)+math.abs(after.Y-target.Y)+math.abs(after.Z-target.Z)<.1,'command-teleport-readback')
      self:_release_seat(h,'command-teleport')
    end)
    if not moved then
      if identity.matches(h.actor,h.identity)then pcall(h.actor.K2_SetActorLocationAndRotation,h.actor,old,before,false,{},true)end
      error(why)
    end
    if h.kind=='mc'then h.service:command_move(h.mob,target,r.Yaw)
    else
      local movement=h.actor.CharacterMovement;movement:StopMovementImmediately()
      if h.player then
        if valid(h.actor.Controller)then h.actor.Controller:SetControlRotation(r)end
        if self.binding.mc_gliding then self.binding.mc_gliding:close()end
        require('host.pbz.item_interface').reset_fall_after_teleport(self.binding)
      end
    end
  end
  self:invalidate();return true,self:_descriptor(h)
end
function M:teleport(...)return protected(self._teleport,self,...)end
function M:_mount(e,vehicle)
  local h,v=self:_resolve(e),self:_resolve(vehicle)
  assert(v.kind=='boat'and (h.player or h.kind=='native'),'command-ride-target-unsupported')
  local ok,why=v.service:capture(v.boat,h.actor,h.player and 'player'or 'mob',self:_time());assert(ok,why)
  self:invalidate();return true,{vehicle=v.id,passenger=h.id}
end
function M:mount(...)return protected(self._mount,self,...)end
function M:_dismount(e)
  local h=self:_resolve(e);local boats=self:_boats();assert(boats,'command-not-riding')
  local boat,rider=boats:spear_seat(h.actor);assert(boat,'command-not-riding')
  local ok,why=boats:release(boat,rider,'command-dismount',true);assert(ok,why)
  self:invalidate();return true,{passenger=h.id}
end
function M:dismount(...)return protected(self._dismount,self,...)end
function M:_health_attribute()
  if self.health_attribute then return self.health_attribute end
  local status=self.binding.mc_status_service
  if status and status.attribute then self.health_attribute=status.attribute;return self.health_attribute end
  local effect=StaticFindObject('/PBZCombatAsset/Config/AttributesModifyEffect/GE_MA_Health_1_Add.GE_MA_Health_1_Add')
  assert(valid(effect),'command-health-attribute-unavailable')
  effect.Modifiers:ForEach(function(_,wrapped)local a=wrapped:get().Attribute
    if a.AttributeName:ToString()=='Health'then self.health_attribute=a;return true end end)
  assert(self.health_attribute,'command-health-attribute-unavailable');self.health_asset=effect;return self.health_attribute
end
function M:_health_delta(h,delta)
  assert(finite(delta),'command-health-delta-invalid')
  if delta==0 then return end
  StaticFindObject('/Script/SGameAttributes.Default__AttributeUtils'):ModifyCharacterAttributeValue(h.actor,self:_health_attribute(),0,delta)
end
function M:_kill(e)
  local h=self:_resolve(e)
  if h.kind=='mc'then local ok,why=h.service:remove_mob(h.mob,'command-kill');assert(ok,why)
  elseif h.kind=='boat'then local ok,why=h.service:remove(h.boat,'command-kill');assert(ok,why)
  else
    local death=h.actor['Death Component'];assert(valid(death),'command-native-death-component-unavailable')
    local component=death['Actor State Component'];local tag=death['Dead State Tag']
    assert(valid(component)and identity.matches(component:GetOwner(),h.identity)
      and tag.TagName:ToString()=='CharacterState.Dead','command-native-death-state-unavailable')
    if component:InExactState(tag)then return false,'command-entity-already-dead'end
    self:_release_seat(h,'command-kill')
    -- /kill is an explicit administrative death, including creative players.
    -- Override only synchronous callbacks for this bound player request, then
    -- restore only callbacks still owned by this scope (respawn may rebind them).
    local saved,temporary={},{}
    if h.player then
      temporary.PBZMC_DeathDecision=function()return false end
      temporary.PBZMC_HealthDecision=function(delta)return delta end
      temporary.PBZMC_LethalHealthDecision=function(delta)return delta end
      for name,fn in pairs(temporary)do saved[name]=_G[name];_G[name]=fn end
    end
    local ok,why=pcall(function()if not component:InPendingState(tag)then component:AddPendingState(tag)end end)
    for name,fn in pairs(temporary)do if _G[name]==fn then _G[name]=saved[name]end end
    self:invalidate();assert(ok,why)
    assert(identity.matches(h.actor,h.identity),'command-native-death-requested-actor-retired-unconfirmed')
    assert(component:InExactState(tag),'command-native-death-request-pending-or-rejected')
  end
  local effects=self.effects[h.id]
  if effects then self:_retire_effect(effects)end
  self.effects[h.id]=nil;self:invalidate();return true,{id=h.id,killed=true}
end
function M:kill(...)return protected(self._kill,self,...)end
local damage_kinds={generic='explosion',explosion='explosion',player_explosion='explosion',player_attack='sword',mob_attack='sword',
  arrow='arrow',in_fire='fire',on_fire='fire',lava='fire',fall='fall',fly_into_wall='fly_into_wall'}
function M:_damage(e,amount,kind,source)
  local h=self:_resolve(e);kind=short(kind or 'generic')
  assert(finite(amount)and amount>0,'command-damage-amount-invalid')
  assert(damage_kinds[kind],'command-damage-type-unsupported:'..tostring(kind))
  if h.kind=='boat'then
    local dead=require('rules.boat').hit(h.boat.state,amount)
    if dead then local ok,why=h.service:remove(h.boat,'command-damage');assert(ok,why)end
    self:invalidate();return true,{requested=amount,killed=dead}
  end
  if h.kind=='mc'then
    local m=h.mob;assert(not m.invulnerable,'command-entity-invulnerable')
    local accepted,result=require('host.pbz.mob_living').hit(self.binding,h.actor,amount,nil,{command=true,knockback=false,kind=damage_kinds[kind]})
    self:invalidate();return accepted,result
  end
  assert(h.actor.bCanBeDamaged,'command-entity-invulnerable')
  local attacker=source and self:_resolve(source)or self:_admit(self.binding.actor,'player')
  assert(attacker.kind=='native'or attacker.player,'command-native-damage-source-unsupported')
  local native_kind=damage_kinds[kind]
  if attacker.actor==h.actor then
    assert(native_kind=='explosion'or native_kind=='fire'or native_kind=='fall'or native_kind=='fly_into_wall','command-self-damage-type-unsupported')
  end
  local attack=attacker.actor.AttributeSetBase.Attack.CurrentValue
  assert(finite(attack)and attack>0 and amount/attack<=1000,'command-native-damage-coefficient-limit')
  local before=assert(health(h.actor),'command-native-health-unavailable');assert(before>0,'command-entity-dead')
  local player_status=h.player and self.binding.mc_status_service
  local prior_status=player_status and player_status.report.last_damage
  local effects=self.effects[h.id];local prior_effect=effects and effects.last_native_damage
  local damage=component(h.actor,'/Script/SGameAttributes.AttributeComponent')
  local origin=StaticConstructObject(StaticFindObject('/Script/SGameCombatSystem.DamageSource_GameplayEffect'),attacker.actor)
  assert(valid(origin)and type(PBZMC_NativeHit)=='function','command-native-damage-unavailable')
  local p=h.actor:K2_GetActorLocation();local a=attacker.actor:K2_GetActorLocation()
  local dx,dy,dz=p.X-a.X,p.Y-a.Y,p.Z-a.Z;local n=math.sqrt(dx*dx+dy*dy+dz*dz)
  local direction=n>.001 and {X=dx/n,Y=dy/n,Z=dz/n}or {X=0,Y=0,Z=1}
  local request={phase='damage',kind=native_kind,pawn=path(attacker.actor),target=path(h.actor),source=path(origin),
    component=path(damage),coefficient=amount/attack,location=vec(p),direction=direction,
    normal={X=-direction.X,Y=-direction.Y,Z=-direction.Z}}
  local shield_ok,shield=pcall(function()return h.actor.AttributeSetBase.Shield.CurrentValue end)
  local json=require('dkjson');local raw,why=PBZMC_NativeHit(json.encode(request));assert(raw,why)
  local receipt=assert(json.decode(raw));local after=identity.matches(h.actor,h.identity)and health(h.actor)or nil
  local shield_after_ok,shield_after=pcall(function()return h.actor.AttributeSetBase.Shield.CurrentValue end)
  receipt.before=before;receipt.after=after;receipt.requested=amount;receipt.units='native-health';receipt.health_delta=after and before-after
  if shield_ok and shield_after_ok and finite(shield)and finite(shield_after)then receipt.shield_delta=shield-shield_after end
  if player_status and player_status.report.last_damage~=prior_status then
    local status=player_status.report.last_damage
    receipt.absorbed=status and status.absorbed;receipt.totem=status and status.totem
  end
  if effects and effects.last_native_damage~=prior_effect then
    receipt.effect_mitigated=effects.last_native_damage.mitigated
  end
  self:invalidate()
  if receipt.blocked then return false,'command-native-damage-blocked'end
  if not receipt.dispatched then return false,'command-native-damage-not-dispatched'end
  if after and after>=before and (receipt.shield_delta or 0)<=0 and (receipt.absorbed or 0)<=0 and (receipt.effect_mitigated or 0)<=0 and not receipt.totem then
    return false,'command-native-damage-dispatched-without-health-or-shield-change'
  end
  return true,receipt
end
function M:damage(...)return protected(self._damage,self,...)end
function M:_spawn(id,pos,nbt)
  checked_position(pos);nbt=nbt or {};assert(type(id)=='string','command-entity-type-invalid')
  local name=id:match('^minecraft:(.+)$')or not id:find(':',1,true)and id
  local group,def
  if name then
    def=require('content.summon_mobs').egg('pbzmc:'..name..'_spawn_egg');assert(def,'command-minecraft-entity-type-unsupported:'..id)
    group=assert(self:_group(true),'command-summon-owner-unavailable')
  end
  if not name and not (self.options.native_types or {})[id]and not self.native_types[id]then self:list()end
  local class_path=not name and ((self.options.native_types or {})[id]or self.native_types[id])
  assert(name or type(class_path)=='string','command-native-type-not-loaded-or-registered:'..id)
  if not name then
    local count=0;for _,h in pairs(self.rows)do if h.spawned and identity.matches(h.actor,h.identity)then count=count+1 end end
    assert(count<128,'command-native-spawn-limit')
  end
  -- Validate all NBT before any actor is created.
  self:_validate_patch({kind=name and 'mc'or 'native'},nbt,true)
  local h
  if def then
    local ok,why,m=group:spawn(def,self:_ue(pos,def.height/2),{exact=true,command=true});assert(ok,why)
    assert(m,'command-summon-receipt-required');h=self:_admit(m.actor,'mc',m,group)
  else
    local class=StaticFindObject(class_path);if not valid(class)then class=LoadAsset(class_path)end
    assert(valid(class)and class:GetFullName()=='BlueprintGeneratedClass '..class_path,'command-native-class-unavailable')
    local actor=self.binding.actor:GetWorld():SpawnActor(class,self:_ue(pos,100),{Pitch=0,Yaw=0,Roll=0})
    assert(valid(actor),'command-native-spawn-rejected')
    local ok,why=pcall(function()
      assert(actor:IsA(StaticFindObject('/Script/ProjectPBZ.PBZCharacter'))and (health(actor)or 0)>0,'command-native-spawn-not-living')
      h=self:_admit(actor,'native');h.spawned=true
      local half=self:_dimensions(h);assert(actor:K2_SetActorLocation(self:_ue(pos,half),false,{},true),'command-native-spawn-placement')
    end)
    if not ok then actor:K2_DestroyActor();error(why)end
  end
  local e=self:_descriptor(h);local ok,why=self:write_data(e,nbt)
  if not ok then
    if h.kind=='mc'then group:remove_mob(h.mob,'command-spawn-rollback')elseif identity.matches(h.actor,h.identity)then h.actor:K2_DestroyActor()end
    error(why)
  end
  self:invalidate();return self:_descriptor(h)
end
function M:summon(...)return result(self._spawn,self,...)end

-- Potions, mob attacks and commands share one status owner.
require('host.pbz.entity_effects').install(M)
function M:effect(...)return protected(self._effect,self,...)end
function M:clear_effect(...)return protected(self._clear_effect,self,...)end
local attributes={max_health=true,movement_speed=true,attack_damage=true}
function M:_attribute(e,id,op,value)
  local h=self:_resolve(e);id=short(id);op=(op or 'get'):gsub(' ','_')
  assert(attributes[id]and h.kind~='boat','command-attribute-unsupported:'..tostring(id))
  assert(op=='get'or op=='base_get'or op=='set'or op=='base_set','command-attribute-operation-unsupported')
  local reading=op=='get'or op=='base_get';local current
  if id=='movement_speed'then current=h.actor.CharacterMovement.MaxWalkSpeed/100
  elseif h.kind=='mc'then current=id=='max_health'and h.mob.max_health or h.mob.attack_damage or h.mob.def.damage
  else local hp,max=health(h.actor);current=id=='max_health'and max or h.actor.AttributeSetBase.Attack.CurrentValue end
  assert(finite(current),'command-attribute-unavailable')
  if op=='base_get'then
    local s=self.effects[h.id]
    if id=='movement_speed'and s and s.leases.MaxWalkSpeed then current=s.leases.MaxWalkSpeed.base/100 end
    if id=='attack_damage'and s and s.base_damage then current=s.base_damage end
  end
  if reading then return current end
  assert(finite(value)and value>=0 and value<=100000,'command-attribute-value-invalid')
  assert(h.kind=='mc'or id=='movement_speed'and not h.player,'command-native-attribute-write-unsupported')
  if id=='max_health'then assert(value>0,'command-max-health-positive');h.mob.max_health=value;h.mob.health=math.min(h.mob.health,value)
  elseif id=='movement_speed'then
    local s=self.effects[h.id];if s then self:_restore(s,'MaxWalkSpeed');self:_restore(s,'MaxFlySpeed')end
    h.actor.CharacterMovement.MaxWalkSpeed=value*100;h.actor.CharacterMovement.MaxFlySpeed=value*100
    if s then self:_modifiers(s)end
  else
    local s=self.effects[h.id];if s and s.base_damage~=nil then s.base_damage=value else h.mob.attack_damage=value end
    if s then self:_modifiers(s)end
  end
  self:invalidate();return true,{attribute=id,value=value}
end
function M:attribute(...)return result(self._attribute,self,...)end
function M:_read_data(e)
  local h=self:_resolve(e);local d=self:_descriptor(h);local v=h.actor:GetVelocity()
  local out={id=d.type,UUID=d.id,Health=d.data.Health,MaxHealth=d.data.MaxHealth,Pos={d.pos.x,d.pos.y,d.pos.z},
    Rotation={d.yaw,d.pitch},Motion={v.X/2000,v.Z/2000,-v.Y/2000},Tags=tag_list(self:_tags(h)),CustomName=h.custom_name}
  if h.kind=='mc'then out.NoAI=h.mob.no_ai==true;out.NoGravity=h.mob.no_gravity==true;out.Invulnerable=h.mob.invulnerable==true end
  return out
end
function M:read_data(...)return result(self._read_data,self,...)end
local writable={Health=true,Pos=true,Rotation=true,Motion=true,Tags=true,CustomName=true,NoAI=true,NoGravity=true,Invulnerable=true}
function M:_validate_patch(h,patch,spawning)
  assert(type(patch)=='table','command-entity-data-object-required')
  assert(not h.player or next(patch)==nil,'command-player-data-write-forbidden')
  for field,value in pairs(patch)do
    assert(writable[field],'command-entity-data-field-unsupported:'..tostring(field))
    if field=='Health'then assert(finite(value)and value>0,'command-data-health-positive-use-kill-for-death')
    elseif field=='Pos'or field=='Motion'then checked_vector(value)
    elseif field=='Rotation'then assert(type(value)=='table'and #value==2 and finite(value[1])and finite(value[2])and math.abs(value[2])<=90,'command-data-rotation-invalid')
    elseif field=='Tags'then tags(value)
    elseif field=='CustomName'then assert(type(value)=='string'and #value<=256,'command-data-name-invalid')
    else assert(h.kind=='mc','command-native-data-field-unsupported:'..field);assert(type(value)=='boolean'or value==0 or value==1,'command-data-boolean-required')end
  end
  if h.kind=='boat'then for field in pairs(patch)do assert(field=='Tags'or field=='CustomName','command-boat-data-field-unsupported')end end
  return true
end
function M:_write_data(e,patch,options)
  local h=self:_resolve(e)
  local prior=self:_read_data(e)
  if options and options.replace then
    assert(type(patch)=='table','command-entity-data-object-required')
    local candidate={}
    for field,value in pairs(patch)do
      if field=='id'or field=='UUID'or field=='MaxHealth'then
        assert(value==prior[field],'command-entity-data-read-only:'..field)
      else candidate[field]=value end
    end
    for _,field in ipairs({'id','UUID','MaxHealth','Health','Pos','Rotation','Motion'})do
      assert(prior[field]==nil or patch[field]~=nil,'command-entity-data-required:'..field)
    end
    candidate.Tags=candidate.Tags or {};candidate.CustomName=candidate.CustomName or ''
    if h.kind=='mc'then
      for _,field in ipairs({'NoAI','NoGravity','Invulnerable'})do if candidate[field]==nil then candidate[field]=false end end
    end
    patch=candidate
  end
  local changed={};for field,value in pairs(patch)do if not equal(value,prior[field])then changed[field]=value end end;patch=changed
  self:_validate_patch(h,patch)
  if not next(patch)then return true,{unchanged=true}end
  local maximum=h.kind=='mc'and h.mob.max_health or select(2,health(h.actor))
  if patch.Health then assert(maximum and patch.Health<=maximum,'command-data-health-exceeds-maximum')end
  if patch.NoGravity~=nil then assert(finite(h.actor.CharacterMovement.GravityScale),'command-gravity-field-unavailable')end
  if patch.Motion then assert(h.kind=='mc'or valid(h.actor.CharacterMovement),'command-motion-unsupported')end
  if patch.Health and h.kind~='mc'then self:_health_attribute()end
  local boats=self:_boats();local seated=boats and boats:spear_seat(h.actor)
  if seated and (patch.Pos or patch.Rotation)then
    for field in pairs(patch)do assert(field=='Pos'or field=='Rotation','command-data-riding-compound-unsupported')end
  end
  local old_tags,old_name=state.clone(self:_tags(h)),h.custom_name;local m=h.kind=='mc'and h.mob
  local old_mob=m and {home=m.command_home,path=m.path,target=m.target,steer=m.steer,no_ai=m.no_ai,
    no_gravity=m.no_gravity,invulnerable=m.invulnerable,gravity=m.move.GravityScale,base_gravity=m.base_gravity}
  local moved,motion,health_write=false,false,false
  local ok,why=pcall(function()
    if patch.Pos or patch.Rotation then
      local p=patch.Pos or prior.Pos;local r=patch.Rotation or prior.Rotation
      local accepted,reason=self:_teleport(e,{x=p[1],y=p[2],z=p[3]},r[1],r[2]);assert(accepted,reason);moved=true
    end
    if patch.Motion then
      motion=true;local v=patch.Motion;h.actor.CharacterMovement:StopMovementImmediately()
      h.actor:LaunchCharacter({X=v[1]*2000,Y=-v[3]*2000,Z=v[2]*2000},true,true)
    end
    if patch.Tags then self:_set_tags(h,tags(patch.Tags))end
    if patch.CustomName then h.custom_name=patch.CustomName~=''and patch.CustomName or nil end
    if m then
      if patch.NoAI~=nil then m.no_ai=patch.NoAI==true or patch.NoAI==1;if m.no_ai then m.steer=nil;m.path=nil;m.target=nil;m.move:StopMovementImmediately()end end
      if patch.Invulnerable~=nil then m.invulnerable=patch.Invulnerable==true or patch.Invulnerable==1 end
      if patch.NoGravity~=nil then
        if m.base_gravity==nil then m.base_gravity=m.move.GravityScale end
        m.no_gravity=patch.NoGravity==true or patch.NoGravity==1;m.move.GravityScale=m.no_gravity and 0 or m.base_gravity
      end
      if patch.Health then m.health=patch.Health end
    elseif patch.Health then
      health_write=true;self:_health_delta(h,patch.Health-prior.Health)
      local hp=health(h.actor);assert(hp and math.abs(hp-patch.Health)<.01,'command-data-health-rejected')
    end
  end)
  if not ok then
    local restored,restore_error=pcall(function()
      self:_resolve(e);if patch.Tags then self:_set_tags(h,old_tags)end;h.custom_name=old_name
      if moved then local p,r=prior.Pos,prior.Rotation;assert(self:_teleport(e,{x=p[1],y=p[2],z=p[3]},r[1],r[2]))end
      if motion or moved then local v=prior.Motion;h.actor.CharacterMovement:StopMovementImmediately();h.actor:LaunchCharacter({X=v[1]*2000,Y=-v[3]*2000,Z=v[2]*2000},true,true)end
      if m then
        m.command_home=old_mob.home;m.path=old_mob.path;m.target=old_mob.target;m.steer=old_mob.steer
        m.no_ai=old_mob.no_ai;m.no_gravity=old_mob.no_gravity;m.invulnerable=old_mob.invulnerable
        m.move.GravityScale=old_mob.gravity;m.base_gravity=old_mob.base_gravity;m.health=prior.Health
      elseif health_write then local hp=health(h.actor);assert(hp and hp>0,'command-health-rollback-target-dead');self:_health_delta(h,prior.Health-hp)end
    end)
    self:invalidate();error(tostring(why)..(restored and ''or '; rollback: '..tostring(restore_error)))
  end
  self:invalidate();return true,self:_read_data(e)
end
function M:write_data(...)return protected(self._write_data,self,...)end
function M:close()
  if self.effect_timer then CancelDelayedAction(self.effect_timer);self.effect_timer=nil end
  if self.closed then return end
  for _,s in pairs(self.effects)do
    self:_retire_effect(s)
  end
  if self.effect_fx then self.effect_fx:release(self)end
  if PBZMC_EntityHealthDecision==self.entity_health_callback then PBZMC_EntityHealthDecision=nil end
  self.effects={};self.rows={};self.by_id={};self:invalidate();self.closed=true
end
return M
