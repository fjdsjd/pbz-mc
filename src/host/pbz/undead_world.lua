-- Physics, sight and targeting use the bound PBZ world. Summons have a plain
-- Character capsule; no hostile PBZ behaviour tree or daylight effect runs.
local valid=require('host.pbz.appearance').valid
local ids=require('host.pbz.object_identity')
local UE=require('UEHelpers')
local M={};M.__index=M
local function vec(x,y,z) return {X=x,Y=y,Z=z} end
function M.copy(p) return vec(p.X,p.Y,p.Z) end
function M.offset(p,d,t) return vec(p.X+d.X*t,p.Y+d.Y*t,p.Z+d.Z*t) end
function M.delta(a,b) return vec(a.X-b.X,a.Y-b.Y,a.Z-b.Z) end
function M.length(p) return math.sqrt(p.X*p.X+p.Y*p.Y+p.Z*p.Z) end
function M.direction(a,b)
  local d=M.delta(b,a);local length=M.length(d)
  if length<.001 then return vec(1,0,0),0 end
  return vec(d.X/length,d.Y/length,d.Z/length),length
end
function M.rotation(d)
  return {Yaw=math.deg(math.atan(d.Y,d.X)),Pitch=math.deg(math.atan(d.Z,math.sqrt(d.X*d.X+d.Y*d.Y))),Roll=0}
end
function M.new(combat)
  return setmetatable({combat=combat,binding=combat.binding,pawn=combat.binding.actor,
    char=StaticFindObject('/Script/Engine.Character'),hostile_class=StaticFindObject('/Script/ProjectPBZ.PBZCharacter'),
    models=require('host.pbz.undead_models').new(combat.binding)},M)
end
function M:ground(p,ignore,up,down)
  local a,b=vec(p.X,p.Y,p.Z+up),vec(p.X,p.Y,p.Z-down)
  local yes,hit=self.combat:trace(a,b,1,nil,ignore)
  if yes and hit.ImpactNormal.Z>=.45 then return M.copy(hit.ImpactPoint) end
end
function M:spawn_point(def,aim,ignore)
  local origin,dir=aim()
  local yes,hit,object=self.combat:trace(origin,M.offset(origin,dir,600),1,nil,ignore)
  if def.phases_terrain then
    if not yes then return M.offset(origin,dir,600) end
    local p=M.offset(hit.ImpactPoint,hit.ImpactNormal,2);p.Z=p.Z+def.height/2
    return p
  end
  local fluid=self.binding.mc_fluid_sampler
  if def.aquatic and fluid then
    local limit=yes and math.min(600,M.length(M.delta(hit.ImpactPoint,origin))) or 600
    for step=80,limit,40 do
      local p=M.offset(origin,dir,step)
      if fluid:water_at(p.X,p.Y,p.Z) and self:clear_capsule(def,p) then return p end
    end
  end
  if not yes then return nil end
  local p=M.offset(hit.ImpactPoint,hit.ImpactNormal,def.radius+3)
  if valid(object) and object:IsA(self.char) then
    p.X=p.X-dir.X*(def.radius+20);p.Y=p.Y-dir.Y*(def.radius+20)
  end
  return self:free_position(def,p,ignore)
end
function M:free_position(def,p,ignore,occupancy_ignore)
  local ground=self:ground(p,ignore,60,320)
  if not ground then return end
  local half=def.height/2
  local centre=vec(ground.X,ground.Y,ground.Z+half+4)
  if self:clear_capsule(def,centre,occupancy_ignore) then return centre end
end
function M:follow_position(m,feet,attempt)
  local p=require('rules.mob_follow').candidate(feet,m.serial,attempt,m.def.radius)
  local def=m.def
  if def.phases_terrain then return vec(p.X,p.Y,feet.Z+def.height/2+100) end
  local ignored={m.actor}
  if def.aquatic and not def.amphibious then
    local water=self.binding.mc_fluid_sampler
    p.Z=p.Z+def.height/2
    if water and water:water_at(p.X,p.Y,p.Z) and self:clear_capsule(def,p,ignored) then return p end
    return
  end
  local floor=self:ground(p,ignored,100,150)
  if not floor then return end
  local sampler=self.binding.mc_fluid_sampler
  if sampler and sampler._point then
    local kind=sampler:_point(floor.X,floor.Y,floor.Z+8,{})
    if kind=='lava' or kind=='water' and not def.aquatic then return end
  end
  -- Require support across the footprint, not one lucky ray on a ledge.
  local radius=math.min(def.radius,def.height/2)*.7
  for _,d in ipairs({{radius,0},{-radius,0},{0,radius},{0,-radius}}) do
    local at=vec(p.X+d[1],p.Y+d[2],floor.Z)
    local support=self:ground(at,ignored,35,40)
    if not support or math.abs(support.Z-floor.Z)>30 then return end
  end
  local centre=vec(p.X,p.Y,floor.Z+def.height/2+4+(def.flies and 100 or 0))
  if self:clear_capsule(def,centre,ignored) then return centre end
