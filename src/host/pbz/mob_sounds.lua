-- Vanilla events and weights are resolved at asset build time. Playback has a
-- shared, finite voice budget; inaudible events are discarded, never queued.
local json=require('dkjson')
local M={};M.__index=M
local cached_root,cached
local generation=0
local function clamp(n,a,b)return math.max(a,math.min(b,n))end
function M.new(binding,options)
  options=options or {}
  local root=binding.item_models_root..'/../mob-sounds'
  local data=options.manifest
  if not data then
    if cached_root~=root then
      local f=assert(io.open(root..'/manifest.json','rb'));local raw=f:read('a');f:close()
      cached=assert(json.decode(raw));cached_root=root
    end
    data=cached
  end
  local clips={};for _,c in ipairs(data.clips)do clips[c.name]=c end
  generation=generation+1
  return setmetatable({binding=binding,data=data,clips=clips,voices={},options=options,
    owner='mobs:'..generation,report={played=0,culled=0,limited=0}},M)
end
function M:play(m,event,now,listener)
  local species=self.data.species[m.def.name]
  local action=species and species.events[event]
  if not action or #action.variants==0 then return false end
  local random=self.options.random or math.random
  listener=listener or self.listener
  if not listener then return false end
  local p=m.position;local x,y,z=p.X-listener.X,p.Y-listener.Y,p.Z-listener.Z
  local distance=math.sqrt(x*x+y*y+z*z)
  if distance>=1600 then self.report.culled=self.report.culled+1;return false end
  local ambient=event=='ambient' or event=='ambient_water' or event=='step'
  local voices,count={},0
  for _,v in ipairs(self.voices)do
    if now<v.until_time then voices[#voices+1]=v;if v.ambient then count=count+1 end end
  end
  self.voices=voices
  if #voices>=6 or ambient and count>=2 then self.report.limited=self.report.limited+1;return false end
  m.sound_times=m.sound_times or {}
  if now<(m.sound_times[event] or 0)then return false end
  local weight=0;for _,v in ipairs(action.variants)do weight=weight+v.weight end
  local pick=random()*weight;local selected=action.variants[#action.variants]
  for _,v in ipairs(action.variants)do pick=pick-v.weight;if pick<0 then selected=v;break end end
  -- LivingEntity.getVoicePitch: adult voice = 1 + (r1-r2)*0.2.
  local pitch=clamp(selected.pitch*(1+(random()-random())*.2),.25,2)
  local yaw=math.rad(self.yaw or 0)
  local request={clip=selected.clip,gain=clamp(selected.volume*(1-distance/1600)*(event=='step' and .35 or 1),0,1),
    pitch=pitch,pan=distance>1 and clamp((-math.sin(yaw)*x+math.cos(yaw)*y)/distance,-1,1)or 0,
    sound_event='minecraft:'..action.event,source=m.def.attack=='passive' and 'neutral' or 'hostile',owner=self.owner}
  local fn=self.options.audio or PBZMC_BlockSound
  local ok,reply,why=pcall(fn,json.encode(request))
  if not ok or not reply then self.report.error=tostring(why or reply);return false end
  local clip=assert(self.clips[selected.clip])
  voices[#voices+1]={until_time=now+clip.duration/pitch+.03,ambient=ambient}
  m.sound_times[event]=now+(event=='step'and .3 or event=='hurt'and .15 or .1)
  self.report.played=self.report.played+1;self.report.last_event=action.event
  return true
end
function M:tick(m,now,listener)
  self.listener=listener
  local species=self.data.species[m.def.name]
  if not species then return end
  local closed=false
  if m.def.name=='shulker'then
    local _,s=require('rules.shulker_pose').update(m,now)
    closed=s.raw==0
    if s.revision~=(m.shulker_sound_revision or 0)then
      m.shulker_sound_revision=s.revision;self:play(m,s.event,now,listener)
    end
  end
  local random=self.options.random or math.random
  if not m.next_voice then m.next_voice=now+random()*species.ambient_range end
  if now>=m.next_voice then
    m.next_voice=now+species.ambient_delay+random()*species.ambient_range
    if not closed then self:play(m,m.swimming and species.events.ambient_water and 'ambient_water' or 'ambient',now,listener)end
  end
  local prior=m.sound_position;local p=m.position
  if prior then
    local d=math.sqrt((p.X-prior.X)^2+(p.Y-prior.Y)^2)
    if d<200 then m.sound_distance=(m.sound_distance or 0)+d end
    if (m.sound_distance or 0)>=110 and m.move.MovementMode==1 then
      m.sound_distance=0;self:play(m,'step',now,listener)
    end
  end
  m.sound_position={X=p.X,Y=p.Y,Z=p.Z}
end
function M:close()
  pcall(self.options.audio or PBZMC_BlockSound,json.encode({op='stop',owner=self.owner}))
  self.voices={}
end
return M
