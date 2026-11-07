"""Exercise actual flight/firework hosts with isolated swept-movement doubles.

No game, native collision engine, real input or save is touched. The fixture
checks transaction/owner boundaries and frame scheduling using production Lua.
"""
from pathlib import Path
import hashlib
import json
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'build/lua-check'))
from lupa.lua54 import LuaRuntime

lua = LuaRuntime(unpack_returned_tuples=True)
lua.globals().root = ROOT.as_posix()
lua.execute("package.path=root..'/src/?.lua;'..root..'/third_party/dkjson/?.lua;'..package.path")
result = json.loads(lua.execute(r'''
local json=require('dkjson')
local State=require('storage.state')
local Slots=require('rules.container_slots')
local canonical=require('storage.canonical_json')
local identity=require('host.pbz.object_identity')
local checks,scenarios,failures=0,0,{}
local f
local function check(ok,why)checks=checks+1;assert(ok,why)end
local function near(a,b,why,tolerance)check(math.abs(a-b)<(tolerance or 1e-6),why or (tostring(a)..' != '..tostring(b)))end
local function scenario(name,run)
 scenarios=scenarios+1
 local ok,err=pcall(run)
 if not ok then failures[#failures+1]={name=name,error=tostring(err),flight=f and f.flight and f.flight.report,
  rockets=f and f.service and f.service.report}end
end
local function v(x,y,z)return {X=x,Y=y,Z=z}end
local function copy(p)return v(p.X,p.Y,p.Z)end
local function forbidden(name)return function()error('forbidden:'..name)end end
local serial=100
local function object(kind)
 serial=serial+1
 local o={address=serial,name=kind..'_'..serial,valid=true,kind=kind}
 function o:IsValid()return self.valid end
 function o:GetAddress()return self.address end
 function o:GetFullName()return self.name end
 function o:IsA(class)return class and (class.name==self.kind
  or (class.name=='/Script/Engine.Pawn' or class.name=='/Script/ProjectPBZ.PBZCharacter')and self.kind=='pawn'
  or class.name=='/Script/Engine.Actor'and (self.kind=='pawn'or self.kind=='terrain'))end
 return o
end
local gameplay={}
function gameplay:GetTimeSeconds()return f.now end
function gameplay:IsGamePaused()return f.paused or false end
gameplay.SaveGameToSlot=forbidden('save')
local classes={}
function StaticFindObject(path)
 if path=='/Script/Engine.Default__GameplayStatics'then return gameplay end
 if not classes[path]then classes[path]={name=path,IsValid=function()return true end}end
 return classes[path]
end
function LoopInGameThreadAfterFrames(frames,fn)
 check(frames==1,'one-frame scheduler request')
 f.timer_serial=f.timer_serial+1;f.timers[f.timer_serial]=fn;return f.timer_serial
end
function CancelDelayedAction(key)f.timers[key]=nil;f.cancelled=f.cancelled+1 end
function PBZMC_BlockSound(raw)f.sounds[#f.sounds+1]=raw;return '{"ok":true}'end
package.loaded['host.pbz.appearance']={valid=function(o)return o and o.IsValid and o:IsValid()or false end}
package.loaded['host.pbz.campaign_inventory']={
 armor_slots=function(binding)check(binding==f.binding,'current armor owner');return f.armor end,
 view=function(binding)check(binding==f.binding,'current inventory owner');return f.data end,
 current=function(binding)return binding==f.binding and f.current end}
local damage={}
function damage:hit(row,amount,action,kind,position,normal)
 check(row.actor==f.pawn and row.player,'only explicit self-damage')
 f.damage[#f.damage+1]={amount=amount,action=action,kind=kind,position=position,normal=normal}
 return {accepted=true}
end
function damage:close()f.damage_closed=true end
package.loaded['host.pbz.tnt_damage']={new=function()return damage end}
package.loaded['host.pbz.building_service']={get=function()
 return {audio={combat=function(_,name)f.sounds[#f.sounds+1]=name end},
  world={placement_obstacle=function(_,component)return component and component.kind=='pawn'and 'pawn'or 'terrain'end}}
end}
local kismet={}
package.loaded.UEHelpers={GetKismetSystemLibrary=function()return kismet end}

local function ray(start,finish,planes)
 local best
 for _,plane in ipairs(planes)do
  local a=plane.axis;local s,e=start[a],finish[a]
  local blocked=plane.maximum and e>plane.value+1e-9 or not plane.maximum and e<plane.value-1e-9
  if blocked and not (plane.component and f.pawn.CapsuleComponent.ignored[plane.component]) then
   local delta=e-s
   local t=math.abs(delta)>1e-12 and (plane.value-s)/delta or 0
   t=math.max(0,t)
   if t<=1 and (not best or t<best.time)then best={time=t,plane=plane}end
  end
 end
 if not best then return false end
 local p=v(start.X+(finish.X-start.X)*best.time,start.Y+(finish.Y-start.Y)*best.time,start.Z+(finish.Z-start.Z)*best.time)
 local n=v(0,0,0);n[best.plane.axis]=best.plane.maximum and -1 or 1
 return true,{Location=p,ImpactPoint=copy(p),Normal=n,ImpactNormal=copy(n),Time=best.time,
  Actor={Get=function()return best.plane.actor end},Component={Get=function()return best.plane.component end},
  HitObjectHandle={ReferenceObject={Get=function()return best.plane.component or best.plane.actor end}},bBlockingHit=true}
end
function kismet:SphereTraceSingle(actor,start,finish,radius,channel,complex,ignore,draw,out,ignore_self)
 check(actor==f.pawn and ignore_self and ignore[1]==f.pawn,'rocket trace isolates owner')
 local yes,hit
 if f.trace_override then yes,hit=f.trace_override(start,finish)
 else yes,hit=ray(start,finish,f.rocket_planes)end
 if hit then for key,value in pairs(hit)do out[key]=value end end
 return yes
end
local Visual={}
function Visual:launch(position,...)
 if f.visual_error then error('fixture-visual-error')end
 f.visual_serial=f.visual_serial+1
 local h={id=f.visual_serial,active=true,position=copy(position)}
 f.handles[#f.handles+1]=h;f.active_visuals=f.active_visuals+1;return h
end
function Visual:update(h,p,velocity)
 check(h and h.active,'only live visual updated');h.position=copy(p);h.velocity=copy(velocity)
end
function Visual:remove(h)
 check(h and h.active,'visual removed exactly once');h.active=false;f.active_visuals=f.active_visuals-1
end
function Visual:tick(dt)f.visual_ticks=f.visual_ticks+1 end
function Visual:close()
 for _,h in ipairs(f.handles)do if h.active then h.active=false;f.active_visuals=f.active_visuals-1 end end
 f.visual_closed=true
end
package.loaded['host.pbz.firework_visuals']={new=function()return setmetatable({},{__index=Visual})end}
local Flight=require('host.pbz.elytra_flight')
local Rockets=require('host.pbz.firework_service')
local Rules=require('rules.elytra_flight')
io.open=forbidden('filesystem');os.execute=forbidden('subprocess')

local function fixture()
 math.randomseed(1211)
 f={now=0,current=true,equipped=true,moves={},planes={},rocket_planes={},damage={},sounds={},timers={},timer_serial=0,cancelled=0,
  handles={},visual_serial=0,active_visuals=0,visual_ticks=0,commits=0,logs={},launches={}}
 f.pawn=object('pawn');f.pc=object('controller');f.movement=object('movement');f.anim=object('anim');f.source=object('source')
 f.pc.ControlRotation={Pitch=0,Yaw=0,Roll=0};f.pc.look_ignored=1;f.pc.move_ignored=2
 function f.pc:SetIgnoreLookInput(value)self.look_ignored=self.look_ignored+(value and 1 or -1)end
 function f.pc:SetIgnoreMoveInput(value)self.move_ignored=self.move_ignored+(value and 1 or -1)end
 function f.pc:SetMouseLocation(x,y)self.mouse={x=x,y=y}end
 function f.pc:SetControlRotation(r)self.ControlRotation={Pitch=r.Pitch,Yaw=r.Yaw,Roll=r.Roll};self.control_writes=(self.control_writes or 0)+1 end
 f.movement.MovementMode=3;f.movement.CustomMovementMode=0
 function f.movement:StopMovementImmediately()f.pawn.native_velocity=v(0,0,0)end
 function f.movement:SetMovementMode(mode,custom)self.MovementMode=mode;self.CustomMovementMode=custom end
 f.anim.RootMotionMode=2
 function f.anim:SetRootMotionMode(mode)self.RootMotionMode=mode end
 function f.source:GetAnimInstance()return f.anim end
 f.pawn.CharacterMovement=f.movement;f.pawn.position=v(0,0,1000);f.pawn.native_velocity=v(1000,200,-100)
 f.pawn.bUseControllerRotationYaw=true
 f.pawn.CapsuleComponent=object('component')
 f.pawn.CapsuleComponent.ignored={}
 function f.pawn.CapsuleComponent:CopyArrayOfMoveIgnoreComponents()
  local list={};for c in pairs(self.ignored)do list[#list+1]=c end;return list
 end
 function f.pawn.CapsuleComponent:IgnoreComponentWhenMoving(c,value)self.ignored[c]=value or nil end
 f.pawn.AttributeSetBase={Health={CurrentValue=1000},Health_Max={CurrentValue=1000}}
 function f.pawn:GetVelocity()return copy(self.native_velocity)end
 function f.pawn:K2_GetActorLocation()return copy(self.position)end
 function f.pawn:K2_SetActorLocation(target,sweep,out,teleport)
  check(sweep==true and teleport==false,'every flight move is swept, never teleport')
  local start=copy(self.position);local yes,hit=ray(start,target,f.planes)
  self.position=yes and copy(hit.Location)or copy(target)
  if hit then for key,value in pairs(hit)do out[key]=value end end
  f.moves[#f.moves+1]={start=start,requested=copy(target),accepted=copy(self.position),collision=yes}
  return not yes
 end
 function f.pawn:K2_SetActorRotation(r)self.rotation=r end
 function f.pawn:LaunchCharacter(velocity,xy,z)
  check(xy and z,'release uses the surviving velocity');self.native_velocity=copy(velocity);f.launches[#f.launches+1]=copy(velocity)
 end
 f.pawn.SetActorEnableCollision=forbidden('collision-disable')
 f.pawn.SetCollisionResponseToChannel=forbidden('collision-mask')
 f.data=Slots.empty();f.data.player.hotbar['1']=State.object({content_id='pbzmc:firework_rocket',count=8,metadata=State.object()})
 f.armor={chest={content_id='pbzmc:elytra',count=1}}
 f.binding={actor=f.pawn,actor_id=identity.capture(f.pawn),source=f.source,closed=false}
 function f.binding:is_current()return f.current and not self.closed and self.actor:IsValid()end
 f.binding.log=function(s)f.logs[#f.logs+1]=s end
 local status={value=State.object(),mode='adventure'}
 function status:current()return f.current and not f.status_stale end
 function status:commit(value,address,expected,consume)
  if f.commit_error then error('fixture-commit-failed')end
  check(canonical(Slots.get(f.data,address))==canonical(expected),'debit compare-and-swap')
  f.commits=f.commits+1
  if consume then
   local draft=Slots.edit(f.data);local stack=State.clone(expected);stack.count=stack.count-1
   draft:set(address,stack.count>0 and stack or nil);f.data=draft.data
  end
 end
 f.binding.mc_status_service=status
 f.camera={focused=true,inventory=false,traversal=function()return f.traversal end}
 f.flight=Flight.new(f.binding,f.pc)
 return f
end
local function batch(keys,epoch,focused,dx)
 return {samples={},latest={keys=keys or 0,epoch=epoch or 1,focused=focused~=false,seq=(f.seq or 0)+1,
  time_ms=f.now*1000,width=1280,height=720,x=640,y=360,look_dx=dx or 0,look_dy=0},overflow=false}
end
local function start()
 f.flight:start();check(f.binding.mc_gliding==f.flight and f.movement.MovementMode==0,'flight takes one temporary movement owner')
 check(f.pc.look_ignored==2 and f.pc.move_ignored==3 and f.anim.RootMotionMode==1,'input/root-motion leases acquired once')
end
local function advance(dt)
 f.now=f.now+dt;f.flight:tick(f.camera)
end
local function use(hand,action)
 hand=hand or 'mainhand'
 local stack=hand=='offhand'and f.data.player.offhand or f.data.player.hotbar['1']
 return f.service:use({hand=hand,action_id=action or 'fixture',equipment={[hand]=State.clone(stack)}},
  function()return v(0,0,100),v(0,0,-1)end)
end
local function rockets()
 f.service=Rockets.new(f.binding,f.pc,f.binding.log);return f.service
end
local function active_visuals()local n=0;for _,h in ipairs(f.handles)do if h.active then n=n+1 end end;return n end

scenario('second fresh jump starts while rising; held first jump does not',function()
 fixture();f.movement.MovementMode=1
 f.flight:input_batch(batch(0),true);f.flight:input_batch(batch(1<<18),true)
 check(not f.flight:wants_start(f.camera),'ground jump stays native')
 f.movement.MovementMode=3;f.pawn.native_velocity.Z=500
 f.flight:input_batch(batch(1<<18),true);check(not f.flight:wants_start(f.camera),'held original Space is not a new edge')
 f.flight:input_batch(batch(0),true);f.flight:input_batch(batch(1<<18),true)
 check(f.flight:wants_start(f.camera),'new airborne Space starts without downward-speed gate')
end)
scenario('focus and epoch baselines cannot manufacture a flight request',function()
 fixture();f.flight:input_batch(batch(0),true)
 local mixed=batch(1<<18,2);mixed.samples={batch(1<<18,1).latest}
 f.flight:input_batch(mixed,true);check(not f.flight:wants_start(f.camera),'old-epoch queued edge cannot start in the new epoch')
 f.flight:input_batch(batch(0,2,false),false);f.flight:input_batch(batch(1<<18,2,true),true)
 check(not f.flight:wants_start(f.camera),'focus regain held key is a baseline')
end)
scenario('water blocks fresh start; stale water sample does not',function()
 fixture();f.binding.mc_fluid_contact={kind='water',active=true,valid_until=.05}
 f.flight:input_batch(batch(0),true);f.flight:input_batch(batch(1<<18),true)
 check(not f.flight:wants_start(f.camera),'current water rejects start')
 f.now=1;f.flight:input_batch(batch(0),true);f.flight:input_batch(batch(1<<18),true)
 check(f.flight:wants_start(f.camera),'expired contact cannot permanently reject airborne start')
end)
scenario('zero dt, half ticks and release preserve owner counters',function()
 fixture();start();f.flight:tick(f.camera);f.flight:tick(f.camera)
 check(f.flight.report.ticks==0 and #f.moves==0,'paused/zero game time never steps')
 advance(.025);check(f.flight.report.ticks==1,'first positive interval advances one velocity tick')
 advance(.025);check(f.flight.report.ticks==1,'remaining half tick does not apply gravity twice')
 advance(.001);check(f.flight.report.ticks==2,'new tick begins only at its boundary')
 local last=copy(f.flight.velocity);f.flight:close();f.flight:close()
 check(f.movement.MovementMode==3 and f.binding.mc_gliding==nil,'close returns to falling')
 check(f.pc.look_ignored==1 and f.pc.move_ignored==2 and f.anim.RootMotionMode==2,'only this owner leases released')
 check(#f.launches==1 and f.pawn.bUseControllerRotationYaw==true,'release idempotent and native yaw restored')
 near(f.launches[1].X,last.X,'momentum survives release');check(f.flight.report.stops==1,'one stop')
end)
scenario('inventory and focus clear look but existing physics coasts; paused clock stays still',function()
 fixture();start();f.flight:input_batch(batch(0),true);advance(.05)
 local before=copy(f.pawn.position);local yaw=f.pc.ControlRotation.Yaw
 f.camera.inventory=true;f.camera.focused=false;f.flight:input_batch(batch(1<<18,1,false,80),false);advance(.05)
 check(f.flight.active and f.pawn.position.X>before.X,'authorised host adaptation retains existing flight inertia')
 near(f.pc.ControlRotation.Yaw,yaw,'blocked input does not steer')
 local ticks=f.flight.report.ticks;before=copy(f.pawn.position);f.flight:tick(f.camera)
 check(f.flight.report.ticks==ticks and f.pawn.position.X==before.X,'paused world clock cannot move')
end)
scenario('death and native takeover release without overriding newer movement',function()
 fixture();start();f.movement:SetMovementMode(6,2);advance(.02)
 check(not f.flight.active and f.movement.MovementMode==6 and f.movement.CustomMovementMode==2,'new movement owner keeps its mode')
 check(f.pc.look_ignored==1 and f.pc.move_ignored==2 and #f.launches==0,'takeover releases only input ownership')
 fixture();start();f.pawn.AttributeSetBase.Health.CurrentValue=0;advance(.02)
 check(not f.flight.active and f.movement.MovementMode==0 and #f.launches==0,'dead pawn is not relaunched')
end)
scenario('stale actor/controller does not receive new movement',function()
 fixture();start();f.current=false;advance(.02)
 check(not f.flight.active and #f.moves==0,'owner replacement stops before sweeping')
 check(f.pc.look_ignored==1 and f.pc.move_ignored==2 and f.anim.RootMotionMode==2,'still-valid leases released on old owner')
end)
scenario('replacement native movement component ends the old physics lease',function()
 fixture();start();local old=f.movement;local replacement=object('movement');replacement.MovementMode=3;replacement.CustomMovementMode=0
 function replacement:SetMovementMode(mode,custom)self.MovementMode=mode;self.CustomMovementMode=custom end
 f.pawn.CharacterMovement=replacement;advance(.02)
 check(not f.flight.active and #f.moves==0,'changed movement identity stops before moving actor')
 check(replacement.MovementMode==3 and #f.launches==0,'old flight must not launch or change replacement component')
 check(f.pc.look_ignored==1 and f.pc.move_ignored==2,'component replacement releases input leases')
end)
scenario('clock interruption cancels flight rather than simulating stale input',function()
 fixture();start();advance(2.01)
 check(not f.flight.active and #f.moves==0 and f.movement.MovementMode==3,'long clock gap releases flight without catchup sweep')
 check(f.pc.look_ignored==1 and f.pc.move_ignored==2,'clock cancellation balances leases')
end)
scenario('late glider deployment preserves already accumulated fast-fall distance',function()
 fixture();f.pawn.native_velocity=v(0,0,-2500)
 for _,z in ipairs({1000,850,700,550,400})do
  f.pawn.position=v(0,0,z);f.now=f.now+.05;f.flight:observe_fall();f.flight:wants_start(f.camera)
 end
 f.flight:input_batch(batch(0),true);f.flight:input_batch(batch(1<<18),true)
 check(f.flight:wants_start(f.camera),'late fresh jump accepted while falling')
 start();check(f.flight.fall_distance>=600,'equipping/deploying is not a blanket fall-distance reset')
end)
scenario('real water contact clears prior fall distance; expired contact does not',function()
 fixture();f.flight.fall_distance=600;f.flight.fall_z=1000;f.flight.fall_mode=3
 f.binding.mc_fluid_contact={kind='water',active=true,valid_until=1};f.flight:observe_fall()
 check(f.flight.fall_distance==0,'water update mirrors Entity.onLanding fall-distance reset')
 f.binding.mc_fluid_contact=nil;f.movement.MovementMode=4;f.flight.fall_distance=600;f.flight:observe_fall()
 check(f.flight.fall_distance==0,'native swimming also clears prior fall distance')
 f.movement.MovementMode=3;f.now=2;f.flight.fall_distance=600;f.flight.fall_z=nil
 f.binding.mc_fluid_contact={kind='water',active=true,valid_until=1};f.flight:observe_fall()
 check(f.flight.fall_distance==600,'expired water cannot grant a free fall-distance reset')
end)
scenario('water entry during fast glide clears fall history before returning native movement',function()
 fixture();f.pawn.native_velocity=v(0,0,-2500);start();f.flight.fall_distance=700
 f.binding.mc_fluid_contact={kind='water',active=true,valid_until=1};advance(.02)
 check(not f.flight.active and f.flight.fall_distance==0,'entering water cannot retain pre-water collision damage')
end)
scenario('successful teleport fall reset does not reinterpret destination delta as a fall',function()
 fixture();f.flight.fall_distance=600;f.flight.fall_z=1000;f.flight.fall_mode=3
 f.pawn.position=v(100,200,300);f.flight:reset_fall();f.flight:observe_fall()
 check(f.flight.fall_distance==0,'teleport destination establishes a fresh fall baseline')
 f.pawn.position.Z=280;f.flight:observe_fall()
 check(f.flight.fall_distance==20,'ordinary downward motion after teleport starts a new fall')
 f.flight:reset_fall();f.flight:reset_fall();check(f.flight.fall_distance==0,'fall reset is idempotent')
end)
scenario('horizontal wall clips capsule and applies one speed-loss self damage',function()
 fixture();f.pawn.native_velocity=v(2000,400,-100);f.planes={{axis='X',value=10,maximum=true}}
 start();advance(.05)
 check(f.pawn.position.X<=10.00001 and f.pawn.position.Y>0,'swept wall stops normal motion but permits tangent')
 check(f.flight.velocity.X<1e-6 and #f.damage==1 and f.damage[1].kind=='fly_into_wall','real wall loss reaches correct self-damage kind')
 local hp=f.pawn.AttributeSetBase.Health.CurrentValue
 check(hp==1000,'adapter never overwrites HP directly')
 advance(.01);check(#f.damage==1,'same physics tick does not reapply impact')
end)
scenario('fast landing retains fall distance and uses fall damage once',function()
 fixture();f.pawn.position=v(0,0,200);f.pawn.native_velocity=v(0,0,-2500);f.pc.ControlRotation.Pitch=-89
 f.planes={{axis='Z',value=100,maximum=false}};start();f.flight.fall_distance=500;advance(.1)
 check(not f.flight.active and f.movement.MovementMode==1 and f.pawn.position.Z>=100,'ground sweep lands without tunneling')
 check(#f.damage==1 and f.damage[1].kind=='fall','fast landing submits normal fall damage')
 check(f.pc.look_ignored==1 and f.pc.move_ignored==2,'landing releases input leases')
end)
scenario('air-wall exclusions remain local and physical geometry still blocks',function()
 fixture()
 local owner=object('terrain')
 local function component(profile)
  local c=object('component')
  function c:GetOwner()return owner end
  function c:GetCollisionProfileName()return {ToString=function()return profile end}end
  return c
 end
 local air,solid,prior=component('Profile_LA_InvisibleWall'),component('BlockAll'),component('InvisibleWall')
 f.pawn.CapsuleComponent.ignored[prior]=true
 f.planes={{axis='X',value=5,maximum=true,component=air,actor=owner},
  {axis='X',value=15,maximum=true,component=solid,actor=owner}}
 f.pawn.native_velocity=v(2000,0,0);start();advance(.05)
 check(f.pawn.position.X>5 and f.pawn.position.X<=15,'air passed, solid sibling component blocked')
 check(f.pawn.CapsuleComponent.ignored[air] and not f.pawn.CapsuleComponent.ignored[solid],'only air component excluded')
 f.flight:stop('test')
 check(not f.pawn.CapsuleComponent.ignored[air] and f.pawn.CapsuleComponent.ignored[prior],'owned exclusions restored, prior ignore retained')
end)
local function flight_frames(fps,lag)
 fixture();start();local maximum=0
 if lag then advance(.8);maximum=f.flight.report.ticks;for i=1,3 do f.flight:tick(f.camera)end end
 for i=1,math.floor(fps*(lag and 3.2 or 4)+.5)do
  local before=f.flight.report.ticks;advance(1/fps);maximum=math.max(maximum,f.flight.report.ticks-before)
 end
 return {position=copy(f.pawn.position),velocity=copy(f.flight.velocity),ticks=f.flight.report.ticks,max_ticks=maximum}
end
local frame_results={}
scenario('host sweep integration matches across render partitions and bounded backlog',function()
 local reference=flight_frames(60);frame_results['60']=reference
 for _,fps in ipairs({5,20,30,144})do
  local candidate=flight_frames(fps);frame_results[tostring(fps)]=candidate
  check(candidate.ticks==reference.ticks,'same flight game-tick count at '..fps..' FPS')
  for _,key in ipairs({'X','Y','Z'})do near(candidate.position[key],reference.position[key],'render-rate invariant glide position '..key..' at '..fps,1e-5)end
  check(candidate.max_ticks<=4,'bounded 4-tick catchup')
 end
 local lag=flight_frames(60,true);frame_results.lag=lag
 check(lag.ticks==reference.ticks and lag.max_ticks<=4,'no lost game ticks in drained .8-second backlog')
 for _,key in ipairs({'X','Y','Z'})do near(lag.position[key],reference.position[key],'drained backlog position '..key,1e-5)end
end)
scenario('attached main/offhand debit is exactly once and boosts with surviving velocity',function()
 fixture();start();rockets();check(use('mainhand','m1'),'mainhand launch')
 check(f.data.player.hotbar['1'].count==7 and #f.service.rockets==1 and active_visuals()==1,'one accepted entity and debit')
 check(not use('mainhand','m1') and f.data.player.hotbar['1'].count==7,'repeated action cannot charge twice')
 f.data.player.offhand=State.clone(f.data.player.hotbar['1']);check(use('offhand','o1'),'offhand launch')
 check(f.data.player.offhand.count==6 and f.data.player.hotbar['1'].count==7,'exact triggering hand debit')
 local before=f.service.report.boosts;advance(.05)
 check(f.service.report.boosts==before+2 and f.flight.velocity.X>2000,'two live attached rockets both boost')
end)
scenario('failed debit rolls back visual and permits retry of same action',function()
 fixture();start();rockets();f.commit_error=true
 check(not use('mainhand','retry'),'commit failure rejected')
 check(f.data.player.hotbar['1'].count==8 and f.commits==0 and #f.service.rockets==0 and active_visuals()==0,'failed commit leaves no entity or charge')
 f.commit_error=false;check(use('mainhand','retry'),'same action may retry after a failed transaction')
 check(f.data.player.hotbar['1'].count==7 and #f.service.rockets==1,'retry publishes once')
end)
scenario('visual allocation failure does not consume or publish a rocket',function()
 fixture();start();rockets();f.visual_error=true
 local ok,accepted=pcall(use,'mainhand','fx-fail')
 check(not ok or not accepted,'visual failure does not succeed')
 check(f.commits==0 and #f.service.rockets==0 and f.data.player.hotbar['1'].count==8 and active_visuals()==0,'allocation failure rolls back before debit')
end)
scenario('ground use requires a surface; accepted use positions along original normal',function()
 fixture();rockets();check(not use('mainhand','miss') and f.commits==0,'empty air passes without consumption')
 f.rocket_planes={{axis='Z',value=0,maximum=false}};check(use('mainhand','ground'),'ground launch succeeds')
 local r=f.service.rockets[1];near(r.position.Z,15,'fifteen-centimetre normal offset')
 check(r.state.kind=='world' and f.data.player.hotbar['1'].count==7,'world rocket debits one')
 near(r.velocity.X,r.state.vx,'initial triangular X velocity survives launch')
 near(r.velocity.Y,r.state.vy,'initial triangular Y velocity survives launch')
end)
scenario('non-gliding use against a native entity passes without debit',function()
 fixture();rockets();local enemy=object('pawn');local component=object('component');component.owner=enemy
 function component:GetOwner()return self.owner end
 f.rocket_planes={{axis='Z',value=0,maximum=false,actor=enemy,component=component}}
 local accepted,action=use('mainhand','entity-use')
 check(not accepted and action=='pass' and f.commits==0 and #f.service.rockets==0,'entity target is not FireworkRocketItem.useOnBlock')
end)
local ground_results={}
local function ground_frames(fps)
 fixture();rockets();f.rocket_planes={{axis='Z',value=0,maximum=false}};check(use('mainhand','ground'),'ground launch fixture')
 f.rocket_planes={};local r=f.service.rockets[1]
 for i=1,fps do f.now=f.now+1/fps;f.service:tick()end
 return {position=copy(r.position),velocity=copy(r.velocity),life=r.state.life,active=#f.service.rockets}
end
scenario('ground rocket integration preserves identical trajectory across frame partitions',function()
 local reference=ground_frames(60);ground_results['60']=reference
 for _,fps in ipairs({5,20,30,144})do
  local candidate=ground_frames(fps);ground_results[tostring(fps)]=candidate
  check(candidate.life==reference.life,'same rocket game ticks at '..fps)
  for _,key in ipairs({'X','Y','Z'})do near(candidate.position[key],reference.position[key],'rocket position '..key..' at '..fps,1e-5)end
 end
end)
scenario('world rocket entity contact removes no-star projectile without damage',function()
 fixture();rockets();f.rocket_planes={{axis='Z',value=0,maximum=false}};check(use('mainhand','entity-test'),'rocket fixture')
 local enemy=object('pawn');local component=object('component');component.owner=enemy
 function component:GetOwner()return self.owner end
 f.rocket_planes={{axis='Z',value=20,maximum=true,actor=enemy,component=component}}
 f.now=.1;f.service:tick()
 check(#f.service.rockets==0 and active_visuals()==0,'entity impact expires the no-star rocket')
 check(#f.damage==0,'no firework stars means zero damage')
end)
scenario('world rocket solid block contact keeps velocity and entity alive',function()
 fixture();rockets();f.rocket_planes={{axis='Z',value=0,maximum=false}};check(use('mainhand','block-test'),'rocket fixture')
 local terrain=object('terrain');local component=object('component');component.owner=terrain
 function component:GetOwner()return self.owner end
 f.rocket_planes={{axis='Z',value=20,maximum=true,actor=terrain,component=component}}
 f.now=.1;f.service:tick()
 check(#f.service.rockets==1 and f.service.rockets[1].position.Z<=20.000001,'solid ceiling blocks position without no-star explosion')
 check(f.service.rockets[1].state.vz>100,'vanilla retains intended vertical velocity through block clipping')
end)
scenario('death or owner replacement closes all rocket visuals and timer without inventory refund',function()
 fixture();start();rockets();check(use('mainhand','closed'),'attached launch')
 f.current=false;f.service:tick();f.service:tick()
 check(f.service.closed and f.binding.mc_fireworks==nil and #f.service.rockets==0 and active_visuals()==0,'stale owner releases every rocket visual')
 check(f.cancelled==1 and f.data.player.hotbar['1'].count==7,'timer cancelled once; used rocket is not duplicated/refunded')
end)
scenario('creative wing and hover share the real camera input and dispatch',function()
 fixture()
 local view_path='/Script/Engine.PlayerController:SetViewTargetWithBlend'
 local schema=StaticFindObject(view_path)
 function schema:GetFunctionFlags() return 67240962 end
 function schema:ForEachProperty(visit)
  for _,field in ipairs({'ObjectProperty NewViewTarget','FloatProperty BlendTime','ByteProperty BlendFunc',
                         'FloatProperty BlendExp','BoolProperty bLockOutgoing'}) do
   local kind,name=field:match('(%S+) (%S+)')
   visit({GetFullName=function()return kind..' '..view_path..':'..name end})
  end
 end
 package.loaded['host.pbz.item_interface']={combat_presentation=function()end}
 local camera=require('host.pbz.first_person_camera').start(f.binding.log)
 camera.context=function()return f.binding,f.pc,{} end
 camera.story=function()return f.story end
 camera.equipment=function()return {group='pbz'} end
 camera.traversal=f.camera.traversal
 camera.update_free_look=function()end
 camera.focused=true;camera.flight=f.flight
 function f.pc:GetInputMouseDelta(x,y)x.DeltaX=0;y.DeltaY=0 end
 f.binding.mc_creative=true;f.binding.mc_status_service.mode='creative'
 f.movement.MovementMode=1;camera:tick()
 local jump=1<<18
 local function send(ms,keys,blocked,epoch)
  f.now=ms/1000;f.seq=(f.seq or 0)+1
  local b=batch(keys,epoch);b.blocked_keys=blocked or 0
  camera:input(b,true,1);camera:tick()
  check(not (f.binding.mc_gliding and f.binding.mc_creative_flight),'two flight owners')
 end
 send(0,0);send(10,jump);f.movement.MovementMode=3
 send(80,jump);check(not f.flight.active,'holding takeoff cannot open wings')
 send(100,0);send(200,jump)
 check(f.binding.mc_creative_flight and not f.flight.active,'quick takeoff double tap reserves hover')
 send(280,0);send(650,jump);send(680,0);send(740,jump)
 check(not f.binding.mc_creative_flight and not f.flight.active,'double tap off is consumed once')
 send(780,jump);check(not f.flight.active,'holding hover exit cannot deploy')
 send(820,0);send(900,jump)
 check(f.flight.active,'fresh air press after hover exit opens wings')
 rockets();check(use('mainhand','creative-glide'),'rocket use')
 send(960,0);check(f.service.report.boosts>0 and f.data.player.hotbar['1'].count==8,'creative rocket boosts without debit')
 local handoff=copy(f.flight.velocity);local launched=#f.launches
 send(1050,jump)
 local hover=f.binding.mc_creative_flight
 check(hover and not f.flight.active and not f.binding.mc_gliding,'glide double tap reaches hover in movement mode None')
 check(#f.launches==launched,'handoff cannot queue a native launch after hover starts')
 near(hover.velocity.X,handoff.X,'handoff preserves horizontal momentum')
 check(f.pc.look_ignored==2 and f.pc.move_ignored==3,'single owner for native look and move gates')
 send(1080,0);send(1500,jump);send(1540,0);send(1580,jump)
 f.movement.MovementMode=1
 send(1800,0);send(1910,jump);f.movement.MovementMode=3
 send(1980,0);send(2300,jump)
 check(f.flight.active and not f.binding.mc_creative_flight,'spaced ground jump and air press starts glide')
 f.planes={{axis='Z',value=f.pawn.position.Z-1,maximum=false}}
 f.flight.velocity=v(0,0,-2000);f.flight.fall_distance=2000
 send(2390,0)
 check(not f.flight.active and f.flight.report.reason=='landed' and #f.damage==0,'creative glide lands without health damage')
 f.planes={};f.movement.MovementMode=3;f.armor.chest=nil
 send(2900,0);send(3000,jump);check(not f.flight.active,'empty chest slot cannot glide')
 f.armor.chest={content_id='pbzmc:elytra',count=1}
 send(3600,0);send(3700,jump,jump);send(3860,jump)
 check(not f.flight.active and not f.binding.mc_creative_flight,'blocked held jump cannot arm either flight')
 send(3910,0);f.binding.mc_native_selection_pending=true;send(4000,jump)
 f.binding.mc_native_selection_pending=nil;send(4050,jump)
 check(not f.flight.active,'weapon handoff cannot replay a held jump')
 send(4120,0);f.traversal='climb';send(4480,jump)
 check(not f.flight.active and not f.binding.mc_creative_flight,'climb owns the jump')
 f.traversal=nil;send(4900,0);f.binding.mc_creative=false;send(5000,jump)
 check(f.flight.active and not f.binding.mc_creative_flight,'survival air press still glides')
 camera:close();f.service:close()
 check(f.pc.look_ignored==1 and f.pc.move_ignored==2,'closing releases exactly the flight gates')
end)
return json.encode({checks=checks,scenarios=scenarios,failures=failures,passed=#failures==0,
 frame_partitions=frame_results,ground_partitions=ground_results})
'''))
result.update(source_sha256={str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
                            for path in [ROOT / 'src/host/pbz/elytra_flight.lua',
                                         ROOT / 'src/host/pbz/firework_service.lua',
                                         ROOT / 'src/host/pbz/first_person_camera.lua']},
              game_loaded=False, real_input=False, native_collision_engine=False,
              native_damage=False, save_written=False)
receipt = ROOT / 'research/evidence/elytra-host-check-20261101.json'
receipt.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n', 'utf-8')
print(json.dumps({key: result[key] for key in ('passed', 'checks', 'scenarios', 'failures')}, ensure_ascii=False))
if not result['passed']:
    raise SystemExit(1)
