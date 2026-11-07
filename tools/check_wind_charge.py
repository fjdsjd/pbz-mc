"""Exercise inventory, real wind flight and redstone against deterministic host collision."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'build/lua-check'))
from lupa.lua54 import LuaRuntime

lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute("local r=...;package.path=r..'/src/?.lua;'..r..'/third_party/dkjson/?.lua;'..package.path",root.as_posix())
lua.execute(r'''
local wind=require('rules.wind_charge')
local status_rules=require('rules.status_effects')
local state=require('storage.state')
local slots=require('rules.container_slots')
local stack={content_id=wind.id,count=1,metadata=state.object()}
local data=require('rules.supply_catalogue').take(slots.empty(),wind.id,'player/hotbar/2')
assert(slots.get(data,'player/hotbar/2').content_id==wind.id)
assert(require('rules.item_catalogue').category(wind.id)=='equipment')
local function v(x,y,z)return {X=x,Y=y,Z=z}end
local zero=v(0,0,0)
local now=0
local callbacks={}
function LoopInGameThreadAfterFrames(n,fn) assert(n==1);local t={};callbacks[t]=fn;return t end
function CancelDelayedAction(id) callbacks[id]=nil end
function StaticFindObject(path)
  if path:find('GameplayStatics') then return {GetTimeSeconds=function()return now end} end
  return path
end
local function actor(id,p,mode)
  local a={id=id,p=p,CharacterMovement={MovementMode=mode},AttributeSetBase={Health={CurrentValue=100}},caps=20}
  a.CapsuleComponent={GetScaledCapsuleHalfHeight=function()return 80 end,GetScaledCapsuleRadius=function()return 32 end}
  function a:IsValid()return true end;function a:GetAddress()return self.id end;function a:GetFullName()return tostring(self.id)end
  function a:GetVelocity()return zero end;function a:K2_GetActorLocation()return self.p end
  function a:IsA()return self.id<10 end
  function a:LaunchCharacter(push,xy,z) assert(not xy and not z);self.launch=push;self.launches=(self.launches or 0)+1 end
  return a
end
local pawn=actor(1,v(0,0,80),3);local direct=actor(2,v(100,0,80),1);local covered=actor(3,v(100,140,80),1)
local wall=actor(11,v(200,0,0),0)
local lib={}
function lib:SphereOverlapActors(p,o,r,types,cl,ignored,found)
  found[1]=direct;found[2]=covered;found[3]=direct
end
function lib:LineTraceSingle(p,a,b) return b.Y>100 end
package.loaded.UEHelpers={GetKismetSystemLibrary=function()return lib end}
package.loaded['host.pbz.appearance']={valid=function(o)return type(o)=='table' end}
package.loaded['host.pbz.build_world']={object_types={1}}
package.loaded['host.pbz.boat_service']={get=function()return nil end}
package.loaded['host.pbz.tnt_service']={get=function()return nil end}
package.loaded['host.pbz.building_service']={get=function()return nil end}
local resets=0;package.loaded['host.pbz.item_interface']={reset_fall_after_teleport=function()resets=resets+1 end}
local statuses={value=status_rules.empty(),mode='free',current=function()return true end}
local commits,accept=0,true
function statuses:projectile_cooldown(record,id,consume)
  if not accept then return false,'stale hand' end
  assert(record.equipment[record.hand].content_id==id and consume==(self.mode=='adventure'))
  self.value=status_rules.start_cooldown(self.value,id);commits=commits+1;return true
end
local binding={actor=pawn,mc_status_service=statuses,is_current=function()return true end}
local origin,dir=v(0,0,160),v(0,0,-1)
local pc={PlayerCameraManager={CameraCachePrivate={POV={Location=origin}}}}
local hits=0
local combat={binding=binding,pc=pc,hits=0,damage={eligible=function(_,target)return target==direct or target==covered end},
  log=function()end,sound=function()return true end,aim=function()return origin,dir end}
function combat.damage:hit(target,amount,id,contact)
  assert(target==direct and contact.kind=='wind_charge' and amount>0 and amount<15);hits=hits+1;return true
end
local surface='ground'
function combat:trace(a,b)
  if surface=='ground' and b.Z<=0 then return true,{ImpactPoint=zero,ImpactNormal=v(0,0,1)},wall end
  if surface=='mob' and b.X>=100 then return true,{ImpactPoint=v(100,0,80),ImpactNormal=v(-1,0,0)},direct end
  return false
end
local service=require('host.pbz.wind_charge').new(combat)
local recycled=0
service.visual={acquire=function()return {actor=wall} end,draw=function()end,release=function()recycled=recycled+1 end,close=function()end}
combat.mace_fx={burst=function(_,effect)assert(effect.wind and effect.small);return 6 end}
local function throw(i,hand)
  return service:throw({hand=hand or 'main',source='1/2/3',action_id=tostring(i),equipment={main=stack,offhand=stack}})
end
assert(throw(1));assert(commits==1 and status_rules.remaining(statuses.value,wind.id)==10)
assert(not throw(2,'offhand'))
now=.09;service:tick();assert(#service.charges==0 and not next(callbacks) and hits==0)
assert(resets==1 and pawn.launch.Z>1000 and direct.launch and not covered.launch and direct.launches==1)
assert(pawn.BeforeFallingLocation.Z==80 and service.report.burst==1 and service.report.last_impact.center.Z==25)
assert(service.report.last_impact.particles==6 and not service.report.last_impact.fx_error)
-- A native transition may rebase the fall at the apex. Falling back to the
-- launch height is protected and a later independent fall has its own origin.
local fall_service={binding=binding,value={totem_cooldown=1},report={}}
local fall=require('host.pbz.native_totem_fall')
pawn.BeforeFallingLocation=v(0,0,900);fall.tick(fall_service);assert(pawn.BeforeFallingLocation.Z==80)
pawn.CharacterMovement.MovementMode=1;fall.tick(fall_service);assert(not binding.mc_wind_lift)
pawn.CharacterMovement.MovementMode=3;pawn.BeforeFallingLocation=v(0,0,700)
fall.tick(fall_service);assert(pawn.BeforeFallingLocation.Z==700)
local function glide_landing(ground,expected)
  local at=v(0,0,ground+1)
  local rider={K2_GetActorLocation=function()return at end,K2_SetActorLocation=function(_,to,sweep,hit)
    assert(sweep);hit.ImpactNormal=v(0,0,1);at=v(0,0,ground) end}
  local glider={binding={actor=rider,mc_wind_lift={z=80}},velocity=v(0,0,-1000),fall_distance=1000,report={sweeps=0},
    stop=function(_,reason,grounded)assert(grounded and reason=='landed') end,
    damage=function(_,amount,kind)assert(amount==expected and kind=='fall')end}
  require('host.pbz.elytra_flight').sweep(glider,.05)
  assert(not glider.binding.mc_wind_lift)
end
glide_landing(80,0);glide_landing(-420,2)
statuses.value=status_rules.advance(statuses.value,10,100);surface='mob';origin=v(0,0,80);dir=v(1,0,0)
now=.6;assert(throw(3,'offhand'));now=.7;service:tick();assert(hits==1 and service.report.last_impact.direct)
assert(#service.charges==0);service:tick();assert(hits==1)
statuses.value=status_rules.advance(statuses.value,10,100);accept=false;assert(not throw(4));assert(#service.charges==0 and not next(callbacks) and commits==2)
accept=true;statuses.mode='adventure';surface='air';now=1.2;assert(throw(5))
local p=service.charges[1];p.position=v(200,0,80);p.time=now;p.velocity=zero
assert(not service:melee(origin,dir,0,300));now=1.46
assert(service:melee(origin,dir,0,300) and p.velocity.X==3000 and not service:melee(origin,dir,0,300))
-- Cross in flight between two samples (neither object's starting point is hit).
p.armed=2;p.time=2;p.position=v(0,50,0);p.velocity=v(0,-1000,0)
assert(not service:arrow(v(-50,0,0),v(50,0,0),v(1000,0,0),2,2.1,.1))
assert(service:arrow(v(-50,0,0),v(50,0,0),v(1000,0,0),2,2.1,nil))
assert(p.velocity.X==3000 and service.report.deflected==2)
assert(wind.intercept(zero,zero,v(5,0,0),6)==0 and not wind.intercept(zero,zero,v(7,0,0),6))
now=13;service:tick();assert(service.report.expired==1 and not next(callbacks))
service:close();assert(service.closed)

-- Use the regular right-button dispatcher, campaign inventory transaction and
-- cooldown snapshot all the way to the projectile, with no disk-backed save.
local items=require('content.items')
local function equipment(id,count)
  if not id then return nil end
  local s={content_id=id,count=count or 1,metadata=state.object()}
  if items.get(id).instance then s.instance_id='test/'..id end
  return s
end
local function button_case(mode,main,off,expected,interact)
  local core=require('storage.player_state').empty()
  local draft=slots.edit(core.containers)
  draft:set('player/hotbar/1',main);draft:set('player/offhand',off);core.containers=draft.data
  local store=require('storage.session_store').new({core=core,loaded=true,generation=0,head={pages={}},definitions=items})
  local inv=require('runtime.inventory_session').new(store,{is_current=function()return true end},'wind-fixture')
  package.loaded['host.pbz.item_interface'].equipment_available=function()return true end
  package.loaded['host.pbz.campaign_inventory']={view=function()return store.core.containers end,current=function()return true end}
  local status=setmetatable({binding=binding,session={store=store,session=inv},mode=mode,value=status_rules.empty()},
    {__index=require('host.pbz.player_status_service')})
  binding.mc_status_service=status;binding.mc_creative=(mode=='creative')
  local flying=require('host.pbz.wind_charge').new(combat)
  flying.visual=service.visual;combat.wind=flying
  local backend={authorize=function()return true end,cancel=function()end,handlers={
    mine=function()return false end,interact=function()return interact or false end,
    use=function(_,record)return require('host.pbz.minecraft_combat').use(combat,record)end}}
  local act=require('runtime.minecraft_actions').new(backend)
  local context={kind='game',weapon_group='mc',allow_actions=true,epoch=2,equipment_revision=1,input_epoch=3,
    mode=mode,main=main,offhand=off,has_arrow=true}
  local function press(kind,seq)
    assert(act:step(now,context,{{kind=kind,seq=seq,source='2/'..context.equipment_revision..'/3',
      owner_epoch=2,equipment_revision=context.equipment_revision,input_epoch=3}}))
  end
  now=now+1;press('use_press',1)
  assert(#flying.charges==(expected and 1 or 0))
  if expected then
    assert(flying.charges[1].hand==expected and act.swing_start==now and store.commits==1 and store.flushes==0)
    local frame=act:presentation(now+.1,context);assert(frame.swing_hand==expected and frame.swing>0)
    local holders=require('presentation.first_person_camera').holders(frame)
    local other=expected=='main' and 'offhand' or 'main'
    assert(holders[expected].position.X>90 and holders[other].position.X==90)
    frame.age=0;frame.stride=0;frame.speed=0;frame.actor_yaw=0;frame.look={Pitch=0,Yaw=0,Roll=0}
    frame.anchor={position=zero,rotation=frame.look}
    local parts={{name='left_arm',pivot=zero},{name='right_arm',pivot=zero}}
    local pose=require('presentation.minecraft_third_person_pose')
    local thrown=pose.solve(parts,frame);frame.swing=0;local resting=pose.solve(parts,frame)
    local right=math.abs(thrown.right_arm.rotation.Pitch-resting.right_arm.rotation.Pitch)
    local left=math.abs(thrown.left_arm.rotation.Pitch-resting.left_arm.rotation.Pitch)
    assert(expected=='main' and right>left or expected=='offhand' and left>right)
    assert(status_rules.remaining(store.core.mc_status,wind.id)==10)
    local address=expected=='main' and 'player/hotbar/1' or 'player/offhand'
    local before=(expected=='main' and main or off).count
    local after=slots.get(store.core.containers,address)
    assert((after and after.count or 0)==before-(mode=='adventure' and 1 or 0))
    now=now+.05;press('use_release',2)
    context.main=equipment(wind.id,1);context.offhand=nil;context.equipment_revision=2
    now=now+.05;press('use_press',3);assert(#flying.charges==1 and store.commits==1)
    if after then
      -- Simulate an equipment change between reading the hand and committing.
      status.value=status_rules.advance(status.value,10,100)
      local stale=require('rules.item_stack').copy(after,after.count+1)
      local ok,why=pcall(status.projectile_cooldown,status,{hand=expected,equipment={[expected]=stale}},wind.id,true)
      assert(not ok and tostring(why):find('status%-held%-stack%-changed') and store.commits==1)
    end
  else assert(store.commits==0 and not store.dirty) end
  flying:close();assert(not next(callbacks))
end
button_case('adventure',equipment(wind.id,2),nil,'main')
button_case('adventure',nil,equipment(wind.id),'offhand')
for _,id in ipairs({'diamond_sword','diamond_pickaxe','mace'}) do
  button_case('free',equipment('pbzmc:'..id),equipment(wind.id),'offhand')
end
button_case('creative',equipment(wind.id),nil,'main')
button_case('free',equipment('pbzmc:bow'),equipment(wind.id),nil)
button_case('free',equipment(wind.id),nil,nil,true)

local mechanism=require('host.pbz.mechanism_service')
local records={{id='lever',content_id='pbzmc:lever',x=10,y=0,z=0,properties={powered=false}},
 {id='lo',content_id='pbzmc:oak_door',x=50,y=0,z=0,properties={half='lower',open=false}},
 {id='hi',content_id='pbzmc:oak_door',x=50,y=0,z=100,properties={half='upper',open=false}},
 {id='wall-lever',content_id='pbzmc:lever',x=100,y=15,z=0,properties={powered=false}},
 {id='iron',content_id='pbzmc:iron_door',x=20,y=0,z=0,properties={open=false}}}
local h={};for i,r in ipairs(records)do h[r.id]={actor=actor(i+20,zero,0)}end
local switches={session={handles=h,visit_nearby=function(_,p,r,fn)for _,rec in ipairs(records)do fn(rec)end end},
 pair=function(_,r)return r.id=='hi' and records[2] or records[3] end,sound=function()end,
 commit=function(_,changes,opts,environment)assert(environment and #changes==3)
  for _,c in ipairs(changes)do assert(c.after.properties.powered or c.after.properties.open)end;return true end}
assert(mechanism.wind_pulse(switches,zero,240,function(a,b)return b.Y==0 end)==3)
-- Exercise each entity service through its public constructor, retaining the
-- real simulation units, passive passengers and unchanged fuse.
package.loaded['host.pbz.campaign_inventory'].ensure=function()return {store={core={}}}end
package.loaded['host.pbz.boat_service']=nil;binding.world_id={name='fixture'}
package.loaded['host.pbz.boat_world']={new=function()return {valid=function()return true end}end}
local boats=require('host.pbz.boat_service').ensure(binding,'',function()end)
local hull={state={x=80,y=0,z=0,vx=0,vy=0,vz=0},resting=true,handle={actor=wall},passengers={direct,covered}}
boats.boats={near=hull}
assert(boats:wind_burst(zero,240,function()return false end)==0 and hull.resting)
assert(boats:wind_burst(zero,240,function()return true end)==1 and hull.state.vx>0 and not hull.resting)
assert(hull.passengers[1]==direct and hull.passengers[2]==covered)
package.loaded['host.pbz.tnt_service']=nil
package.loaded['host.pbz.tnt_damage']={ready=function()return true end,new=function()return {}end}
package.loaded['host.pbz.tnt_effects']={new=function()return {}end}
package.loaded['host.pbz.tnt_sounds']={new=function()return {play=function()end}end}
package.loaded['host.pbz.tnt_world']={new=function()return {destroy=function(_,h)assert(h.actor==wall)end}end}
package.loaded['host.pbz.building_service']={get=function()return {world={}}end}
local tnt=require('host.pbz.tnt_service').ensure(binding,'',function()end)
tnt.fires={near={state={x=50,y=0,z=0},handle={actor=wall}},behind={state={x=50,y=10,z=0},handle={actor=direct}}}
tnt.primed={ready={state={x=50,y=0,z=49,vx=0,vy=0,vz=0,fuse=48},handle={actor=wall}}}
local removed,pushed=tnt:wind_burst(zero,240,function(a,b)return b.Y==0 end)
assert(removed==1 and pushed==1 and tnt.fires.behind and not tnt.fires.near)
assert(tnt.primed.ready.state.vx>0 and tnt.primed.ready.state.fuse==48)
print('PASS: right-click, actual hand transactions, shared cooldown, impact, wind jump, fall protection, cover, deflection, boat, TNT, fires and switches')
''')

if len(sys.argv) == 2:
    lua.execute(r'''
local root=...
local world={};local pawn={GetWorld=function()return world end}
local spawns,materials,uploads=0,0,0
function world:SpawnActor()
  spawns=spawns+1
  local a={alive=true,id=spawns};function a:IsValid()return self.alive end
  function a:GetAddress()return self.id end;function a:GetFullName()return 'wind/'..self.id end
  function a:K2_DestroyActor()self.alive=false end
  function a:AddComponentByClass()
    local c={};function c:SetHiddenInGame(v)self.hidden=v end
    function c:SetCastShadow(v)assert(not v)end;function c:SetCollisionEnabled(v)assert(v==0)end
    function c:SetMaterial(i,v)assert(i==0 and v)end
    function c:CreateMeshSection_LinearColor(i,positions,indices,normals,uv)
      assert(#indices==#positions*3 and #positions==#uv and #uv==#normals)
      uploads=uploads+1;self.vertices=#positions;self.base=uv[1].X
    end
    function c:K2_SetWorldLocationAndRotation(p,r)self.yaw=r.Yaw end
    function c:UpdateMeshSection_LinearColor(i,pos,normals,uv)self.u=uv[1].X end
    return c
  end
  return a
end
package.loaded['host.pbz.translucent_blocks']={new=function(_,_,desc)
  materials=materials+1;assert(desc.path=='wind_charge.png' and desc.bytes>0);return {},{} end}
local visual=require('host.pbz.wind_visuals').new({actor=pawn,item_models_root=root..'/item-models'})
local p={X=0,Y=0,Z=0}
local handle=visual:acquire(p);visual:draw(handle,p,0,p)
assert(handle.parts.core.hidden and handle.parts.shell.hidden)
visual:draw(handle,p,.1,p)
local core,shell=handle.parts.core,handle.parts.shell
assert(core.vertices==24 and shell.vertices==48 and not core.hidden and not shell.hidden)
assert(core.yaw==-32 and shell.yaw==32 and math.abs(core.u-core.base-.06)<.00001)
visual:release(handle);assert(visual:acquire(p)==handle and core.hidden and uploads==2 and materials==1)
visual:release(handle);handle.actor:K2_DestroyActor()
local fresh=visual:acquire(p);assert(fresh~=handle and not visual.all[handle] and uploads==4 and materials==1)
visual:close();assert(not next(visual.all) and not fresh.actor:IsValid())
print('PASS: converted core, shell, original UV scroll, visibility, reuse and cleanup')

-- Run the real effect module, asset preparation, scheduler and mesh writer.
-- Only the UE calls below are stand-ins. A require returning true must fail.
local moment,scheduled,texture_reads=0,nil,0
local texture={}
local dyn={SetTextureParameterValue=function(_,name,value)assert(name=='SpriteTexture' and value==texture)end}
function FName(s)return s end
function StaticFindObject(path)
  if path:find('GameplayStatics') then return {GetTimeSeconds=function()return moment end} end
  if path:find(':ImportFileAsTexture2D') then return function(_,_,path)
    assert(io.open(path,'rb')):close();texture_reads=texture_reads+1;return texture end end
  if path:find('Default__KismetMaterialLibrary') then return {CreateDynamicMaterialInstance=function()return dyn end} end
  return path
end
function LoopInGameThreadAfterFrames(frames,fn)assert(frames==1 and not scheduled);scheduled=fn;return 31 end
function CancelDelayedAction(id)assert(id==31);scheduled=nil end
local bind={actor=pawn,item_models_root=root..'/item-models',is_current=function()return true end,log=error}
local owner={binding=bind,pc={PlayerCameraManager={CameraCachePrivate={POV={Rotation={Pitch=0,Yaw=0,Roll=0}}}}}}
local sprites=require('host.pbz.sprite_particles')
local rule=require('rules.mace_particles')
local function batches(small,expected,per_tick)
  local emitted=rule.emit({wind=p,small=small},0,13)
  assert(#emitted==expected)
  for i,particle in ipairs(emitted) do
    assert(math.abs(particle.start-math.floor((i-1)/3)*per_tick/20)<1e-7)
    assert(particle.life_ticks>=12 and particle.life_ticks<=15)
  end
end
batches(true,6,3);batches(false,24,1)
local gust=rule.emit({wind=p,small=true},0,13)[1]
local right,up={X=0,Y=1,Z=0},{X=0,Y=0,Z=1}
local last=rule.mesh({gust},(gust.life_ticks+.5)/20,right,up,p,13)
assert(last.used==1 and last.uv[1].X==12/13)
assert(rule.mesh({gust},gust.life,right,up,p,13,last).used==0)
assert(sprites.impact(owner,{wind=p,small=true})==6)
local fx=owner.mace_fx
local first_actor=fx.actor;local first_buffer=fx.buffer
local retired=scheduled
assert(scheduled and fx.buffer.used==3 and fx.sections==1 and not fx.mesh.hidden)
local v,uv=fx.buffer.positions[1],fx.buffer.uv[1]
local xyz={v.X,v.Y,v.Z};local u=uv.X
moment=.151;scheduled()
assert(fx.buffer==first_buffer and fx.buffer.used==6 and fx.sections==1 and fx.updates==1)
assert(xyz[1]==v.X and xyz[2]==v.Y and xyz[3]==v.Z and uv.X>u)
moment=2;scheduled();assert(not scheduled and fx.mesh.hidden)
assert(sprites.impact(owner,{wind=p})==24 and fx.actor==first_actor and fx.buffer.used==3)
local count_before=fx.updates;retired();assert(fx.updates==count_before and scheduled~=retired)
for i=1,30 do sprites.impact(owner,{wind=p,small=i%2==0}) end
moment=2.41;scheduled()
assert(#fx.particles==96 and fx.buffer.capacity==96 and fx.buffer.used==96)
local sections=fx.sections
for i=1,8 do moment=moment+.0125;scheduled() end
assert(fx.sections==sections and texture_reads==1 and fx.peak==96)
moment=5;scheduled();assert(not scheduled and not fx.visible and fx.mesh.hidden)
assert(sprites.impact(owner,{wind=p,small=true})==6);local cancelled=scheduled
fx:close();cancelled();assert(not scheduled and not first_actor:IsValid())
local portal=require('host.pbz.portal_particles').new(bind,owner.pc)
assert(portal:burst(p)==32 and portal.buffer.used==32 and texture_reads==2)
moment=8;scheduled();assert(not scheduled and portal.mesh.hidden);portal:close()
print('PASS: real original-atlas gust and portal batches, timed 6/24 sprites, stable mesh, 96 cap and idle shutdown')
''', Path(sys.argv[1]).resolve().as_posix())
