-- Original model geometry and textures are shared by every instance of a species.
-- Only the joints that actually move receive transforms after spawning.
local valid=require('host.pbz.appearance').valid
local ids=require('host.pbz.object_identity')
local mesh=require('host.pbz.mesh_bundle')
local animation=require('presentation.mob_animation')
local convert=require('presentation.mob_transform')
local M={};M.__index=M
local zero={Pitch=0,Yaw=0,Roll=0}
local transform={Rotation={X=0,Y=0,Z=0,W=1},Translation={X=0,Y=0,Z=0},Scale3D={X=1,Y=1,Z=1}}
local function read(path)
  local f=assert(io.open(path,'rb'));local raw=f:read('a');f:close();return raw
end
function M.new(binding)
  local root=binding.item_models_root..'/../undead'
  return setmetatable({root=root,binding=binding,entries=assert(require('dkjson').decode(read(root..'/manifest.json'))),
    models={},next_cache=0,cache_keys={},mesh_class=StaticFindObject('/Script/ProceduralMeshComponent.ProceduralMeshComponent')},M)
end
function M:animation(name,rig)
  if not self.animations then
    self.animations=animation.library(assert(require('dkjson').decode(read(self.root..'/animations.json'))))
  end
  return animation.new(self.animations,name,rig)
