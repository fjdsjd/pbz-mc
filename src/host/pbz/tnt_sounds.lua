-- Bounded immediate playback over the shared native 16-voice bank. Nothing is
-- queued: nearby-in-time duplicates merge, and stale requests are discarded.
local json=require('dkjson')
local M={};M.__index=M
local catalogues={}
local shared={voices={},time=0,serial=0,peak=0}
local policy={
 fuse={window=.18,voices=1},fire={window=.8,voices=1},flint={window=.12,voices=1},
 extinguish={window=.12,voices=1},explosion={window=.08,voices=6},
}
local TOTAL_LIMIT,SOFT_LIMIT,TAIL=8,2,.08
local function finite(n)return type(n)=='number' and n==n and math.abs(n)<math.huge end
local function copy(t)local r={};for k,v in pairs(t or {})do r[k]=v end;return r end
local function increment(t,k)t[k]=(t[k]or 0)+1 end
local function prune(ledger,now)
 for i=#ledger.voices,1,-1 do if ledger.voices[i].finish<=now then table.remove(ledger.voices,i)end end
end
local function host_clock(pc)
 assert(pc and pc:IsValid(),'tnt-audio-no-controller')
 local world=pc:GetWorld();assert(world and world:IsValid(),'tnt-audio-no-world')
 local time=StaticFindObject('/Script/Engine.Default__GameplayStatics'):GetRealTimeSeconds(pc)
 return time,tostring(world:GetAddress())..':'..world:GetFullName()
end
local function now(self,pc)
 local ok,raw,epoch=pcall(self.clock or host_clock,pc)
 if not ok or not finite(raw) or raw<0 then return nil end
 epoch=tostring(epoch or 'injected-clock')
 local ledger=self.ledger;local reset=ledger.epoch~=epoch or (ledger.last_raw and raw<ledger.last_raw)
 if ledger.last_raw==nil then ledger.time=raw
 elseif not reset then ledger.time=ledger.time+raw-ledger.last_raw end
 -- World clocks restart after travel. Keep only numerical outstanding PCM
 -- reservations until their remaining duration elapses in the new clock.
 -- Unknown loading time is conservative; it never grants fresh voice slots.
 ledger.last_raw=raw;ledger.epoch=epoch
 if reset then ledger.native_count=nil;ledger.native_at=nil end
 if reset or self.epoch~=epoch then self.last_events={};self.epoch=epoch end
 prune(ledger,ledger.time);return ledger.time
end
local function reject(self,kind,reason,merged)
 if merged then self.merged=self.merged+1;increment(self.merged_counts,kind)
 else self.dropped=self.dropped+1;increment(self.dropped_counts,kind)end
 increment(self.drop_reasons,reason);self.last_drop={kind=kind,reason=reason}
 return false,reason
end
local function snapshot(self)
 local kinds,active,soft={},0,0
 for _,v in ipairs(self.ledger.voices)do
  active=active+1;increment(kinds,v.kind);if v.kind~='explosion'then soft=soft+1 end
 end
 return active,soft,kinds
