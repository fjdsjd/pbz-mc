-- Two owned, render-only mesh components. Called by the one avatar/preview
-- pose writer; this module has no timers, input, collision or damage calls.
local identity=require('host.pbz.object_identity')
local bundle=require('host.pbz.mesh_bundle')
local poses=require('presentation.held_item_pose')
local native_pose=require('presentation.native_steve_pose')
local valid=require('host.pbz.appearance').valid
local M={};M.__index=M
local function transform()
  return {Rotation={X=0,Y=0,Z=0,W=1},Translation={X=0,Y=0,Z=0},Scale3D={X=1,Y=1,Z=1}}
end
function M.new(owner,catalog,material,options)
  assert(valid(owner) and valid(material),'held-items-owner-or-material-unavailable')
  return setmetatable({owner=owner,owner_id=identity.capture(owner),world_id=identity.capture(owner:GetWorld()),
    material=material,material_id=identity.capture(material),catalog=catalog,options=options or {},parts={},by_hand={},
    report={}},M)
end
function M:is_current()
  if self.closed or not valid(self.owner) or not identity.matches(self.owner,self.owner_id)
      or not identity.matches(self.owner:GetWorld(),self.world_id) or not valid(self.material)
      or not identity.matches(self.material,self.material_id) then return false end
  for _,entry in ipairs(self.parts) do
    if not valid(entry.component) or not identity.matches(entry.component,entry.identity) then return false end
    if self.options.capture_only and not entry.component.bVisibleInSceneCaptureOnly then return false end
  end
  return true
end
function M:component(hand)
  local entry=self.by_hand[hand]
  if entry then assert(entry.ready,'held-items-partial-allocation');return entry end
  local class=StaticFindObject('/Script/ProceduralMeshComponent.ProceduralMeshComponent')
  assert(valid(class),'held-items-component-class-unavailable')
  local component=self.owner:AddComponentByClass(class,true,transform(),false)
  assert(valid(component),'held-items-component-allocation-failed')
  entry={component=component,identity=identity.capture(component),hand=hand,shown=false}
  self.parts[#self.parts+1]=entry;self.by_hand[hand]=entry
  -- Register ownership immediately, including a later failed initialization.
  if self.options.owned then self.options.owned[entry.identity.address]=true end
  component:SetHiddenInGame(true,false);component:SetCollisionEnabled(0)
  component:SetCastShadow(not self.options.capture_only)
  if self.options.capture_only then
    component:SetVisibleInSceneCaptureOnly(true)
    assert(component.bVisibleInSceneCaptureOnly,'held-items-capture-isolation-failed')
  end
  component:SetMaterial(0,self.material)
  if self.options.on_create then self.options.on_create(component) end
  entry.ready=true;return entry
end
function M:hide()
  for _,entry in ipairs(self.parts) do
    if valid(entry.component) and identity.matches(entry.component,entry.identity) then
      if entry.shown then entry.component:SetHiddenInGame(true,false);entry.shown=false end
    end
  end
  self.report={}
end
function M:update(equipment,body,camera,holders)
  assert(self:is_current(),'held-items-stale-owner')
  equipment=equipment or {}
  local first=camera~=nil
  local units=first and 6.25 or native_pose.scale
  local planned,report={},{}
  local properties={pulling=(equipment.bow_charge or 0)>0 and 1 or 0,pull=equipment.bow_charge or 0}
  local main_motion=not first and equipment.group~='pbz' and
    require('presentation.minecraft_third_person_pose').item_motion(equipment) or nil
  for _,hand in ipairs({'main','offhand'}) do
    local left=hand=='offhand'
    local stack=equipment[hand]
    if equipment.group=='pbz' or (left and ((equipment.bow_charge or 0)>0 or (equipment.trident_charge or 0)>0))
        or (not left and stack and stack.content_id=='pbzmc:trident' and equipment.trident_out) then stack=nil end
    local context=(first and 'firstperson_' or 'thirdperson_')..(left and 'lefthand' or 'righthand')
    properties.blocking=equipment.blocking and equipment.use_hand==hand and 1 or 0
    local model,why=self.catalog:resolve(stack,context,properties,units)
    report[hand]={content_id=stack and stack.content_id or nil,model=model and model.model or nil,error=why}
    if model then
      local pose=first and poses.first_person(model,camera,left,holders and holders[hand])
        or poses.third_person(model,assert(body[left and 'left_arm' or 'right_arm']),left,not left and main_motion or nil)
      if first and not left and (equipment.bow_charge or 0)>0 then
        local charge=equipment.bow_charge;local power=math.min(1,(charge*charge+2*charge)/3)
        pose.scale.X=pose.scale.X*(1+power*.2)
      end
      planned[hand]={model=model,pose=pose}
    end
  end
  -- Resolve and verify both files before changing any visible mesh.
  for _,hand in ipairs({'main','offhand'}) do
    local plan=planned[hand]
    if plan then
      local entry=self:component(hand)
      if entry.key~=plan.model.key then
        if entry.shown then entry.component:SetHiddenInGame(true,false);entry.shown=false end
        local material=self.material
        if plan.model.palette then
          material=require('host.pbz.translucent_blocks').cached(self,self.owner,plan.model.material_root or self.catalog.root,plan.model.palette,plan.model.render_layer=='cutout')
        end
        entry.component:SetMaterial(0,material)
        entry.key=nil;bundle.apply(entry.component,plan.model.part);entry.key=plan.model.key
        entry.glint_key=nil
      end
      if plan.model.enchanted or entry.glint then
        require('host.pbz.enchanted_glint').update(entry,plan.model,self.catalog.root,
          StaticFindObject('/Script/Engine.Default__GameplayStatics'):GetRealTimeSeconds(self.owner))
      end
      entry.component:SetWorldScale3D(plan.pose.scale)
      entry.component:K2_SetWorldLocationAndRotation(plan.pose.position,plan.pose.rotation,false,{},true)
      if not entry.shown then entry.component:SetHiddenInGame(false,false);entry.shown=true end
    else
      local entry=self.by_hand[hand]
      if entry and entry.shown then entry.component:SetHiddenInGame(true,false);entry.shown=false end
    end
  end
  self.report=report
end
function M:close()
  if self.closed then return end
  if not valid(self.owner) or not identity.matches(self.owner,self.owner_id) then self.closed=true;return end
  local failures={}
  for _,entry in ipairs(self.parts) do
    if valid(entry.component) and identity.matches(entry.component,entry.identity) then
      local ok,why=pcall(function()
        entry.component:SetHiddenInGame(true,false)
        entry.component:K2_DestroyComponent(self.owner)
        assert(not valid(entry.component),'held-items-component-still-active')
      end)
      if not ok then failures[#failures+1]=tostring(why) end
    end
    if (not valid(entry.component) or not identity.matches(entry.component,entry.identity)) and self.options.owned then
      self.options.owned[entry.identity.address]=nil
    end
  end
  assert(#failures==0,table.concat(failures,'; '));self.closed=true
end
return M
