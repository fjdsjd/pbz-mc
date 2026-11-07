-- Transient command presentation. No combat dispatch, inventory writes, native
-- animation montages, or persistent state. The service owns the native scope.
local json=require('dkjson')
local syntax=require('rules.commands.syntax')
local quads=require('presentation.particle_quads')
local M={};M.__index=M
local serial=0
local particle_limit=96
local assets={['minecraft:crit']='critical_hit',['minecraft:enchanted_hit']='critical_hit',
 ['minecraft:portal']='portal',['minecraft:gust']='mace',['minecraft:small_gust']='mace'}
local function finite(n)return type(n)=='number'and n==n and math.abs(n)<math.huge end
local function clamp(n,a,b)return math.max(a,math.min(b,n))end
local function copy(t)local out={};for k,v in pairs(t or {})do out[k]=v end;return out end
local function read(path,optional)
 local f=io.open(path,'rb');if not f then assert(optional,'command-resource-missing:'..path);return end
 local raw=f:read('a');f:close();local result,_,why=json.decode(raw);assert(result,why);return result
end
local function sound_catalogue(directory)
 local out={}
 local function add(name,variants)
  name=syntax.id(name);assert(type(variants)=='table'and #variants>0,'command-sound-empty:'..name)
  local event={variants={},weight=0}
  for _,v in ipairs(variants)do
   assert(type(v.clip)=='string'and v.clip:match('^[a-z0-9_]+$')and finite(v.volume)and v.volume>=0
    and finite(v.pitch)and v.pitch>0 and finite(v.weight)and v.weight>0 and v.weight%1==0,'command-sound-variant:'..name)
   event.weight=event.weight+v.weight;local sample=copy(v);sample.upper=event.weight;event.variants[#event.variants+1]=sample
  end
  out[name]=event
 end
 for _,path in ipairs({'sounds/manifest.json','building-blocks/sounds/manifest.json',
  'mechanism-blocks/sounds/manifest.json','tnt/sounds/manifest.json','construction/sounds/manifest.json'})do
  local data=read(directory..'/'..path,path~='sounds/manifest.json')
  if data then
   for key,name in pairs(data.event_names or {})do if data.variants and data.variants[key]then add(name,data.variants[key])end end
   for _,group in pairs(data.groups or {})do for _,event in pairs(group.events or {})do add(event.event,event.variants)end end
  end
 end
 return out
end
function M.new(binding,directory,options)
 options=options or {};assert(type(options.native_context)=='function','command-presentation-native-context-required')
 assert(options.entities,'command-presentation-entities-required');serial=serial+1
 return setmetatable({binding=binding,directory=directory,options=options,entities=options.entities,
  owner='command-presentation-'..serial,sounds=options.sounds or sound_catalogue(directory),voices={},renderers={},swings={}},M)
end
function M:_native(allow_stale)
 -- This predicate must reject a rule worker before even IsInGameThread is
 -- called: UE4SS's unregistered coroutine cannot invoke any native function.
 assert(self.options.native_context()==true,'command-presentation-native-context-required')
 assert(type(IsInGameThread)=='function'and IsInGameThread(),'command-presentation-game-thread-required')
 if not allow_stale then assert(not self.closed and self.binding:is_current(),'command-presentation-owner-stale')end
end
function M:_time()
 local now=self.options.clock and self.options.clock()or self.entities:_time()
 assert(finite(now),'command-presentation-clock');return now
end
function M:_controller()
 return self.options.controller and self.options.controller()or require('host.pbz.local_player').controller()
end
function M:_audio(request)
 local fn=self.options.audio or PBZMC_BlockSound;assert(type(fn)=='function','command-audio-interface-unavailable')
 local raw,why=fn(json.encode(request));assert(raw,why or 'command-audio-rejected')
 local reply=type(raw)=='table'and raw or assert(json.decode(raw),'command-audio-response')
 assert(reply.protocol==2 and reply.ready==true,'command-audio-interface-version-2-required');return reply
end
function M:_players(targets)
 assert(type(targets)=='table'and #targets>0,'no-players-found')
 for _,e in ipairs(targets)do
  local h=self.entities:_resolve(e)
  assert(h.player and h.actor==self.binding.actor,'command-remote-player-audio-unavailable')
 end
 return targets
end
local function distance(a,b)local x,y,z=a.x-b.x,a.y-b.y,a.z-b.z;return math.sqrt(x*x+y*y+z*z),x,y,z end
function M:_mix(voice,pov)
 local p=voice.position;local x,y,z=p.X-pov.Location.X,p.Y-pov.Location.Y,p.Z-pov.Location.Z
 local d=math.sqrt(x*x+y*y+z*z);local yaw=math.rad(pov.Rotation.Yaw)
 return clamp(voice.volume,0,1)*math.max(0,1-d/voice.range),
  d>1e-6 and clamp((-math.sin(yaw)*x+math.cos(yaw)*y)/d,-1,1)or 0
end
function M:play_sound(request)
 self:_native();self:_players(request.targets)
 local event=assert(self.sounds[request.sound],'command-sound-resource-unavailable:'..tostring(request.sound))
 assert(#request.targets==1,'command-audio-multiple-local-listeners-unsupported')
 -- Probe the protocol without playing a legacy one-shot on an older bridge.
 self:_audio({op='status',owner=self.owner})
 local target=request.targets[1];local d,x,y,z=distance(request.pos,target.pos)
 local pos,volume=request.pos,request.volume
 if d>math.max(1,volume)*16 then
  assert(request.min_volume>0,'playsound-no-player-in-range')
  pos={x=target.pos.x+x/d*2,y=target.pos.y+y/d*2,z=target.pos.z+z/d*2};volume=request.min_volume
 end
 local pick=(self.options.random or math.random)()*event.weight;local sample=event.variants[#event.variants]
 for _,v in ipairs(event.variants)do if pick<v.upper then sample=v;break end end
 local voice={position=self.entities:_ue(pos),volume=volume*sample.volume,range=math.max(1,volume*sample.volume)*1600,
  pitch=clamp(request.pitch*sample.pitch,.5,2),sound=request.sound,source=request.source}
 local pov=self:_controller().PlayerCameraManager.CameraCachePrivate.POV
 local gain,pan=self:_mix(voice,pov)
 local reply=self:_audio({op='play',clip=sample.clip,gain=gain,pitch=voice.pitch,pan=pan,
  sound_event=request.sound,source=request.source,owner=self.owner})
 assert(type(reply.id)=='number','command-audio-voice-required');voice.id=reply.id
 self.voices[voice.id]=voice
 return 1,'已播放 '..request.sound
end
function M:stop_sound(request)
 self:_native();self:_players(request.targets)
 if request.sound then assert(self.sounds[request.sound],'command-sound-resource-unavailable:'..request.sound)end
 local reply=self:_audio({op='stop',sound_event=request.sound,source=request.source})
 for id,v in pairs(self.voices)do
  if (not request.sound or request.sound==v.sound)and (not request.source or request.source==v.source)then self.voices[id]=nil end
 end
 -- Vanilla counts recipients, including a recipient with no matching voice.
 return #request.targets,'已停止声音（'..tostring(reply.stopped or 0)..' 个声部）'
end
local function linear(v)return v<=.04045 and v/12.92 or ((v+.055)/1.055)^2.4 end
local function gaussian(random)return math.sqrt(-2*math.log(math.max(1e-12,random())))*math.cos(2*math.pi*random())end
local function particle_batch(request,point,now,random)
 local out={};local n=math.max(1,request.count)
 for _=1,n do
  local delta=request.delta;local dx,dy,dz=0,0,0;local vx,vy,vz
  if request.count==0 then vx=delta.x*request.speed;vy=delta.y*request.speed;vz=delta.z*request.speed
  else
   dx=gaussian(random)*delta.x;dy=gaussian(random)*delta.y;dz=gaussian(random)*delta.z
   vx=gaussian(random)*request.speed;vy=gaussian(random)*request.speed;vz=gaussian(random)*request.speed
  end
  local p={x=point.X+dx*100,y=point.Y-dz*100,z=point.Z+dy*100,
   vx=vx*2000,vy=-vz*2000,vz=vy*2000,start=now,kind=request.name,ticks=0}
  if request.name=='minecraft:portal'then
   local shade=random()*.6+.4;p.r=shade*.9;p.g=shade*.3;p.b=shade
   p.life=(40+math.floor(random()*10))/20;p.size=10*(random()*.2+.5);p.frame=math.floor(random()*8)
   -- Portal's motion provider consumes the supplied per-tick displacement.
   p.vx,p.vy,p.vz=vx*100,-vz*100,vy*100
  elseif request.name=='minecraft:gust'or request.name=='minecraft:small_gust'then
   p.life_ticks=12+math.floor(random()*4);p.life=(p.life_ticks+1)/20
   p.size=request.name=='minecraft:small_gust'and 50 or 100
  else
   local shade=random()*.3+.6;p.r=shade;p.g=shade;p.b=shade
   if request.name=='minecraft:enchanted_hit'then p.r=p.r*.3;p.g=p.g*.8 end
   p.life=math.max(1,math.floor(6/(random()*.8+.6)))/20;p.size=15*(random()*.5+.5)
  end
  out[#out+1]=p
 end
 return out
end
local particle_rules={interval=1/20,emit=function(effect)return effect.batch end}
function particle_rules.mesh(particles,now,right,up,origin,frames,buffer)
 buffer=buffer or quads.new(#particles)
 for i,p in ipairs(particles)do
  local age=math.max(0,now-p.start);local x,y,z=p.x,p.y,p.z;local size=p.size;local u0,v0,u1,v1=0,0,1,1;local color
  if p.life_ticks then
   local tile=1+(math.min(p.life_ticks,math.floor(age*20+1e-6))*(frames-2))//p.life_ticks
   u0,u1=tile/frames,(tile+1)/frames
  elseif p.kind=='minecraft:portal'then
   local f=clamp(age/p.life,0,1);local trajectory=1+f-2*f*f
   x=x+p.vx*trajectory;y=y+p.vy*trajectory;z=z+p.vz*trajectory+100*(1-f)
   size=size*(1-(1-f)^2);u0,u1=p.frame/frames,(p.frame+1)/frames
   color={R=linear(p.r),G=linear(p.g),B=linear(p.b),A=1}
  else
   local ticks=math.floor(age*20+1e-6)
   while p.ticks<ticks do
    p.ticks=p.ticks+1;p.vz=p.vz-40;p.x=p.x+p.vx*.05;p.y=p.y+p.vy*.05;p.z=p.z+p.vz*.05
    p.vx=p.vx*.7;p.vy=p.vy*.7;p.vz=p.vz*.7;p.g=p.g*.96;p.b=p.b*.9
   end
   x,y,z=p.x,p.y,p.z;color={R=linear(p.r),G=linear(p.g),B=linear(p.b),A=1}
  end
  quads.write(buffer,i,x-origin.X,y-origin.Y,z-origin.Z,right,up,size,u0,v0,u1,v1,color)
 end
 return quads.finish(buffer,#particles)
end
function M:_renderer(asset)
 if self.renderers[asset]then return self.renderers[asset]end
 local renderer
 if self.options.renderer then renderer=self.options.renderer(asset,particle_rules)
 else
  renderer=require('host.pbz.sprite_particles').new(self.binding,self:_controller(),asset,particle_rules)
  if asset=='critical_hit'then
   -- Reuse the pinned 8x8 critical sprite loader; the common renderer owns the
   -- bounded queue/timer. No private replacement image is generated.
   local critical=require('host.pbz.critical_particles')
   renderer.sprite=critical.new(self.binding,renderer.pc).sprite
   renderer.prepare=function(r)
    critical.prepare(r);r.asset={frames=1};r.game=StaticFindObject('/Script/Engine.Default__GameplayStatics')
    r.mesh:SetHiddenInGame(true,false)
   end
  end
 end
 self.renderers[asset]=renderer;return renderer
end
function M:particle(request)
 self:_native();self:_players(request.targets)
 local asset=assert(assets[request.name],'command-particle-resource-unavailable:'..tostring(request.name))
 assert(not request.options or next(request.options)==nil,'command-particle-options-unsupported:'..request.name)
 local n=math.max(1,request.count);assert(n<=particle_limit,'command-particle-budget-exceeded:96')
 assert(request.speed<=1000 and math.abs(request.delta.x)<=1000 and math.abs(request.delta.y)<=1000
  and math.abs(request.delta.z)<=1000,'command-particle-motion-budget-exceeded')
 local recipients=0;local range=request.force and 512 or 32
 for _,target in ipairs(request.targets)do if distance(target.pos,request.pos)<=range then recipients=recipients+1 end end
 assert(recipients>0,'particle-no-viewer-in-range')
 local now=self:_time();local active=0
 for _,r in pairs(self.renderers)do
  local keep=0
  for _,p in ipairs(r.particles)do if now-p.start<p.life then keep=keep+1;r.particles[keep]=p end end
  for i=#r.particles,keep+1,-1 do r.particles[i]=nil end
  active=active+keep
 end
 assert(active+n<=particle_limit,'command-particle-budget-exceeded:96')
 local point=self.entities:_ue(request.pos);local batch=particle_batch(request,point,now,self.options.random or math.random)
 local renderer=self:_renderer(asset)
 local count=renderer:burst({X=point.X,Y=point.Y,Z=point.Z,batch=batch})
 assert(count==n,'command-particle-renderer-rejected')
 return recipients,'已生成 '..n..' 个 '..request.name..' 粒子'
end
function M:swing(request)
 self:_native();local admitted={};local now=self:_time()
 for _,e in ipairs(request.targets)do
  local h=self.entities:_resolve(e)
  if h.kind~='boat'then
   assert(h.player or self.options.swing_target,'command-swing-pose-unavailable:'..tostring(e.type))
   local record={entity_id=e.id,hand=request.hand,animation=request.animation,start=now,
    duration=request.duration/20,duration_ticks=request.duration}
   if h.player and self.options.player_swing_available then
    assert(self.options.player_swing_available(h,record)==true,'command-swing-native-weapon-pose-unavailable')
   end
   if not h.player then
    assert(self.options.swing_target(h,record,true)==true,'command-swing-pose-unavailable:'..tostring(e.type))
   end
   admitted[#admitted+1]={handle=h,record=record}
  end
 end
 assert(#admitted>0,'swing-no-living-entities')
 for _,v in ipairs(admitted)do
  local old=self.swings[v.record.entity_id];local ticks=old and math.floor((now-old.start)*20+1e-6)
  -- Vanilla reports the living target even when its early swing cannot restart.
  if not old or ticks<=0 or ticks>math.floor(old.duration_ticks/2)then
   if not v.handle.player then assert(self.options.swing_target(v.handle,v.record,false)==true,'command-swing-pose-rejected')end
   if old then old.cancelled=true end
   self.swings[v.record.entity_id]=v.record
  end
  if v.handle.player then self.player_id=v.record.entity_id end
 end
 return #admitted,'已播放挥手动画'
end
-- Pure presentation hooks. Call after composing the ordinary action frame and
-- before either camera/pose solver. They never query a native object or time.
function M.swing_progress(record,now)
 if not record or record.cancelled or now<record.start or now>=record.start+record.duration then return nil end
 return clamp((now-record.start)/record.duration,0,1)
end
function M:apply_frame(frame,now,entity_id)
 assert(finite(now),'command-swing-clock-required')
 local s=self.swings[entity_id or self.player_id];local progress=M.swing_progress(s,now);if not progress then return frame end
 local out=copy(frame)
 out.command_swing={animation=s.animation,progress=progress,hand=s.hand}
 out.swing=s.animation=='whack'and progress or 0;out.swing_hand=s.hand=='offhand'and 'offhand'or 'main'
 out.bow_charge=0;out.trident_charge=0;out.spear_charge=0;out.spear_jab=0;out.eating=0;out.blocking=false
 return out
end
function M.first_person_holders(holders,frame)
 local s=frame and frame.command_swing;if not s or s.animation~='stab'then return holders end
 local out=copy(holders);local hand=s.hand=='offhand'and 'offhand'or 'main';local old=assert(holders[hand])
 -- 26.3 SpearAnimations.firstPersonAttack uses the same .05/.2/.4 phase
 -- boundaries as the existing pure spear jab. The animation is item-agnostic.
 local sign=hand=='offhand'and -1 or 1;local side=math.abs(old.position.Y)
 local pose=require('presentation.minecraft_spear_animation').first_person(nil,0,clamp(s.progress,0,1),10,side)
 pose.position.X=old.position.X+pose.position.X-90;pose.position.Y=old.position.Y+sign*(pose.position.Y-side)
 pose.position.Z=old.position.Z+pose.position.Z+48
 pose.rotation.Yaw=pose.rotation.Yaw*sign;pose.rotation.Roll=pose.rotation.Roll*sign
 out[hand]=pose
 return out
end
function M.first_person_arm(pose,camera,left,frame)
 local s=frame and frame.command_swing
 if not s or s.animation~='stab'or (s.hand=='offhand')~=left then return pose end
 local side=camera.arm_span or 90*math.tan(math.rad(103)/2)/(16/9)*(16/10)*.68;local sign=left and -1 or 1
 local rest={position={X=90,Y=side*sign,Z=-48},rotation={Pitch=0,Yaw=0,Roll=0}}
 local holders={main=rest,offhand=rest}
 local motion=M.first_person_holders(holders,frame)[left and 'offhand'or 'main']
 return require('presentation.rigid_transform').compose(camera,{
  position={X=70+motion.position.X-90,Y=motion.position.Y,Z=-42+motion.position.Z+48},
  rotation={Pitch=65+motion.rotation.Pitch,Yaw=(left and 8 or -8)+motion.rotation.Yaw,Roll=motion.rotation.Roll}})
end
function M.third_person_pose(poses,parts,frame)
 local s=frame and frame.command_swing;if not s or s.animation~='stab'then return poses end
 local rigid=require('presentation.rigid_transform');local out=copy(poses)
 local easing=require('presentation.minecraft_spear_animation');local t=clamp(s.progress,0,1)
 local a=easing.in_out_sine(easing.progress(t,0,.05));local b=easing.progress(t,.05,.2)^2
 local c=easing.in_out_expo(easing.progress(t,.4,1))
 local prefix=s.hand=='offhand'and 'left_'or 'right_';local pitch=-(90*a-120*b+30*c)
 for _,part in ipairs(parts)do
  if part.name==prefix..'arm'or part.name==prefix..'sleeve'then
   local old=poses[part.name]
   if old then out[part.name]=rigid.compose(old,{position={X=0,Y=0,Z=0},rotation={Pitch=pitch,Yaw=0,Roll=0}})end
  end
 end
 return out
end
function M:tick(now)
 self:_native(true);if self.closed then return end
 if not self.binding:is_current()then return self:close()end
 now=now or self:_time();assert(finite(now),'command-presentation-clock')
 for id,s in pairs(self.swings)do if now>=s.start+s.duration or now<s.start then s.cancelled=true;self.swings[id]=nil end end
 if not next(self.voices)or self.next_audio and now<self.next_audio then return end
 self.next_audio=now+.05
 local pov=self:_controller().PlayerCameraManager.CameraCachePrivate.POV
 for id,v in pairs(self.voices)do
  local gain,pan=self:_mix(v,pov)
  local reply=self:_audio({op='update',id=id,owner=self.owner,gain=gain,pan=pan,pitch=v.pitch})
  if not reply.active then self.voices[id]=nil end
 end
end
function M:close()
 self:_native(true);if self.closed then return true end
 local failures={}
 if next(self.voices)then
  local ok,why=pcall(self._audio,self,{op='stop',owner=self.owner})
  if ok then self.voices={}else failures[#failures+1]=tostring(why)end
 end
 for asset,r in pairs(self.renderers)do
  local ok,why=pcall(r.close,r)
  if ok then self.renderers[asset]=nil else failures[#failures+1]=tostring(why)end
 end
 for _,s in pairs(self.swings)do s.cancelled=true end
 self.swings={};self.closed=#failures==0
 assert(#failures==0,table.concat(failures,'; '));return true
end
return M