end
function M.new(root,options)
 options=options or {};local manifest=catalogues[root]
 if not manifest then
  local f=assert(io.open(root..'/sounds/manifest.json','rb'));local raw=f:read('a');f:close()
  manifest=assert(json.decode(raw))
  assert(manifest.schema==1 and manifest.version=='1.21.1' and manifest.format=='s16le'
   and manifest.channels==2 and manifest.sample_rate==44100,'tnt-audio-format')
  manifest.durations={}
  for _,clip in ipairs(manifest.clips)do
   assert(finite(clip.bytes) and clip.bytes>0 and clip.bytes%4==0,'tnt-audio-clip-length')
   manifest.durations[clip.name]=clip.bytes/(manifest.channels*2*manifest.sample_rate)
  end
  for kind,variants in pairs(manifest.variants)do
   assert(policy[kind] and #variants>0,'tnt-audio-event')
   for _,v in ipairs(variants)do assert(manifest.durations[v.clip],'tnt-audio-unknown-clip')end
  end
  catalogues[root]=manifest
 end
 local previous=options.previous
 local ledger=previous and previous.ledger or shared
 if previous and previous.close then previous:close()end
 ledger.serial=ledger.serial+1
 return setmetatable({events=manifest.variants,durations=manifest.durations,root=root,
  ledger=ledger,owner=ledger.serial,clock=options.clock,last_events={},
  counts=copy(previous and previous.counts),played=previous and previous.played or 0,
  requested=previous and previous.requested or 0,merged=previous and previous.merged or 0,
  dropped=previous and previous.dropped or 0,native_failures=previous and previous.native_failures or 0,
  merged_counts=copy(previous and previous.merged_counts),dropped_counts=copy(previous and previous.dropped_counts),
  drop_reasons=copy(previous and previous.drop_reasons)},M)
end
function M:play(kind,p)
 self.requested=self.requested+1
 if self.closed then return reject(self,kind,'closed')end
 local rules=policy[kind];local choices=self.events[kind]
 if not rules or not choices or #choices==0 then return reject(self,tostring(kind),'unknown-event')end
 if not p or not finite(p.x) or not finite(p.y) or not finite(p.z)then return reject(self,kind,'invalid-position')end
 local pc=require('host.pbz.local_player').controller();local stamp=now(self,pc)
 if not stamp then return reject(self,kind,'clock-unavailable')end
 local previous=self.last_events[kind]
 if previous and stamp-previous<rules.window then return reject(self,kind,'coalesced',true)end
 local ledger=self.ledger;local total,soft,kinds=snapshot(self)
 local important=kind=='explosion'
 if total>=TOTAL_LIMIT or (kinds[kind]or 0)>=rules.voices or (not important and soft>=SOFT_LIMIT)then
  return reject(self,kind,important and 'explosion-budget'or 'background-budget')
 end
 if stamp<(important and ledger.explosion_retry or ledger.soft_retry or 0)then return reject(self,kind,'native-backoff')end
 if not important and ledger.native_count and ledger.native_count>=12 and stamp-ledger.native_at<.35 then
  return reject(self,kind,'native-reserve')
 end
 if not pc or not pc:IsValid()then return reject(self,kind,'controller-unavailable')end
 local pov=pc.PlayerCameraManager.CameraCachePrivate.POV
 local x,y,z=p.x-pov.Location.X,p.y-pov.Location.Y,p.z-pov.Location.Z
 local d=math.sqrt(x*x+y*y+z*z);local yaw=math.rad(pov.Rotation.Yaw)
 local range=important and 6400 or 1600
 if d>=range then return reject(self,kind,'inaudible')end
 local sample=choices[math.random(#choices)];local pitch=sample.pitch
 if important then pitch=(1+(math.random()-math.random())*.2)*.7
 elseif kind=='flint'then pitch=math.random()*.4+.8 end
 local pan=d>1 and math.max(-1,math.min(1,(-math.sin(yaw)*x+math.cos(yaw)*y)/d))or 0
 local gain=math.min(1,sample.volume*math.max(0,1-d/range)*(kind=='fire' and .4 or 1))
 local ok,raw,why=pcall(PBZMC_BlockSound,json.encode({clip=sample.clip,gain=gain,pitch=pitch,pan=pan}))
 if not ok or not raw then
  self.error=tostring(ok and why or raw);self.last_native_error=self.error;self.native_failures=self.native_failures+1
  ledger.explosion_retry=stamp+.12;ledger.soft_retry=stamp+.75
  return reject(self,kind,'native-rejected')
 end
 local reply=type(raw)=='string' and json.decode(raw)
 if type(reply)=='table' and finite(reply.voices) and reply.voices>=0 and reply.voices<=16 then
  ledger.native_count=reply.voices;ledger.native_at=stamp
 end
 ledger.voices[#ledger.voices+1]={kind=kind,owner=self.owner,finish=stamp+self.durations[sample.clip]/pitch+TAIL}
 ledger.peak=math.max(ledger.peak,#ledger.voices)
 self.last_events[kind]=stamp;self.played=self.played+1;increment(self.counts,kind);self.error=nil
 return true
end
function M:state()
 if not self.closed then now(self,require('host.pbz.local_player').controller())end
 local active,soft,kinds=snapshot(self)
 return {played=self.played,counts=copy(self.counts),requested=self.requested,merged=self.merged,dropped=self.dropped,
  merged_counts=copy(self.merged_counts),dropped_counts=copy(self.dropped_counts),drop_reasons=copy(self.drop_reasons),
  active=active,active_background=soft,active_by_kind=kinds,peak=self.ledger.peak,native_failures=self.native_failures,
  error=self.error,last_native_error=self.last_native_error,closed=self.closed==true,
  limits={total=TOTAL_LIMIT,background=SOFT_LIMIT,explosion=policy.explosion.voices},queued=0}
end
function M:close()
 if self.closed then return true end
 now(self,require('host.pbz.local_player').controller())
 self.last_events={};self.clock=nil;self.closed=true
 -- The native API has no per-voice stop. Retain <=8 numeric reservations,
 -- never a controller/world/actor or delayed playback callback.
 return true
end
return M