end
function M:cage_position(def,block,ignore)
  local sample=require('rules.mob_spawner').sample(block,math.random)
  local centre=vec(sample.X,sample.Y,sample.Z+def.height/2+4)
  local water=self.binding.mc_fluid_sampler
  if def.aquatic and water and water:water_at(centre.X,centre.Y,centre.Z) then
    if self:clear_capsule(def,centre) then return centre end
    return
  end
  if def.flies then
    -- create() lifts flyers by 45 cm. Test their final capsule.
    if self:clear_capsule(def,vec(centre.X,centre.Y,centre.Z+45)) then return centre end
    return
  end
  local p=self:free_position(def,sample,ignore)
  if p and math.abs((p.Z-def.height/2-4)-(block.z-50))<=104 then return p end
end
function M:clear_capsule(def,centre,ignore)
  if def.phases_terrain then return true end
  local half=def.height/2
  local lib=UE.GetKismetSystemLibrary()
  local color={R=0,G=0,B=0,A=0}
  -- Do not bury a new mob in a wall/ceiling. The owner is also checked here.
  return not lib:CapsuleTraceSingle(self.pawn,centre,vec(centre.X,centre.Y,centre.Z+.1),math.min(def.radius,half),half,
      0,false,ignore or {},0,{},false,color,color,0)
end
function M:create(def,p,serial,exact)
  -- Preserve species identity: spawner nearby limits compare this definition.
  -- Runtime health and command attributes belong on the live record instead.
  local ai=require('rules.mob_ai').profile(def.name)
  local maximum=tonumber(def.max_health or def.health) or ai.health
  assert(maximum>0 and maximum<1e9,'summon-health-definition')
  local pos=M.copy(p)
  if def.flies and not exact then pos.Z=pos.Z+45 end
  -- PBZ initially checks the default Character capsule, before the species
  -- capsule can be installed. Leave headroom for small creatures on the ground.
  local default_half=self.default_half
  if not default_half then
    default_half=StaticFindObject('/Script/Engine.Default__Character').CapsuleComponent:GetScaledCapsuleHalfHeight()
    self.default_half=default_half
  end
  local initial=vec(pos.X,pos.Y,pos.Z+math.max(0,default_half-def.height/2))
  local actor
  if def.phases_terrain then actor=require('host.pbz.dragon_collision').spawn(self,pos)
  else actor=self.pawn:GetWorld():SpawnActor(self.char,initial,{Pitch=0,Yaw=0,Roll=0}) end
  if not valid(actor) then return nil end -- an occupied site is a normal failed attempt
  local m={actor=actor,id=ids.capture(actor),def=def,serial=serial,position=pos,
    health=maximum,max_health=maximum,ai=ai}
  local ok,why=pcall(function()
    local cap=actor.CapsuleComponent;local half=def.height/2
    cap:SetCapsuleSize(math.min(def.radius,half),half,true)
    if def.phases_terrain then require('host.pbz.dragon_collision').target_only(cap)
    else
      cap:SetCollisionResponseToChannel(2,1) -- overlap pawns, block terrain
      cap:SetCollisionResponseToChannel(3,2)
    end
    actor.bUseControllerRotationYaw=false
    m.move=actor.CharacterMovement;m.move.bRunPhysicsWithNoController=true
    m.move.bOrientRotationToMovement=false;m.move.MaxWalkSpeed=def.speed;m.move.MaxFlySpeed=def.speed
    m.move.MaxStepHeight=60
    m.move.JumpZVelocity=520;m.move.AirControl=1
    m.move:SetMovementMode(def.flies and 5 or 1,0)
    assert(actor:K2_SetActorLocationAndRotation(pos,{Pitch=0,Yaw=0,Roll=0},false,{},true),'undead-placement')
    local asset=assert(self.models.entries[def.name])
    local units=def.model_units or def.height/(asset.top-asset.bottom)
    m.parts=self.models:attach(actor,def.name,units,def.height/2)
    m.visual=self.models:animation(def.name,assert(asset.rig,'mob-rig-missing'))
    require('host.pbz.undead_models').pose(m,StaticFindObject('/Script/Engine.Default__GameplayStatics'):GetTimeSeconds(self.pawn),false)
    if def.phases_terrain then require('host.pbz.dragon_collision').attach(m) end
  end)
  if not ok then actor:K2_DestroyActor();error(why) end
  return m
