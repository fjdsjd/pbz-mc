-- Original events, shared preloaded native PCM bank; no per-cell voices.
local json=require('dkjson')
local M={};M.__index=M
local aliases={lever_click='lever',comparator_click='comparator'}
function M.new(root,log)
  local f=assert(io.open(root..'/mechanism-blocks/sounds/manifest.json','rb'))
  local manifest=assert(json.decode(f:read('a')));f:close()
  return setmetatable({variants=manifest.variants,event_names=manifest.event_names,played=0,log=log or function()end},M)
end
function M:play(event,record)
  event=aliases[event]or event
  local variants=self.variants[event];if not variants or #variants==0 then return false end
  if type(PBZMC_BlockSound)~='function'then return false end
  local pc=require('host.pbz.local_player').controller();if not pc or not pc:IsValid()then return false end
  local pov=pc.PlayerCameraManager.CameraCachePrivate.POV
  local x,y,z=record.x-pov.Location.X,record.y-pov.Location.Y,record.z-pov.Location.Z
  local distance=math.sqrt(x*x+y*y+z*z);if distance>=1600 then return true end
  local sample=variants[math.random(#variants)];local volume,pitch=1,1
  if event=='lever'then volume=.3;pitch=(record.properties or {}).powered and .6 or .5
  elseif event=='comparator'then volume=.3;pitch=(record.properties or {}).mode=='subtract'and .55 or .5
  elseif event:match('^piston_')then volume=.5;pitch=.6+math.random()*.25
  elseif event:match('_hit$')then volume=.25;pitch=.5
  elseif event:match('_place$')or event:match('_break$')then pitch=.8
  elseif event:match('_ambient$')then volume=.2 end
  local yaw=math.rad(pov.Rotation.Yaw)
  local pan=distance>1 and math.max(-1,math.min(1,(-math.sin(yaw)*x+math.cos(yaw)*y)/distance))or 0
  local raw,why=PBZMC_BlockSound(json.encode({clip=sample.clip,gain=volume*sample.volume*(1-distance/1600),
    pitch=pitch*sample.pitch,pan=pan,sound_event=self.event_names and self.event_names[event]and 'minecraft:'..self.event_names[event]or nil,
    source=event:match('^bucket_')and 'player' or 'block'}))
  if not raw then self.error=tostring(why);return false end
  self.error=nil;self.played=self.played+1;self.last=event;return true
end
function M:state()return {played=self.played,last=self.last,error=self.error}end
return M