end
function M:model(name,units)
  local cache=self.models[name]
  if cache then return cache end
  local entry=assert(self.entries[name],'missing-undead-model:'..name)
  local raw=read(self.root..'/'..entry.mesh.path)
  assert(#raw==entry.mesh.bytes and require('storage.sha256')(raw)==entry.mesh.sha256,'undead-model-checksum:'..name)
  cache={parts=mesh.decode(raw,units),bottom=entry.bottom*units,units=units,texture=entry.texture,rig=entry.rig}
  if name=='ender_dragon' then
    require('presentation.dragon_model').prepare_mesh(cache.parts,units)
    cache.bottom=0 -- dragon root animation is relative to the entity's feet
  end
  -- Native components already own the uploaded buffers and material. Retain
  -- only recent decoded Lua vertex arrays when browsing a large egg catalogue.
  local slot=self.next_cache%18+1
  local old=self.cache_keys[slot]
  if old then
    local old_texture=self.models[old].texture
    self.models[old]=nil
    if self.translucent_materials then self.translucent_materials[self.root..'/'..old_texture.path..':'..old_texture.sha256..':cutout']=nil end
  end
  self.cache_keys[slot]=name;self.next_cache=slot;self.models[name]=cache;return cache
end
function M:attach(actor,name,units,half)
  local cached=self:model(name,units)
  -- Creature skins are cutouts, not transparent water. A depth-writing masked
  -- material prevents the back/top of a cube painting over its face/chest.
  local material=require('host.pbz.translucent_blocks').cached(self,self.binding.actor,self.root,cached.texture,true)
  local result={}
  for _,part in ipairs(cached.parts) do
    local c=actor:AddComponentByClass(self.mesh_class,false,transform,false)
    assert(valid(c),'undead-mesh-component:'..name)
    c:SetCollisionEnabled(0);c:SetCastShadow(false);c:SetCullDistance(10000)
    c:SetMaterial(0,material);if #part.positions>0 then mesh.apply(c,part)end
    local p=part.pivot
    c:K2_SetRelativeLocationAndRotation({X=p.X,Y=p.Y,Z=p.Z-half-cached.bottom},zero,false,{},true)
    result[part.name]={component=c,material=material,last_pitch=0,last_roll=0,units=units,
      root_offset=-half-cached.bottom,base=cached.rig and cached.rig[part.name]}
  end
  if cached.rig then
    for name,entry in pairs(result)do
      local parent=entry.base.parent
      if parent~=''and result[parent]then
        assert(entry.component:K2_AttachToComponent(result[parent].component,FName('None'),2,2,2,false),'mob-bone-attachment:'..name)
        entry.parent_pivot=cached.rig[parent].pivot;entry.root_offset=0
      end
      local p=convert.position(entry.base.pivot,entry.parent_pivot,units,entry.root_offset)
      entry.component:K2_SetRelativeLocationAndRotation(p,convert.rotation(entry.base),false,{},true)
    end
  end
  return result
end
function M.pose(m,now,moving)
  assert(m.visual,'vanilla-mob-animation-missing')
    local poses=m.visual:update(m,now)
    for name,pose in pairs(poses)do
      local part=m.parts[name]
      if part then
        local last=part.last_pose;local changed=not last
        if last then
          for i=1,3 do
            if math.abs(pose.rotation[i]-last[i])>.25 or math.abs(pose.position[i]-last[i+3])>.015
                or math.abs(pose.scale[i]-last[i+6])>.002 then changed=true;break end
          end
        end
        if pose.ordered or pose.entity_rotation or last and (last.ordered or last.entity_rotation)then changed=true end
        if part.visible~=pose.visible then part.component:SetVisibility(pose.visible,false);part.visible=pose.visible end
        if changed then
          local p=convert.position(pose.position,part.parent_pivot,part.units,part.root_offset)
          part.component:K2_SetRelativeLocationAndRotation(p,convert.rotation(pose,poses,m.visual.rig,name),false,{},true)
          if not last or pose.scale[1]~=last[7]or pose.scale[2]~=last[8]or pose.scale[3]~=last[9]then
            part.component:SetRelativeScale3D({X=pose.scale[3],Y=pose.scale[1],Z=pose.scale[2]})
          end
          last=last or {};part.last_pose=last
          for i=1,3 do last[i]=pose.rotation[i];last[i+3]=pose.position[i];last[i+6]=pose.scale[i]end
          last.ordered=pose.ordered~=nil;last.entity_rotation=pose.entity_rotation
          m.pose_writes=(m.pose_writes or 0)+1
        end
      end
    end
end
function M.fuse(m,progress,white)
  local flash=progress>0 and math.floor(progress*(5+progress*2))%2==1
  if m.flash==flash or not flash and m.flash==nil then return end
  m.flash=flash
  for _,part in pairs(m.parts) do part.component:SetMaterial(0,flash and white or part.material) end
end
local sizes={skull=4, trident=5.5, spit=4, fang=5.5, bullet=5,gust=5,
  flame=24, fireball=70, dragon_breath=64, snowball=20, potion=23, sonic=52, beam=9}
-- Use the same decoded model and material as a full-size creature. The display
-- actor has no capsule, AI or damage ownership and cannot intercept an egg.
function M:preview(def,block)
  local entry=assert(self.entries[def.name])
  local units=def.model_units or def.height/(entry.top-entry.bottom)
  local cached=self:model(def.name,units)
  if not cached.preview_scale then
    local radial=0
    for _,part in ipairs(cached.parts) do
      for _,v in ipairs(part.positions) do
        radial=math.max(radial,(v.X+part.pivot.X)^2+(v.Y+part.pivot.Y)^2)
      end
    end
    cached.preview_scale=58/math.max(def.height,2*math.sqrt(radial))
  end
  local p={X=block.x,Y=block.y,Z=block.z}
  local actor=self.binding.actor:GetWorld():SpawnActor(StaticFindObject('/Script/Engine.Actor'),p,zero)
  assert(valid(actor),'spawner-preview-actor')
  local ok,why=pcall(function()
    assert(valid(actor:AddComponentByClass(StaticFindObject('/Script/Engine.SceneComponent'),false,transform,false)))
    local parts=self:attach(actor,def.name,units,def.height/2)
    M.pose({parts=parts,visual=self:animation(def.name,entry.rig),def=def,position=p,move={MovementMode=1}},0,false)
    local scale=cached.preview_scale
    actor:SetActorEnableCollision(false);actor:SetActorScale3D({X=scale,Y=scale,Z=scale})
    actor:K2_SetActorLocationAndRotation(p,zero,false,{},true)
  end)
  if not ok then actor:K2_DestroyActor();error(why) end
  return {actor=actor,id=ids.capture(actor)}
end
function M.projectile(combat,models,kind,p,rot)
  local actor=combat.binding.actor:GetWorld():SpawnActor(StaticFindObject('/Script/Engine.Actor'),p,rot)
  assert(valid(actor),'undead-projectile')
  local ok,why=pcall(function()
    local root=actor:AddComponentByClass(StaticFindObject('/Script/Engine.SceneComponent'),false,transform,false)
    assert(valid(root),'undead-projectile-root')
    if kind=='arrow' then
      local c=actor:AddComponentByClass(models.mesh_class,false,transform,false)
      assert(valid(c));c:SetCollisionEnabled(0);c:SetMaterial(0,combat.binding.material);mesh.apply(c,combat:arrow_part())
    else
      local parts=models:attach(actor,kind,assert(sizes[kind],kind),0)
      if kind=='trident' then
        parts.body.component:K2_SetRelativeLocationAndRotation({X=-70,Y=0,Z=0},{Pitch=-90,Roll=0,Yaw=0},false,{},true)
      end
    end
    actor:K2_SetActorLocationAndRotation(p,rot,false,{},true)
  end)
  if not ok then actor:K2_DestroyActor();error(why) end
  return {actor=actor,id=ids.capture(actor)}
end
return M