end
function M:enemies(origin,radius,ignore)
  local found,targets={},{}
  UE.GetKismetSystemLibrary():SphereOverlapActors(self.pawn,origin,radius,
    require('host.pbz.build_world').object_types,self.hostile_class,ignore,found)
  for _,raw in ipairs(found) do
    local actor=raw.GetFullName and raw or raw:get()
    if self.combat.damage:eligible(actor) then
      targets[#targets+1]={actor=actor,id=ids.capture(actor),pos=M.copy(actor:K2_GetActorLocation())}
    end
  end
  return targets
end
function M:sight(a,b,target,ignore)
  local list={table.unpack(ignore)};list[#list+1]=target
  return require('host.pbz.wind_burst').clear(self.binding,a,b,list)
end
function M:path(m,destination)
  local nav=StaticFindObject('/Script/NavigationSystem.Default__NavigationSystemV1')
  if not valid(nav) then return end
  local path=nav:FindPathToLocationSynchronously(self.pawn,m.position,destination,m.actor,nil)
  if not valid(path) or not path:IsValid() then return end
  local points={}
  path.PathPoints:ForEach(function(_,entry)
    if #points<32 then points[#points+1]=M.copy(entry:get()) end
  end)
  if #points>1 then return {points=points,index=2} end
end
function M:move_to(m,destination,now)
  local toward=destination
  local ground=not (m.def.flies or m.swimming)
  if ground and m.path then
    local route=m.path
    local p=route.points[route.index]
    if p and (p.X-m.position.X)^2+(p.Y-m.position.Y)^2<60^2 then route.index=route.index+1;p=route.points[route.index] end
    if p then toward=p else m.path=nil end
  end
  local d=M.delta(toward,m.position)
  if ground then d.Z=0 end
  local len=M.length(d)
  if len<8 then m.steer=nil;return end
  m.steer=vec(d.X/len,d.Y/len,d.Z/len)
  local yaw=M.rotation(m.steer).Yaw
  if not m.yaw or math.abs((yaw-m.yaw+180)%360-180)>2 then
    m.yaw=yaw;m.actor:K2_SetActorRotation({Yaw=yaw,Pitch=0,Roll=0},false)
  end
  if ground and now>=(m.repath or 0) then
    m.repath=now+.5+(m.serial%4)*.05
    local last=m.last_progress;m.last_progress=M.copy(m.position)
    if last and (last.X-m.position.X)^2+(last.Y-m.position.Y)^2<36^2 then
      m.stuck_since=m.stuck_since or now
      if (self.path_budget or 0)>0 then self.path_budget=self.path_budget-1;m.path=self:path(m,destination) end
    else
      m.stuck_since=nil
    end
  end
  if ground and m.move.MovementMode==1 and now>=(m.next_obstacle or 0) and (self.probe_budget or 0)>0 then
    self.probe_budget=self.probe_budget-1;m.next_obstacle=now+.2
    self:obstacle(m,now)
  end
end
function M:obstacle(m,now)
  local p=m.position;local half=m.def.height/2;local feet=p.Z-half
  local ahead=math.max(65,m.def.radius+45);local d=m.steer
  local low=vec(p.X,p.Y,feet+30)
  local front=M.offset(low,d,ahead)
  local ignored={m.actor,self.pawn}
  local blocked=self.combat:trace(low,front,math.min(12,m.def.radius*.5),nil,ignored)
  if not blocked then return end
  -- Jump over one block, with full capsule headroom at takeoff and landing.
  local landing=self:ground(vec(front.X,front.Y,feet+110),ignored,10,150)
  if not landing or landing.Z-feet>105 or landing.Z-feet<25 or now<(m.next_jump or 0) then return end
  local lift=landing.Z-feet+12
  local raised=vec(p.X,p.Y,p.Z+lift)
  local destination=vec(front.X,front.Y,landing.Z+half+4)
  if not self:clear_capsule(m.def,raised,{m.actor}) or not self:clear_capsule(m.def,destination,{m.actor}) then return end
  local color={R=0,G=0,B=0,A=0}
  if UE.GetKismetSystemLibrary():CapsuleTraceSingle(self.pawn,raised,vec(front.X,front.Y,raised.Z),
      math.min(m.def.radius,half),half,0,false,{m.actor},0,{},false,color,color,0) then return end
  local gravity=math.abs(m.move:GetGravityZ())
  local speed=m.move.MaxWalkSpeed;local boost=require('rules.status_effects').level(m.status,'jump_boost')
  m.actor:LaunchCharacter(vec(d.X*speed,d.Y*speed,math.sqrt(2*math.max(1,gravity)*125)+200*boost),true,true)
  m.next_jump=now+.6;m.jumps=(m.jumps or 0)+1;m.path=nil
end
return M
