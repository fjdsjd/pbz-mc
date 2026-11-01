-- Reversible native appearance binding. The caller supplies a verified player
-- actor; class-wide NPC replacement is deliberately not an identity policy.
local UE=require('UEHelpers')
local identity=require('host.pbz.object_identity')
local bundle=require('host.pbz.mesh_bundle')
local pose=require('presentation.native_steve_pose')
local visibility=require('host.pbz.appearance_visibility')
local M={};M.__index=M
local cache
local is_valid,system
local required={'neck_01','pelvis','upperarm_r','upperarm_l','hand_r','hand_l','thigh_r','thigh_l','foot_r','foot_l'}
local function valid(object)
  if not object or not object:IsValid() then return false end
  if not is_valid then is_valid=StaticFindObject('/Script/Engine.KismetSystemLibrary:IsValid');system=UE.GetKismetSystemLibrary() end
  return is_valid(system,object)
end
local function transform()
  return {Rotation={X=0,Y=0,Z=0,W=1},Translation={X=0,Y=0,Z=0},Scale3D={X=1,Y=1,Z=1}}
end
local function weapon_mesh(component)
  local ok,asset=pcall(function() return component:GetSkeletalMeshAsset() end)
  if not ok or not valid(asset) then return false end
  local name=asset:GetFullName()
  return name:find('/Weapon/',1,true)~=nil or name:find('/Weapons/',1,true)~=nil
