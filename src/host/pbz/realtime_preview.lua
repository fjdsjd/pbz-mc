-- Captures separate render-only Steve parts with the MC inventory mouse pose.
-- Only preview-owned components change; the live player's pose is untouched.
local identity=require('host.pbz.object_identity')
local Appearance=require('host.pbz.appearance')
local pose=require('presentation.native_steve_pose')
local M={};M.__index=M
local function object(path)
  local value=StaticFindObject(path)
  assert(value and value:IsValid(),'preview-native-metadata-unavailable:'..path)
  return value
end
local function enum(path,name)
  local value
  object(path):ForEachName(function(entry,number)
    local full=entry:ToString()
    if full==name or full:match('::([^:]+)$')==name then value=number end
  end)
  assert(value~=nil,'preview-native-enum-unavailable:'..name)
  return value
end
local function valid(value) return Appearance.valid(value) end

function M.new(binding,ui,rect,dpi,log)
  assert(binding and binding:is_current(),'preview-current-appearance-required')
  assert(ui:valid() and rect.w>0 and rect.h>0 and dpi>0,'preview-current-ui-required')
  assert(type(CancelDelayedAction)=='function','preview-cancellable-scheduler-required')
  local self=setmetatable({binding=binding,ui=ui,log=log or function() end,updates=0,
    width=rect.w,height=rect.h,parts=#binding.parts,
    active=true,dirty=true,look={body_yaw=0,head_yaw=0,head_pitch=0,tilt=0}},M)
  local ok,err=pcall(function()
    -- Register before allocating resources. Construction runs synchronously on
    -- this same game thread, and a partial failure retains a cleanup retry loop.
    self.action=LoopInGameThreadAfterFrames(2,function()
      -- This pinned UE4SS loop discards callback return values. Only the
      -- explicit CancelDelayedAction in close() unregisters the callback.
      if self.closed then if self.action then CancelDelayedAction(self.action);self.action=nil end;return end
      local worked,why=pcall(function()
        if self.closing or not self:is_current() then self:close()
        elseif self.active and self.dirty then self:update() end
      end)
      if not worked then
        self.closing=true
        if self.last_error~=tostring(why) then
          self.last_error=tostring(why);self.log('preview update/cleanup failed: '..self.last_error)
        end
        pcall(self.close,self)
      end
    end)
    local world=binding.actor:GetWorld()
    self.world_id=identity.capture(world)
    local at=binding.actor:K2_GetActorLocation()
    self.stage={X=at.X,Y=at.Y,Z=at.Z-100000}
    self.actor=world:SpawnActor(object('/Script/Engine.SceneCapture2D'),self.stage,{Pitch=0,Yaw=0,Roll=0})
    assert(valid(self.actor),'preview-capture-actor-allocation-failed')
    self.actor_id=identity.capture(self.actor)
    self.capture=self.actor.CaptureComponent2D
    assert(valid(self.capture),'preview-capture-component-unavailable')
    self.capture_id=identity.capture(self.capture)
    local capture=self.capture
    capture.bCaptureEveryFrame=false;capture.bCaptureOnMovement=false
    capture.bAlwaysPersistRenderingState=false
    capture.bUseRayTracingIfEnabled=false
    capture.bRenderInMainRenderer=false
    capture.bMainViewFamily=false;capture.bMainViewCamera=false;capture.bMainViewResolution=false
    capture.PrimitiveRenderMode=enum('/Script/Engine.ESceneCapturePrimitiveRenderMode','PRM_UseShowOnlyList')
    -- The first HDRNoAlpha run produced RGB with zero alpha in this host.
    -- FinalColorLDR is a separate runtime candidate, not assumed opaque.
    capture.CaptureSource=enum('/Script/Engine.ESceneCaptureSource','SCS_FinalColorLDR')
    self.capture_source='SCS_FinalColorLDR'
    capture.CompositeMode=enum('/Script/Engine.ESceneCaptureCompositeMode','SCCM_Overwrite')
    capture.ProjectionType=enum('/Script/Engine.ECameraProjectionMode','Orthographic')
    capture.OrthoWidth=160
    capture.PostProcessBlendWeight=0
    capture.bConsiderUnrenderedOpaquePixelAsFullyTranslucent=true
    capture:ClearShowOnlyComponents()
    self.model=require('host.pbz.preview_model').new(self.actor,binding)
    assert(not self.model.creation_failure,self.model.creation_failure)
    for _,entry in ipairs(self.model.parts) do
      capture:ShowOnlyComponent(entry.component)
      if entry.part.name=='body' then self.body=entry.component;self.body_id=identity.capture(entry.component) end
    end
    assert(self.body,'preview-body-component-required')
    self.library=object('/Script/Engine.Default__KismetRenderingLibrary')
    self.target=object('/Script/Engine.KismetRenderingLibrary:CreateRenderTarget2D')(
      self.library,ui.owner,rect.w,rect.h,enum('/Script/Engine.ETextureRenderTargetFormat','RTF_RGBA8'),
      {R=0,G=0,B=0,A=1},false,false)
    assert(valid(self.target),'preview-render-target-allocation-failed')
    self.target_id=identity.capture(self.target)
    -- Both are native UObject references, so the target survives between ticks.
    capture.TextureTarget=self.target
    self.image=StaticConstructObject(object('/Script/UMG.Image'),ui.tree)
    assert(valid(self.image),'preview-image-allocation-failed')
    self.image_id=identity.capture(self.image)
    local slot=ui.canvas:AddChildToCanvas(self.image)
    assert(valid(slot),'preview-image-attach-failed')
    self.image:SetVisibility(3)
    self.image:SetBrushResourceObject(self.target)
    self.image:SetColorAndOpacity({R=1,G=1,B=1,A=1})
    slot:SetPosition({X=rect.x/dpi,Y=rect.y/dpi})
    slot:SetSize({X=rect.w/dpi,Y=rect.h/dpi});slot:SetZOrder(1000)
    self:configure_unlit()
    self.log(string.format('preview created parts=%d target=%dx%d capture=%s',self.parts,rect.w,rect.h,self.actor_id.name))
  end)
  if not ok then
    local cleaned,why=pcall(self.close,self)
    if not cleaned then self.creation_failure=tostring(err);self.cleanup_failure=tostring(why);return self end
    error(err)
  end
  return self
