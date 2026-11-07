"""Integration checks using production TNT modules and verified real resources.

Native Unreal calls are explicit doubles. No game input, game process, live
damage, deployment, or files outside this check are touched. These checks do
not establish host material rendering or native garbage-collection behavior.
"""
from pathlib import Path
import hashlib
import json
import sys

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'build/lua-check'))
from lupa.lua54 import LuaRuntime

lua=LuaRuntime(unpack_returned_tuples=True)
lua.globals().ROOT=ROOT.as_posix()
result=lua.execute(r'''
package.path=ROOT..'/src/?.lua;'..ROOT..'/third_party/dkjson/?.lua;'..package.path
local json=require('dkjson')
local results={}
local function check(name,callback)
 local ok,why=pcall(callback);results[#results+1]={name=name,passed=ok,error=not ok and tostring(why)or nil}
end
local function near(a,b)assert(math.abs(a-b)<1e-5,tostring(a)..' ~= '..tostring(b))end
local reads,real_open={},io.open
io.open=function(path,...)
 reads[path]=(reads[path]or 0)+1;return real_open(path,...)
end
local asset_root=ROOT..'/assets/private/tnt'
local Assets=require('host.pbz.tnt_assets')
local assets=Assets.open(asset_root)
check('real manifest exposes meshes and distinct per-mesh scales',function()
 assert(#assets.manifest.outputs==35)
 assert(assets.records['tnt.mesh'].scale==6.25)
 assert(assets.records['fire/fire_textured.mesh'].scale==5.625)
 assert(Assets.open(asset_root)==assets)
end)
check('all textured cube faces are installed by the portable resource recipe',function()
 local f=assert(real_open(ROOT..'/distribution/asset-recipes/runtime-files.json','rb'))
 local packaged=json.decode(f:read('a'));f:close()
 for _,name in ipairs({'tnt_side','tnt_top','tnt_bottom'})do
  local path=assets:face_texture(name);local rel=assert(path:match('/%.%./(building%-blocks/.+)$'))
  assert(packaged[rel].sha256==assets.records['original/'..name..'.png'].sha256)
 end
end)
check('original PNG paths and particle payload have verified records',function()
 for _,name in ipairs({'particles/atlas.png','original/fire_0.png','particles.json'})do
  -- The host requests a path first; the atlas record is discovered lazily
  -- from the hash-verified particle payload, rather than listed as a mesh.
  assert(assets:path(name)==asset_root..'/'..name)
  assert(assets.records[name].sha256 and assets.verified[name])
  local before=reads[asset_root..'/'..name];assert(assets:path(name)==asset_root..'/'..name)
  assert(reads[asset_root..'/'..name]==before,'verified path rereads bytes')
 end
 local data=assets:particles();assert(data==assets:particles())
 assert(#data.animations.smoke==8 and #data.animations.explosion==16)
end)
check('TNT production decode caches 100cm cube and 24-vertex flash',function()
 local part=assets:part('tnt.mesh');assert(part==assets:part('tnt.mesh'))
 local flash=assets:part('tnt_flash.mesh');assert(#flash.positions==24)
 assert(#part.positions==4040)
 for _,key in ipairs({'X','Y','Z'})do
  local lo,hi=math.huge,-math.huge
  for _,v in ipairs(part.positions)do lo=math.min(lo,v[key]);hi=math.max(hi,v[key])end
  near(lo,-50);near(hi,50)
 end
 assert(reads[asset_root..'/tnt.mesh']==1,'mesh reread instead of cached')
end)
check('all 32 fire UV frames are isolated, exact and cached',function()
 local base=assets:part('fire/fire_textured.mesh')
 assert(#base.positions==8 and #base.triangles==24)
 for frame=0,31 do
  local part=assets:fire(frame);assert(part==assets:fire(frame))
  assert(part.positions==base.positions and part.uv~=base.uv)
  for i,uv in ipairs(part.uv)do
   near(uv.X,base.uv[i].X);near(uv.Y,(frame+base.uv[i].Y)/32)
   assert(uv.Y>=0 and uv.Y<=1)
  end
 end
 for _,uv in ipairs(base.uv)do assert(uv.Y==0 or uv.Y==1,'cached base UV was mutated')end
end)
check('particle original animation order and atlas bounds are exact',function()
 local data=assets:particles()
 for i=1,8 do assert(data.animations.smoke[i]=='generic_'..(8-i))end
 for i=1,16 do assert(data.animations.explosion[i]=='explosion_'..(i-1))end
 for _,sprite in pairs(data.sprites)do
  local r,u=sprite.atlas_pixels,sprite.atlas_uv
  near(u[1],r[1]/256);near(u[2],r[2]/128);near(u[3],(r[1]+r[3])/256);near(u[4],(r[2]+r[4])/128)
 end
end)

-- Production world/identity code with address-aware actor/component doubles.
local serial=0
local function object(name,outer)
 serial=serial+1
 local o={name=name..serial,address=serial,alive=true,outer=outer}
 function o:IsValid()return self.alive end
 function o:GetAddress()return self.address end
 function o:GetFullName()return self.name end
 return o
end
local current=true;local log={imports=0,materials=0,destroys=0,submissions=0}
local host=object('World');local pawn=object('Player',host)
pawn.location={X=1000,Y=-500,Z=80}
function pawn:GetWorld()return host end
function pawn:K2_GetActorLocation()return self.location end
local function require_live(o)assert(o.alive,'native call used stale '..o.name)end
local function actor_at(location)
 local actor=object('Actor',host);actor.location=location;actor.components={}
 function actor:AddComponentByClass(class,manual,trans,deferred)
  require_live(self);assert(not manual and not deferred,'scene root is not attached automatically')
  local mesh=object('Mesh',self);mesh.submissions=0;mesh.clears=0
  function mesh:SetCollisionEnabled(n)require_live(self);self.collision=n end
  function mesh:SetCastShadow(n)require_live(self);self.shadow=n end
  function mesh:SetReceivesDecals(n)require_live(self);self.decals=n end
  function mesh:SetMaterial(slot,mat)require_live(self);self.material=mat end
  function mesh:SetCullDistance(n)require_live(self);self.cull=n end
  function mesh:SetVisibility(n)require_live(self);self.visible=n end
  function mesh:SetMeshSectionVisible(n,on)self.visible_sections=self.visible_sections or {};self.visible_sections[n]=on end
  function mesh:ClearAllMeshSections()require_live(self);self.clears=self.clears+1;self.last=nil end
  function mesh:CreateMeshSection_LinearColor(section,positions,triangles,normals,uv,uv1,uv2,uv3,colors)
   require_live(self);self.submissions=self.submissions+1;log.submissions=log.submissions+1
   self.last={positions=positions,triangles=triangles,normals=normals,uv=uv,colors=colors}
  end
  function mesh:UpdateMeshSection_LinearColor(section,positions,normals,uv,uv1,uv2,uv3,colors)
   require_live(self);assert(#positions==0 and #normals==0 and #colors==0,'fire changed stable geometry')
   assert(self.last,'missing initial section');self.last.uv=uv;self.updates=(self.updates or 0)+1
  end
  actor.components[#actor.components+1]=mesh
  if not actor.RootComponent then actor.RootComponent=mesh end
  return mesh
 end
 function actor:K2_SetActorLocation(p,sweep,hit,teleport)
  require_live(self);assert(self.RootComponent,'actor has no scene root');self.location=p
 end
 function actor:SetActorScale3D(s)require_live(self);self.scale=s end
 function actor:K2_DestroyActor()
  require_live(self);self.alive=false;log.destroys=log.destroys+1
  for _,c in ipairs(self.components)do c.alive=false end
  return true
 end
 return actor
end
function host:SpawnActor(class,location,rotation)return actor_at(location)end
local pc=object('Controller');pc.PlayerCameraManager={CameraCachePrivate={POV={
 Location={X=0,Y=0,Z=0},Rotation={Pitch=20,Yaw=60,Roll=5}}}}
local system={}
package.loaded.UEHelpers={GetPlayerController=function()return pc end,GetKismetSystemLibrary=function()return system end}
package.loaded['host.pbz.local_player']={controller=function()return pc end}
package.loaded['host.pbz.appearance']={valid=function(o)return o and o:IsValid()end}
local base_material=object('BaseMaterial')
LoadAsset=function(path)return base_material end
FName=function(name)return name end
StaticFindObject=function(path)
 if path=='/Script/Engine.KismetRenderingLibrary:ImportFileAsTexture2D'then
  return function(library,context,file)
   local f=assert(real_open(file,'rb'));local magic=f:read(8);f:close();assert(magic=='\137PNG\13\10\26\10')
   log.imports=log.imports+1;local texture=object('Texture');texture.context=context;texture.file=file;return texture
  end
 end
 if path=='/Script/Engine.Default__KismetMaterialLibrary'then
  return {CreateDynamicMaterialInstance=function(_,owner,base,name,flags)
   log.materials=log.materials+1;local material=object('MID',owner);material.params={}
   function material:SetTextureParameterValue(key,value)require_live(self);self.params[key]=value end
   function material:K2_GetTextureParameterValue(key)return self.params[key]end
   return material
  end}
 end
 return path
end
local identity=require('host.pbz.object_identity')
local binding={actor=pawn,actor_id=identity.capture(pawn),world_id=identity.capture(host),is_current=function()return current end}
local real_assets_open=Assets.open
Assets.open=function(path)assert(path:sub(-17)=='/pbzmc-assets/tnt');return real_assets_open(asset_root)end
local World=require('host.pbz.tnt_world')
local world=World.new(binding,'__native_test__')
Assets.open=real_assets_open

check('native TNT uses root, world location, scale and cached frame changes',function()
 local h=world:spawn('tnt',{x=120,y=-30,z=75})
 assert(h.actor.RootComponent==h.mesh and h.mesh.collision==0 and h.mesh.shadow==false)
 near(h.actor.location.X,120);near(h.actor.location.Z,75)
 world:render(h,{x=140,y=-20,z=90},{white=true,scale=1.2})
 near(h.actor.location.X,140);near(h.actor.scale.X,1.2);assert(#h.mesh.last.positions==24)
 local n=h.mesh.submissions;world:render(h,{x=150,y=-20,z=90},{white=true,scale=1.2})
 assert(h.mesh.submissions==n,'unchanged TNT frame rebuilt')
 world:render(h,{x=150,y=-20,z=90},{white=false,scale=1})
 assert(h.mesh.visible_sections[0] and h.mesh.visible_sections[1] and h.mesh.visible_sections[2]
    and not h.mesh.visible_sections[3] and h.mesh.submissions==n and n==4)
 local faces=world.assets.textured
 assert(#faces[1].positions==16 and #faces[2].positions==4 and #faces[3].positions==4)
 for _,part in ipairs(faces)do
  local uv=false;for _,t in ipairs(part.uv)do uv=uv or (t.X==1 and t.Y==1)end
  assert(uv,'textured face lost original display UVs')
 end
 world:destroy(h);assert(h.retired and world.handles[h.id]==nil and not h.actor.alive)
 local ok=pcall(world.render,world,h,{x=0,y=0,z=0},{white=false,scale=1});assert(not ok)
end)
check('an unavailable shared face falls back once and still permits priming and flashing',function()
 local fallback=setmetatable({binding=binding,handles={},serial=0,materials={}},World)
 local misses=0
 fallback.assets=setmetatable({face_texture=function()
  misses=misses+1;error('missing portable face')
 end},{__index=world.assets})
 local p={x=0,y=0,z=45}
 for i=1,2 do
  local h=fallback:spawn('tnt',p)
  assert(h.flash_section==1 and fallback.textured==false and fallback.texture_error:find('missing portable face',1,true))
  assert(h.mesh.submissions==2)
  fallback:render(h,p,{white=true,scale=1});assert(h.mesh.visible_sections[1] and not h.mesh.visible_sections[0])
  fallback:render(h,p,{white=false,scale=1});assert(h.mesh.visible_sections[0] and not h.mesh.visible_sections[1])
  assert(h.mesh.submissions==2);fallback:destroy(h)
 end
 assert(misses==1 and not next(fallback.handles))
end)
check('fire reuses material and texture under stable player lifetime',function()
 local a=world:spawn('fire',{x=0,y=0,z=45});local b=world:spawn('fire',{x=80,y=0,z=45})
 assert(a.mesh.material==b.mesh.material,'two fires did not share material')
 assert(a.mesh.material.outer==binding.actor,'cached fire MID is owned by transient first fire actor')
 local imports=log.imports
 world:render(a,{x=0,y=0,z=45},{frame=13});local n=a.mesh.submissions
 assert(n==1 and a.mesh.updates==1,'fire UV animation rebuilt its mesh')
 world:render(a,{x=0,y=0,z=45},{frame=13});assert(a.mesh.submissions==n)
 local minz=math.huge;for _,p in ipairs(a.mesh.last.positions)do minz=math.min(minz,p.Z)end
 near(minz+a.actor.location.Z,0)
 world:destroy(a);world:render(b,{x=80,y=0,z=45},{frame=14})
 local c=world:spawn('fire',{x=160,y=0,z=45});assert(log.imports==imports)
 world:destroy(b);world:destroy(c)
end)
check('reused UObject address is never rendered or destroyed as old handle',function()
 local h=world:spawn('tnt',{x=0,y=0,z=0});local old=h.actor.name
 h.actor.name=old..'_reused'
 local ok=pcall(world.render,world,h,{x=0,y=0,z=0},{white=false,scale=1});assert(not ok)
 local before=log.destroys;world:destroy(h);assert(log.destroys==before and h.actor.alive)
 h.actor.name=old;h.actor:K2_DestroyActor()
end)

local Effects=require('host.pbz.tnt_effects')
local fx=Effects.new(world)
local function add_known_effect(kind,size,life)
 fx:add({kind=kind,x=100,y=200,z=300,vx=0,vy=0,vz=0,shade=.7,life=life,size=size,ticks=0})
end
check('atlas explosion half-size exactly matches pinned pixel quad geometry',function()
 add_known_effect('explosion',400,.4);fx:tick(0)
 local part=assert(fx.handle.mesh.last);assert(#part.positions==4 and #part.triangles==12)
 local a,b=part.positions[1],part.positions[2]
 near(math.sqrt((b.X-a.X)^2+(b.Y-a.Y)^2+(b.Z-a.Z)^2),400)
 local uv=assets:particles().sprites.explosion_0.atlas_uv
 near(part.uv[1].X,uv[1]);near(part.uv[1].Y,uv[4]);near(part.uv[3].X,uv[3]);near(part.uv[3].Y,uv[2])
 near(fx.handle.actor.location.X,pawn.location.X)
end)
check('explosion sprite timing and smoke reversed-frame timing use real atlas',function()
 fx:tick(.05)
 local uv=assets:particles().sprites.explosion_1.atlas_uv
 near(fx.handle.mesh.last.uv[1].X,uv[1]);near(fx.handle.mesh.last.uv[1].Y,uv[4])
 fx.particles={};add_known_effect('smoke',20,1);fx:tick(.2)
 local sprite=assets:particles().sprites.generic_6
 near(fx.handle.mesh.last.uv[1].X,sprite.atlas_uv[1]);near(fx.handle.mesh.last.uv[1].Y,sprite.atlas_uv[4])
end)
check('effects recover retired native actor without stale component calls',function()
 world:destroy(fx.handle);add_known_effect('explosion',400,.4)
 fx:tick(.05)
 assert(fx.handle and not fx.handle.retired and identity.matches(fx.handle.actor,fx.handle.identity))
end)
check('empty effects clear once and reuse their cached actor',function()
 fx.particles={};fx.emitters={};fx:tick(.05)
 local h=fx.handle;local n=h.mesh.clears;fx:tick(.05);assert(h.mesh.clears==n)
 add_known_effect('explosion',400,.4);fx:tick(.05);assert(fx.handle==h)
end)
check('native world close retires every surviving handle',function()
 world:close();assert(next(world.handles)==nil and next(world.materials)==nil)
 current=false;local ok=pcall(world.spawn,world,'tnt',{x=0,y=0,z=0});assert(not ok)
 current=true
end)

local audio_calls={}
PBZMC_BlockSound=function(raw)
 local request=assert(json.decode(raw));audio_calls[#audio_calls+1]=request
 assert(request.gain>=0 and request.gain<=1 and request.pan>=-1 and request.pan<=1)
 return '{}'
end
check('audio original bank events submit bounded spatial gain/pan/pitch',function()
 local audio_clock=1000
 local audio=require('host.pbz.tnt_sounds').new(asset_root,{clock=function()return audio_clock,'world-audio-check'end})
 for _,kind in ipairs({'fuse','flint','explosion','fire','extinguish'})do
  audio_clock=audio_clock+10
  assert(audio:play(kind,{x=50,y=100,z=0}));assert(audio.counts[kind]==1)
  local request=audio_calls[#audio_calls]
  if kind=='flint'then assert(request.pitch>=.8 and request.pitch<1.2)
  elseif kind=='explosion'then assert(request.pitch>.56 and request.pitch<.84)end
 end
 assert(audio.played==5)
 audio_clock=audio_clock+10
 PBZMC_BlockSound=function()return nil,'test-unavailable'end
 assert(not audio:play('fuse',{x=0,y=0,z=0}) and audio.played==5)
end)
io.open=real_open
return json.encode({checks=results,native_game_executed=false,
 limitations={'Native UObject/GC/material operations are doubles; actual visual/audio/game lifecycle requires host evidence.'},
 stats={asset_file_reads=reads,texture_imports=log.imports,material_creations=log.materials,mesh_submissions=log.submissions}})
''')
report=json.loads(result)
report['source_sha256']={name:hashlib.sha256((ROOT/'src/host/pbz'/name).read_bytes()).hexdigest()
                         for name in ('tnt_assets.lua','tnt_world.lua','tnt_effects.lua','tnt_sounds.lua')}
report['passed']=all(check['passed'] for check in report['checks'])
print(json.dumps(report,ensure_ascii=False,indent=2))
if not report['passed']:
    sys.exit(1)