end
function M.new(actor,assets,log,source_hint)
  assert(valid(actor),'appearance-actor-invalid')
  local character=actor:IsA(StaticFindObject('/Script/Engine.Character'))
  local mesh
  if source_hint then
    assert(valid(source_hint) and identity.matches(source_hint:GetOwner(),identity.capture(actor)),
      'appearance-source-hint-owner')
    mesh=source_hint
  elseif character then mesh=actor.Mesh
  else
    -- Sequence actors can own a body component without ACharacter.Mesh.
    -- The lifecycle has already verified a protagonist class or source asset.
    for _,param in ipairs(actor:K2_GetComponentsByClass(StaticFindObject('/Script/Engine.SkeletalMeshComponent'))) do
      local component=param:get()
      if valid(component) and component:GetBoneIndex(FName('pelvis'))>=0
          and component:GetBoneIndex(FName('thigh_l'))>=0 and component:GetBoneIndex(FName('neck_01'))>=0 then
        assert(not mesh,'appearance-ambiguous-sequence-body');mesh=component
      end
    end
  end
  assert(valid(mesh),'appearance-source-mesh-invalid')
  local mesh_asset=mesh:GetSkeletalMeshAsset()
  assert(valid(mesh_asset),'appearance-source-asset-invalid')
  local self=setmetatable({actor=actor,source=mesh,actor_id=identity.capture(actor),source_id=identity.capture(mesh),
    asset_id=identity.capture(mesh_asset),world_id=identity.capture(actor:GetWorld()),parts={},owned={},hidden={},bones={},frames=0,
    character=character,source_hint=source_hint~=nil,item_models_root=assets..'/item-models',armor_models_root=assets..'/armor',log=log or function() end},M)
  for _,name in ipairs(required) do
    local index=mesh:GetBoneIndex(FName(name))
    assert(index>=0,'appearance-missing-bone:'..name)
    self.bones[name]=mesh:GetBoneName(index)
  end
  local head_index=mesh:GetBoneIndex(FName('FACIAL_C_FacialRoot'))
  self.head_basis='facial'
  if head_index<0 then
    head_index=mesh:GetBoneIndex(FName('Head'));self.head_basis='head_x_up_y_forward'
  end
  assert(head_index>=0,'appearance-head-bone-unavailable')
  self.head_bone=mesh:GetBoneName(head_index)
  if not cache then
    cache=bundle.read(assets..'/steve.mesh',pose.scale)
    for _,part in ipairs(cache) do for _,uv in ipairs(part.uv) do uv.X=433.5/512;uv.Y=139.5/256 end end
  end
  local material=LoadAsset('/Engine/EngineMaterials/DefaultTextMaterialOpaque.DefaultTextMaterialOpaque')
  assert(valid(material),'appearance-material-unavailable')
  self.material=material
  local ok,err=pcall(function()
    for _,part in ipairs(cache) do
      if #part.positions>0 then
        local component=actor:AddComponentByClass(StaticFindObject('/Script/ProceduralMeshComponent.ProceduralMeshComponent'),false,transform(),false)
        assert(valid(component),'appearance-component-create-failed')
        self.parts[#self.parts+1]={component=component,part=part}
        self.owned[component:GetAddress()]=true
        component:SetCollisionEnabled(0)
        component:SetHiddenInGame(true,false)
        component:SetCastShadow(true)
        bundle.apply(component,part)
        component:SetMaterial(0,material)
      end
    end
    self.tick_option=mesh.VisibilityBasedAnimTickOption
    mesh.VisibilityBasedAnimTickOption=0 -- AlwaysTickPoseAndRefreshBones, including hidden source.
    self:update()
    self:hide_native()
    for _,entry in ipairs(self.parts) do entry.component:SetHiddenInGame(false,false) end
    self.log('appearance bound actor='..actor:GetFullName()..' parts='..#self.parts..' native-hidden='..#self.hidden)
  end)
  if not ok then
    local cleaned,why=pcall(self.close,self)
    if not cleaned then
      -- Preserve the partial binding so its owner can retry cleanup; a failed
      -- constructor must not abandon native components and create more each tick.
      self.creation_failure=tostring(err);self.cleanup_failure=tostring(why)
      return self
    end
    error(err)
  end
  return self
end
function M:is_current()
  if not (not self.closed and valid(self.actor) and identity.matches(self.actor,self.actor_id)
    and identity.matches(self.actor:GetWorld(),self.world_id) and valid(self.source)
    and identity.matches(self.source,self.source_id) and identity.matches(self.source:GetOwner(),self.actor_id)
    and (not self.character or self.source_hint or identity.matches(self.actor.Mesh,self.source_id))
    and identity.matches(self.source:GetSkeletalMeshAsset(),self.asset_id)) then return false end
  for _,entry in ipairs(self.parts) do if not valid(entry.component) then return false end end
  if self.held and not self.held:is_current() then return false end
  return true
end
function M:ensure_hidden()
  if self.suppress_native_weapons and not self.weapons_suppressed then self:hide_native() end
  self.weapons_suppressed=self.suppress_native_weapons
  for _,entry in ipairs(self.hidden) do
    if valid(entry.component) and identity.matches(entry.component,entry.identity) then
      if entry.weapon then
        local owner=entry.component:GetOwner()
        local attached=identity.matches(owner,self.actor_id) or
          valid(owner) and identity.matches(owner:GetAttachParentActor(),self.actor_id)
        if self.suppress_native_weapons and attached then
          if not entry.weapon_hidden then entry.weapon_before=entry.component.bHiddenInGame;entry.weapon_hidden=true end
          entry.component:SetHiddenInGame(true,false)
        elseif entry.weapon_hidden then
          entry.component:SetHiddenInGame(entry.weapon_before,false);entry.weapon_hidden=nil
        end
      else visibility.hide(entry.component,entry.visibility) end
    end
  end
end
function M:hide_native()
  local seen={}
  for _,entry in ipairs(self.hidden) do
    if valid(entry.component) and identity.matches(entry.component,entry.identity) then
      if not entry.weapon then visibility.hide(entry.component,entry.visibility) end
      seen[entry.component:GetAddress()]=true
    end
  end
  local components=self.actor:K2_GetComponentsByClass(StaticFindObject('/Script/Engine.MeshComponent'))
  local function visit(component)
    local address=component:GetAddress()
    if valid(component) and not self.owned[address] and not seen[address] then
      local weapon=weapon_mesh(component)
      local entry={component=component,identity=identity.capture(component),hidden=component.bHiddenInGame,weapon=weapon}
      if not weapon then entry.visibility=visibility.capture(component)end
      self.hidden[#self.hidden+1]=entry
      seen[address]=true
      if not weapon then visibility.hide(component,entry.visibility) end
    end
  end
  -- The pinned fork's push_arrayproperty creates a Lua table whose entries are
  -- RemoteUnrealParam (GetParam), not UObjects. Materialize before native calls.
  local snapshot={}
  if type(components)=='table' then for _,item in ipairs(components) do snapshot[#snapshot+1]=item:get() end
  else components:ForEach(function(_,item) snapshot[#snapshot+1]=item:get() end) end
  for _,component in ipairs(snapshot) do visit(component) end
  -- PBZ's actual equipped weapon is a separate attached actor. Its mesh is not
  -- returned by the pawn's component enumeration; follow only weapon meshes
  -- beneath the native body, leaving other actors/effects alone.
  local children={};self.source:GetChildrenComponents(true,children)
  for _,wrapped in ipairs(children) do
    local component=wrapped:get()
    if valid(component) and component:IsA(StaticFindObject('/Script/Engine.MeshComponent')) and weapon_mesh(component) then visit(component) end
  end
end
function M:update(presentation)
  assert(self:is_current(),'appearance-stale-owner')
  local points={}
  for name,bone in pairs(self.bones) do
    local p=self.source:GetSocketLocation(bone)
    points[name]={X=p.X,Y=p.Y,Z=p.Z}
  end
  local r=self.source:GetSocketRotation(self.head_bone)
  local output=pose.solve(points,{Pitch=r.Pitch,Yaw=r.Yaw,Roll=r.Roll},self.head_basis)
  if presentation then
    assert(presentation.group=='mc' and not presentation.first_person,'unsupported-appearance-presentation')
    local state={}
    for key,value in pairs(presentation) do state[key]=value end
    local rotation=self.actor:K2_GetActorRotation()
    local velocity=self.actor:GetVelocity()
    state.actor_yaw=state.body_yaw or rotation.Yaw;state.speed=math.sqrt(velocity.X^2+velocity.Y^2)
    self.locomotion={body_yaw=state.actor_yaw,actor_yaw=rotation.Yaw,look_yaw=state.look.Yaw,
      speed=state.speed,amplitude=state.walk_amplitude,stride=state.stride}
    local capsule=self.actor.CapsuleComponent
    assert(valid(capsule),'appearance-mc-capsule-unavailable')
    local location=self.actor:K2_GetActorLocation()
    -- Use the physical actor root, as in SteveMesh.Pose. An animated native
    -- neck would apply native crouch/bob a second time on top of the MC pose.
    state.anchor=require('presentation.rigid_transform').compose(
      {position={X=location.X,Y=location.Y,Z=location.Z},rotation={Pitch=rotation.Pitch,Yaw=state.actor_yaw,Roll=rotation.Roll}},
      {position={X=0,Y=0,Z=24*pose.scale-capsule:GetScaledCapsuleHalfHeight()},rotation={Pitch=0,Yaw=0,Roll=0}})
    local render_anchor
    output,render_anchor=require('presentation.minecraft_gliding_pose').solve(cache,state)
    self.elytra_body_local=require('presentation.elytra_pose').relative(render_anchor,output.body)
    if not self.held then
      local catalog=require('host.pbz.item_models').new(self.item_models_root)
      self.held=require('host.pbz.held_items').new(self.actor,catalog,self.material,{owned=self.owned})
    end
    self.held:update(presentation,output)
  else self.elytra_body_local=nil;if self.held then self.held:hide()end end
  for _,entry in ipairs(self.parts) do
    local target=assert(output[entry.part.name],'appearance-unknown-part:'..entry.part.name)
    entry.component:K2_SetWorldLocationAndRotation(target.position,target.rotation,false,{},true)
  end
  self.render_pose=output -- Read-only input for camera-owned hand visuals.
  local armor_slots=require('host.pbz.campaign_inventory').armor_slots(self)
  local armor=require('host.pbz.armor_state').get(armor_slots)
  if self.armor and not self.armor:is_current() then self.armor:close();self.armor=nil end
  if armor.count>0 and not self.armor then
    local worn=require('host.pbz.worn_armor')
    self.armor=worn.new(self.actor,
      require('host.pbz.armor_models').new(self.armor_models_root),self.material,{owned=self.owned,parents=worn.parents(self.parts)})
  end
  if self.armor then
    self.armor:set_hidden(self.armor_hidden)
    self.armor:update(armor,output)
  end
  if armor_slots and armor_slots.chest and armor_slots.chest.content_id=='pbzmc:elytra'and not self.elytra then
    local worn=require('host.pbz.worn_elytra')
    self.elytra=worn.new(self.actor,self.item_models_root..'/../elytra-firework',self.material,
      {owned=self.owned,parents=worn.parents(self.parts)})
  end
  if self.elytra then
    self.elytra:set_hidden(self.armor_hidden=='all'and'all'or false)
    local now=StaticFindObject('/Script/Engine.Default__GameplayStatics'):GetTimeSeconds(self.actor)
    self.elytra:update({armor=armor_slots},{gliding=self.mc_gliding~=nil,crouching=presentation and presentation.crouching or false,
      velocity=self.mc_gliding and self.mc_gliding.velocity or self.actor:GetVelocity(),
      dt=self.elytra_time and math.max(0,math.min(.1,now-self.elytra_time))or 0,body_local=self.elytra_body_local})
    self.elytra_time=now
  end
  self.frames=self.frames+1
  if self.trace then
    local p=self.actor:K2_GetActorLocation();local velocity=self.actor:GetVelocity()
    local sample={frame=self.frames,time=StaticFindObject('/Script/Engine.Default__GameplayStatics'):GetTimeSeconds(self.actor),
      position={p.X,p.Y,p.Z},velocity={velocity.X,velocity.Y,velocity.Z},rotations={},locomotion=self.locomotion}
    for _,name in ipairs({'head','body','right_arm','left_arm','right_leg','left_leg'}) do
      local r=output[name].rotation;sample.rotations[name]={r.Pitch,r.Yaw,r.Roll}
    end
    local trace=self.trace;trace.samples[#trace.samples+1]=sample
    if #trace.samples>=trace.limit then
      local json=require('dkjson');local file=assert(io.open(trace.path,'w'))
      assert(file:write(json.encode({samples=trace.samples,source=self.source_id.name})));assert(file:close())
      self.trace=nil;self.log('appearance pose trace saved frames='..#trace.samples..' updates='..self.frames)
    end
  end
end
function M:close()
  if self.closed then return end
  self.closing=true
  local failures={}
  local function attempt(fn)
    local ok,why=pcall(fn);if not ok then failures[#failures+1]=tostring(why) end
  end
  if self.held then attempt(function() self.held:close() end) end
  if self.armor then attempt(function() self.armor:close() end) end
  if self.elytra then attempt(function() self.elytra:close() end) end
  if self.mc_gliding then attempt(function() self.mc_gliding:close() end)end
  if self.mc_creative_flight then attempt(function() self.mc_creative_flight:close() end)end
  if self.mc_fireworks then attempt(function() self.mc_fireworks:close() end)end
  for _,entry in ipairs(self.parts) do attempt(function()
    if valid(entry.component) then entry.component:K2_DestroyComponent(self.actor) end
  end) end
  local restored={}
  for _,entry in ipairs(self.hidden) do
    attempt(function()
      if valid(entry.component) and identity.matches(entry.component,entry.identity)
          and not restored[entry.component:GetAddress()] then
        restored[entry.component:GetAddress()]=true
        if entry.weapon then
          if entry.weapon_hidden and entry.component.bHiddenInGame then entry.component:SetHiddenInGame(entry.weapon_before,false) end
        else visibility.restore(entry.component,entry.visibility) end
      end
    end)
  end
  attempt(function()
    if valid(self.source) and identity.matches(self.source,self.source_id) and self.tick_option~=nil then
      self.source.VisibilityBasedAnimTickOption=self.tick_option
    end
  end)
  assert(#failures==0,table.concat(failures,'; '))
  self.closed=true
  self.log('appearance components released actor='..self.actor_id.name)
end
M.valid=valid
return M
