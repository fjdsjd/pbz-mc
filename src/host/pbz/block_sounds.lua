local M={};M.__index=M
local json=require('dkjson')
local actions={hit={add=1,divide=8,pitch=.5},place={add=1,divide=2,pitch=.8},['break']={add=1,divide=2,pitch=.8}}
local function finite(n)return type(n)=='number' and n==n and math.abs(n)<math.huge end
local function prepare(group)
  assert(finite(group.volume) and group.volume>=0 and group.volume<=1 and finite(group.pitch) and group.pitch>0,'block-sound-type-parameters')
  for kind in pairs(actions)do
    local event=assert(group.events[kind],'missing-block-sound-kind:'..kind)
    assert(type(event.event)=='string' and type(event.variants)=='table' and #event.variants>0,'empty-block-sound-event')
    local total=0
    for _,sample in ipairs(event.variants)do
      assert(type(sample.clip)=='string' and sample.clip:match('^[a-z0-9_]+$') and finite(sample.volume) and sample.volume>=0
        and finite(sample.pitch) and sample.pitch>0 and finite(sample.weight) and sample.weight%1==0 and sample.weight>0,'invalid-block-sound-variant')
      total=total+sample.weight;sample.upper_weight=total
    end
    event.total_weight=total
  end
  return group
end
function M.new(directory,log)
  local file=assert(io.open(directory..'/sounds/manifest.json','rb'));local manifest=assert(json.decode(file:read('a')));file:close()
  assert(manifest.schema==1 and manifest.version=='1.21.1' and manifest.format=='s16le','block-audio-manifest')
  local self=setmetatable({events=manifest.events,variants=manifest.variants,log=log,played=0,counts={},directory=directory,groups={}},M)
  -- The existing dirt/combat pack remains usable by old installations. New
  -- material IDs never silently fall back to grass when their pack is absent.
  local grass={volume=1,pitch=1,events={}}
  for kind in pairs(actions)do grass.events[kind]={event='block.grass.'..kind,variants=assert(manifest.variants[kind])}end
  self.groups.grass=prepare(grass)
  local source=io.open(directory..'/building-blocks/sounds/manifest.json','rb')
  if source then
    local block_manifest=assert(json.decode(source:read('a')));source:close()
    assert(block_manifest.schema==1 and block_manifest.profile=='minecraft-block-sound-groups-v1'
      and block_manifest.version=='1.21.1' and block_manifest.format=='s16le'
      and block_manifest.sample_rate==44100 and block_manifest.channels==2,'building-block-audio-manifest')
    for name,group in pairs(block_manifest.groups)do self.groups[name]=prepare(group)end
    self.material_pack=true
  else self.material_pack=false;self.mapping_error='building-block-sound-pack-unavailable' end
  local raw,why=PBZMC_BlockSound(json.encode({clip='warmup'}));self.ready=raw~=nil;self.error=why
  if not self.ready then log('block audio unavailable: '..tostring(why)) end
  return self
end
function M:play(kind,block,pc)
  if not self.ready then return false end
  local action=actions[kind]
  if not action then self.error='unknown-block-sound-action:'..tostring(kind);return false end
  local content_id=block and block.content_id
  local definition=content_id and require('content.blocks').get(content_id)
  local name=definition and definition.sound_group
  -- These are the two pre-material building IDs. Position-only legacy calls
  -- also mean dirt; new block records must declare their actual sound group.
  if not name and (not content_id or content_id=='pbzmc:dirt' or content_id=='pbzmc:tnt')then name='grass' end
  local group=name and self.groups[name]
  if not group then self.error='missing-original-block-sound-group:'..tostring(content_id)..':'..tostring(name);return false end
  local event=group.events[kind];local pick=math.random(event.total_weight);local sample
  for _,candidate in ipairs(event.variants)do if pick<=candidate.upper_weight then sample=candidate;break end end
  local position=block and (block.position or block)
  local px,py,pz=position and (position.x or position.X),position and (position.y or position.Y),position and (position.z or position.Z)
  if not finite(px) or not finite(py) or not finite(pz)then self.error='invalid-block-sound-position';return false end
  local pov=pc.PlayerCameraManager.CameraCachePrivate.POV
  local x,y,z=px-pov.Location.X,py-pov.Location.Y,pz-pov.Location.Z
  local distance=math.sqrt(x*x+y*y+z*z);local yaw=math.rad(pov.Rotation.Yaw)
  local pan=distance>1 and math.max(-1,math.min(1,(-math.sin(yaw)*x+math.cos(yaw)*y)/distance)) or 0
  local source_volume=(group.volume+action.add)/action.divide*sample.volume
  local pitch=group.pitch*action.pitch*sample.pitch
  local gain=source_volume*math.max(0,1-distance/1600)
  local raw,why=PBZMC_BlockSound(json.encode({clip=sample.clip,gain=gain,pan=pan,pitch=pitch}))
  if not raw then self.error=why;return false end
  self.error=nil;self.played=self.played+1
  self.counts[kind]=(self.counts[kind] or 0)+1
  local key=name..'.'..kind;self.counts[key]=(self.counts[key] or 0)+1
  self.last={event=kind,sound_event=event.event,sound_group=name,content_id=content_id,legacy=content_id==nil,
    clip=sample.clip,gain=gain,pan=pan,pitch=pitch,source_volume=source_volume,
    sound_type_volume=group.volume,sound_type_pitch=group.pitch,position={x=px,y=py,z=pz}}
  return true
end
function M:combat(kind,position,pc,power)
  if not self.ready then return false end
  local choices=self.variants and self.variants[kind]
  if not choices or #choices==0 then self.error='missing-original-audio-event:'..kind;return false end
  local sample=choices[math.random(#choices)]
  local pov=pc.PlayerCameraManager.CameraCachePrivate.POV
  local x,y,z=position.X-pov.Location.X,position.Y-pov.Location.Y,position.Z-pov.Location.Z
  local distance=math.sqrt(x*x+y*y+z*z);local yaw=math.rad(pov.Rotation.Yaw)
  local pan=distance>1 and math.max(-1,math.min(1,(-math.sin(yaw)*x+math.cos(yaw)*y)/distance)) or 0
  local pitch=sample.pitch
  -- Vanilla bow uses charge-dependent pitch; arrow impact has its own jitter.
  if kind=='bow_shoot' then pitch=pitch*(1/(math.random()*.4+1.2)+(power or 1)*.5)
  elseif kind=='pearl_throw' then pitch=pitch*.4/(math.random()*.4+.8)
  elseif kind=='arrow_hit' then pitch=pitch*1.2/(math.random()*.2+.9) end
  local gain=sample.volume*(kind=='pearl_throw' and .5 or 1)*math.max(0,1-distance/1600)
  local raw,why=PBZMC_BlockSound(json.encode({clip=sample.clip,gain=gain,pan=pan,pitch=pitch}))
  if not raw then self.error=why;return false end
  self.played=self.played+1;self.counts[kind]=(self.counts[kind] or 0)+1
  self.last={event=kind,clip=sample.clip,gain=gain,pitch=pitch}
  return true
end
return M