end

function M:is_current()
  return not self.closed and not self.closing and self.ui:valid() and self.binding:is_current()
    and valid(self.actor) and identity.matches(self.actor,self.actor_id)
    and identity.matches(self.actor:GetWorld(),self.world_id) and valid(self.capture)
    and identity.matches(self.capture,self.capture_id) and valid(self.image)
    and identity.matches(self.image,self.image_id)
    and identity.matches(self.body,self.body_id) and identity.matches(self.target,self.target_id)
    and self.model and self.model:valid()
end
function M:set_pointer(pointer,layout)
  local look=require('presentation.inventory_preview_pose').look(pointer,layout)
  for key,value in pairs(look) do if self.look[key]~=value then self.dirty=true;break end end
  self.look=look
end
function M:set_active(active)
  if self.active==active then return end
  self.active=active
  if valid(self.image) and identity.matches(self.image,self.image_id) then self.image:SetVisibility(active and 3 or 1) end
  if active then self.dirty=true end
end
function M:set_equipment(data)
  assert(self:is_current(),'preview-owner-changed')
  if self.equipment_data==data then return end
  if not self.catalog then
    self.catalog=require('host.pbz.item_models').new(assert(self.binding.item_models_root,'preview-item-model-root-required'))
  end
  local slots=require('rules.container_slots')
  local main=slots.get(data,'player/hotbar/'..data.player.selected)
  local native=require('rules.native_slot_reference').is(main)
  -- Snapshot immutable container stacks; no live source pose or combat event
  -- is replayed into the preview. Native references remain native references.
  self.model:set_equipment({main=main,offhand=slots.get(data,'player/offhand'),group=native and 'pbz' or 'mc',armor=data.player.armor},
    self.catalog,function(component) self.capture:ShowOnlyComponent(component) end)
  self.equipment_data=data;self.dirty=true
end
function M:update()
  assert(self:is_current(),'preview-owner-changed')
  self.model:update(self.stage,self.look)
  local center={X=self.stage.X,Y=self.stage.Y,Z=self.stage.Z-8*pose.scale}
  local at={X=center.X+360,Y=center.Y,Z=center.Z}
  local view={Pitch=0,Yaw=180,Roll=0}
  self.capture:K2_SetWorldLocationAndRotation(at,view,false,{},true)
  self.capture:CaptureScene()
  self.dirty=false
  self.updates=self.updates+1
  self.source_frame=self.binding.frames
  self.center=center
end
function M:state()
  local observed={}
  if self.model then
    for _,entry in ipairs(self.model.parts) do
      if valid(entry.component) and identity.matches(entry.component,entry.identity) then
        local r=entry.component:K2_GetComponentRotation()
        observed[entry.part.name]={Pitch=r.Pitch,Yaw=r.Yaw,Roll=r.Roll,capture_only=entry.component.bVisibleInSceneCaptureOnly}
      end
    end
  end
  return {updates=self.updates,source_frame=self.source_frame,parts=self.parts,width=self.width,height=self.height,
    closed=self.closed==true,closing=self.closing==true,center=self.center,
    target=self.target_id and self.target_id.name,capture=self.actor_id and self.actor_id.name,
    capture_source=self.capture_source,fixed_unlit_flags=self.fixed_unlit_flags==true,material=self.material_id and self.material_id.name,
    look=self.look,observed_parts=observed,independent_model=true,
    held=self.model and self.model.held and self.model.held.report or nil,
    error=self.last_error or self.creation_failure}
end
function M:set_capture_source(source)
  assert(self:is_current(),'preview-owner-changed')
  assert(source=='SCS_SceneColorHDR' or source=='SCS_FinalColorLDR','preview-capture-source-not-allowed')
  self.capture.CaptureSource=enum('/Script/Engine.ESceneCaptureSource',source)
  self.capture_source=source
  self:update()
end
function M:use_rgb_material()
  assert(self:is_current(),'preview-owner-changed')
  -- Existing PBZ video-display shader; only our MID parameters are changed.
  -- Its RGB and separate alpha parameters were observed in the loaded host.
  -- The engine white mask is a rendering constant, never visible UI artwork.
  local parent=object('/Game/PBZContent/UI/UINew/MaterialInterface/AlphaVideo/M_AlphaVideoPlayer.M_AlphaVideoPlayer')
  assert(parent.MaterialDomain==enum('/Script/Engine.EMaterialDomain','MD_UI'),'preview-material-domain-mismatch')
  local mask=object('/Engine/EngineResources/WhiteSquareTexture.WhiteSquareTexture')
  assert(mask:IsA(object('/Script/Engine.Texture2D')),'preview-mask-not-texture')
  local material=self.material
  if not valid(material) or not identity.matches(material,self.material_id) then
    material=object('/Script/Engine.KismetMaterialLibrary:CreateDynamicMaterialInstance')(
      object('/Script/Engine.Default__KismetMaterialLibrary'),self.ui.owner,parent,FName('PBZMC_RealtimePreview'),
      enum('/Script/Engine.EMIDCreationFlags','Transient'))
    assert(valid(material),'preview-ui-material-allocation-failed')
    self.material=material;self.material_id=identity.capture(material)
  end
  material:SetTextureParameterValue(FName('MediaTexture_RGB'),self.target)
  material:SetTextureParameterValue(FName('MediaTexture_Alpha'),mask)
  self.image:SetBrushFromMaterial(material)
  self.log('preview uses isolated RGB material '..self.material_id.name)
end
function M:configure_unlit()
  assert(self:is_current(),'preview-owner-changed')
  assert(type(PBZMC_ConfigurePreviewCapture)=='function','preview-native-flags-bridge-required')
  local path=assert(self.capture_id.name:match('^[^ ]+ (.+)$'),'preview-component-path-unavailable')
  local ok,why=PBZMC_ConfigurePreviewCapture(path);assert(ok,why)
  self.fixed_unlit_flags=true;self:update();self.log('preview fixed unlit flags applied to owned capture')
end
function M:close()
  if self.closed then return end
  self.closing=true
  local failures={}
  local function attempt(fn)
    local ok,why=pcall(fn);if not ok then failures[#failures+1]=tostring(why) end
  end
  attempt(function()
    if valid(self.capture) and identity.matches(self.capture,self.capture_id) then
      self.capture.bCaptureEveryFrame=false;self.capture.bCaptureOnMovement=false
      self.capture:ClearShowOnlyComponents()
    end
  end)
  attempt(function()
    if not self.image_detached and valid(self.image) and identity.matches(self.image,self.image_id) then
      self.image:RemoveFromParent()
      assert(not valid(self.image:GetParent()),'preview-image-still-attached')
    end
    self.image_detached=true
  end)
  attempt(function() if self.model then self.model:close() end end)
  attempt(function()
    if not self.actor_detached and valid(self.actor) and identity.matches(self.actor,self.actor_id) then
      self.actor:K2_DestroyActor()
      assert(not valid(self.actor) or self.actor:IsActorBeingDestroyed(),'preview-actor-still-active')
    end
    self.actor_detached=true
  end)
  -- A failed detach/destroy keeps the GPU resource alive until the next retry.
  if #failures==0 and self.image_detached and self.actor_detached then
    attempt(function()
      if not self.target_released and valid(self.target) and identity.matches(self.target,self.target_id) then
        object('/Script/Engine.KismetRenderingLibrary:ReleaseRenderTarget2D')(self.library,self.target)
        self.target_released=true
      end
    end)
  end
  assert(#failures==0,table.concat(failures,'; '))
  if self.action then CancelDelayedAction(self.action);self.action=nil end
  self.closed=true
  self.image=nil;self.capture=nil;self.actor=nil;self.target=nil;self.body=nil;self.material=nil;self.model=nil
  self.log('preview released updates='..self.updates..' source-frame='..tostring(self.source_frame))
end
return M
