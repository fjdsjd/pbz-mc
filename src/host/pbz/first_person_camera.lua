-- One camera owner, with separate PBZ head-eye and MC control paths.
local identity=require('host.pbz.object_identity')
local valid=require('host.pbz.appearance').valid
local view=require('presentation.first_person_camera')
local M={};local active
local sequence_watcher=false
local function vector(v) return {X=v.X,Y=v.Y,Z=v.Z} end
local function rotation(v) return {Pitch=v.Pitch,Yaw=v.Yaw,Roll=v.Roll} end
local function object(v) return valid(v) and identity.capture(v) or nil end
local function in_world(value,world_id)
  for _=1,12 do
    if not valid(value) then return false end
    if identity.matches(value,world_id) then return true end
    value=value:GetOuter()
  end
  return false
end
local function schema()
  local path='/Script/Engine.PlayerController:SetViewTargetWithBlend'
  local fn=StaticFindObject(path)
  assert(valid(fn) and fn:GetFunctionFlags()==67240962,'camera-viewtarget-schema')
  local expected={'ObjectProperty '..path..':NewViewTarget','FloatProperty '..path..':BlendTime',
    'ByteProperty '..path..':BlendFunc','FloatProperty '..path..':BlendExp','BoolProperty '..path..':bLockOutgoing'}
  local count=0
  fn:ForEachProperty(function(f) count=count+1;assert(f:GetFullName()==expected[count],'camera-viewtarget-field') end)
  assert(count==#expected,'camera-viewtarget-fields')
end
function M.get() return active end
function M.start(log)
  assert(not active,'first-person-camera-already-started');schema()
  local self={desired='pbz_native',reason='native',log=log,ticks=0,created=0,destroyed=0,retired=0,toggles=0,
    edges=require('presentation.camera_input').new(),inventory=false,width=16,height=9}
  active=self
  -- Construction may run before the player has a world or camera. Invalidate
  -- here and inspect on the game thread, after the new object is initialized.
  if not sequence_watcher and type(NotifyOnNewObject)=='function' and valid(StaticFindObject('/Script/LevelSequence.LevelSequencePlayer'))then
    sequence_watcher=pcall(NotifyOnNewObject,'/Script/LevelSequence.LevelSequencePlayer',function()
      if active then active.sequence_dirty=true end
    end)
  end
  self.sequence_watch=sequence_watcher
  function self:context()
    local lifecycle=require('host.pbz.appearance_lifecycle').get()
    local binding=lifecycle and lifecycle:current()
    if not binding or binding.closing or not binding:is_current() then return nil end
    local pc=lifecycle.controller
    if valid(pc) and identity.matches(pc.Pawn,binding.actor_id) then
      local manager=pc.PlayerCameraManager
      if valid(manager) then return binding,pc,manager end
    end
  end
  function self:story(binding,pc,manager)
    local target=manager.ViewTarget.Target
    local pending=manager.PendingViewTarget.Target
    local own=self.camera and identity.matches(target,self.camera_id)
    if valid(pending) and not identity.matches(pending,binding.actor_id)
        and not identity.matches(pending,self.camera_id) then return 'native-pending-camera' end
    if not own and not identity.matches(target,binding.actor_id) then return 'native-viewtarget' end
    if binding.actor.IsControlByDialogue then return 'native-dialogue' end
    if valid(binding.actor.CurrentCameraTrigger) then return 'native-camera-trigger' end
    if not self.sequence_dirty and self.sequence_result_tick==self.ticks and self.sequence_binding==binding then return self.sequence_reason end
    self.sequence_result_tick=self.ticks;self.sequence_binding=binding;self.sequence_reason=nil
    -- Playing status is still read every frame. Only the membership changes
    -- on construction or world travel. Older loaders retain timed discovery.
    if self.sequence_dirty or not self.sequence_tick or self.sequence_world~=binding.world_id.address
        or (not self.sequence_watch and self.ticks-self.sequence_tick>=15) then
      self.sequence_dirty=nil
      self.sequences=FindAllOf('LevelSequencePlayer') or {};self.sequence_world=binding.world_id.address;self.sequence_tick=self.ticks
    end
    for _,sequence in ipairs(self.sequences) do
      if valid(sequence) and sequence:IsPlaying() and in_world(sequence,binding.world_id)
        and valid(sequence:GetActiveCameraComponent()) then self.sequence_reason='native-sequence';return self.sequence_reason end
    end
    -- Damage reactions can temporarily ignore native input. They are not a
    -- cinematic camera owner and must not take the MC camera away.
  end
  function self:equipment()
    local data=require('host.pbz.item_interface').view_state()
    if not data then return {group='pbz'} end
    local slots=require('rules.container_slots')
    local main=slots.get(data,'player/hotbar/'..data.player.selected)
    return {group=require('rules.native_slot_reference').is(main) and 'pbz' or 'mc',selected=data.player.selected,
      main=main,offhand=slots.get(data,'player/offhand')}
  end
  function self:mc_selected()
    return self.desired=='mc_first_person' and self:equipment().group=='mc'
  end
  local special_class=StaticFindObject('/Script/AdvancedSpecialMove.SpecialMoveComponent')
  local traversal_flags={'bEnableUpRunningIK','bEnableSideRunningIK','bEnableClimLadderIK',
    'bEnableDownSlidingIK','bEnableHookIK','bEnableHookMoveIK'}
  function self:traversal(binding)
    if not binding then return 'no-player' end
    local movement=binding.actor.CharacterMovement
    local mode=valid(movement) and movement.MovementMode
    if mode==4 or mode==5 or mode==6 then
      return 'native-movement-mode-'..mode
    end
    if self.traversal_tick==self.ticks and self.traversal_binding==binding then return self.traversal_reason end
    self.traversal_tick=self.ticks;self.traversal_reason=nil
    if valid(special_class) then
      local component=self.traversal_component
      if self.traversal_binding~=binding or not valid(component) then
        component=binding.actor:GetComponentByClass(special_class)
        self.traversal_component=component
      end
      self.traversal_binding=binding
      if valid(component) then
        local data=component:GetSpecialMoveRuntimeData()
        for _,name in ipairs(traversal_flags) do
          if data[name] then self.traversal_reason='native-special-move-'..name;return self.traversal_reason end
        end
      end
    end
  end
  function self:mc_controls()
    local binding=self:context()
    return binding and (binding.mc_creative_flight or binding.mc_gliding or binding.mc_boat_riding or self:equipment().group=='mc') and not self:traversal(binding)
  end
  function self:release_movement()
    if self.movement then self.movement:close();self.movement=nil end
    -- Native weapon selection checks its controller input gates synchronously.
    -- Release only our counted creative gates before that check; flight keeps
    -- its collision owner and resumes after the equipment receipt commits.
    if self.transition and self.creative_flight then self.creative_flight:suspend(true)end
  end
  function self:release_collision()
    if self.collision then self.collision:close();self.collision=nil end
  end
  function self:release_facing()
    local lease=self.facing
    if lease then
      if identity.matches(lease.actor,lease.actor_id) and lease.actor.bUseControllerRotationYaw==true then
        lease.actor.bUseControllerRotationYaw=lease.yaw
      end
      if identity.matches(lease.movement,lease.movement_id) then
        if lease.movement.bOrientRotationToMovement==false then lease.movement.bOrientRotationToMovement=lease.orient end
        if lease.movement.bUseControllerDesiredRotation==false then lease.movement.bUseControllerDesiredRotation=lease.desired end
      end
    end
    self.facing=nil
  end
  function self:update_facing(binding,enabled)
    if self.facing and (not enabled or not identity.matches(binding.actor,self.facing.actor_id)) then self:release_facing() end
    if not enabled or self.facing then return end
    local actor=binding.actor;local movement=actor.CharacterMovement
    assert(valid(movement),'pbz-eye-facing-movement-required')
    self.facing={actor=actor,actor_id=identity.capture(actor),movement=movement,movement_id=identity.capture(movement),
      yaw=actor.bUseControllerRotationYaw,orient=movement.bOrientRotationToMovement,desired=movement.bUseControllerDesiredRotation}
    actor.bUseControllerRotationYaw=true;movement.bOrientRotationToMovement=false;movement.bUseControllerDesiredRotation=false
  end
  function self:release_free_look()
    local lease=self.free_look
    if lease and identity.matches(lease.component,lease.id) then
      lease.component:RemoveOverrideParameter(lease.name,0)
    end
    self.free_look=nil
  end
  function self:update_free_look(binding,pc,enabled)
    local component=binding and binding.actor.NBCamera
    local kind='mc'
    if self.free_look and (not enabled or self.free_look.kind~=kind or not identity.matches(component,self.free_look.id)) then self:release_free_look() end
    if not enabled then return end
    assert(valid(component),'mc-free-look-camera-unavailable')
    if not self.free_look then
      -- A null lock-target override is ignored by NBCamera. Its named rotation
      -- override is applied after soft/hard target framing, retaining native
      -- distance and collision. Never modify a shared camera asset or clear
      -- another system's target/priority stack.
      local path='/Script/AdvancedThirdPersonCamera.ATPCCameraComponent:'
      for _,spec in ipairs({{'SetOverrideParameter_Rotation',79823873,'NameProperty OverrideName','IntProperty Priority',
          'StructProperty TargetRotation','FloatProperty BlendTime'},
        {'RemoveOverrideParameter',67240961,'NameProperty OverrideName','FloatProperty BlentOut'}}) do
        local fn=StaticFindObject(path..spec[1]);assert(valid(fn) and fn:GetFunctionFlags()==spec[2],'mc-free-look-schema')
        local n=2;fn:ForEachProperty(function(p)
          n=n+1;local kind,name=spec[n]:match('(%S+) (%S+)')
          assert(p:GetFullName()==kind..' '..path..spec[1]..':'..name,'mc-free-look-field')
        end);assert(n==#spec,'mc-free-look-fields')
      end
      self.free_look={component=component,id=identity.capture(component),kind=kind,
        name=FName(kind=='mc' and 'PBZMC_MCFreeLook' or 'PBZMC_PBZMouseLook'),rotation=rotation(pc.ControlRotation)}
    end
    local lease=self.free_look
    local motion=binding.mc_creative_flight or binding.mc_gliding or self.movement
    if motion and motion.frame and self.focused then lease.rotation=rotation(motion.frame.rotation) end
    lease.component:SetOverrideParameter_Rotation(lease.name,10000,lease.rotation,0)
  end
  function self:set_body(hidden)
    local binding=self.binding
    local mode=hidden and ((self.source~='pbz' and not self.native_motion) and 'all' or 'head') or false
    if binding then
      binding.camera_body_hidden=mode=='all'
      binding.armor_hidden=hidden and (((self.source~='pbz' or binding.mc_gliding) and not self.native_motion) and 'all' or 'head') or nil
      if binding.armor then binding.armor:set_hidden(binding.armor_hidden)end
    end
    -- These are the mod's own components. A new actor or acquisition has a
    -- new list, even if its desired visibility matches the last camera.
    if self.applied_parts==self.hidden and self.applied_mode==mode then return end
    if binding then
      if mode=='all' then
        if binding.held then binding.held:hide()end
        if binding.elytra then binding.elytra:set_hidden('all')end
      elseif binding.pose_deferred and binding:is_current()then
        binding:update()
      end
    end
    for _,entry in ipairs(self.hidden or {}) do
      if valid(entry.component) and identity.matches(entry.component,entry.id) then
        local hide=mode=='all' or mode=='head' and (entry.name=='head' or entry.name=='hat')
        entry.component:SetHiddenInGame(hide or entry.before,false)
      end
    end
    self.applied_parts=self.hidden;self.applied_mode=mode
  end
  function self:release(reason,keep_movement)
    if not keep_movement then self:release_movement() end
    if not keep_movement and self.creative_flight then self.creative_flight:stop(reason)end
    self:release_free_look()
    self:release_facing()
    self.eye_input=nil;self.eye_look=nil;self.native_input=nil
    -- Only return our own view target. Never overwrite a cinematic's new target.
    if self.pc and identity.matches(self.pc,self.pc_id) and valid(self.pc.PlayerCameraManager)
      and identity.matches(self.pc.PlayerCameraManager.ViewTarget.Target,self.camera_id) then
      local pawn=self.pc.Pawn
      if valid(pawn) then self.pc:SetViewTargetWithBlend(pawn,0,0,0,false) end
    end
    self:set_body(false);self.hidden=nil;self.applied_parts=nil
    if self.model then self.model:close();self.model=nil end
    if valid(self.camera) and identity.matches(self.camera,self.camera_id) then
      self.camera:K2_DestroyActor();self.destroyed=self.destroyed+1
    elseif self.camera_id then
      self.retired=self.retired+1 -- World teardown already destroyed this owned actor.
    end
    self.camera=nil;self.camera_id=nil;self.component=nil;self.binding=nil;self.pc=nil;self.pc_id=nil;self.suspended=nil
    if self.reason~=reason then self.log('camera released: '..reason) end
    self.reason=reason
  end
  function self:camera_view(binding,pc)
    if binding.pose_deferred and (self.source=='pbz' or self.native_motion)then
      binding.camera_body_hidden=false;binding:update()
    end
    local height=binding.actor.CapsuleComponent:GetScaledCapsuleHalfHeight()
    local current=view.view(vector(binding.actor:K2_GetActorLocation()),height,
      binding.mc_creative_flight and binding.mc_creative_flight.frame.rotation or binding.mc_gliding and binding.mc_gliding.frame.rotation or self.movement and self.movement.frame and self.movement.frame.rotation or rotation(pc.ControlRotation),self.width,self.height)
    if (self.source=='pbz' or self.native_motion) and not binding.mc_creative_flight and not binding.mc_gliding and not binding.mc_boat_riding and binding.render_pose and binding.render_pose.head then
      -- Steve head origin is its neck. Original eyes are 6 of 8 pixels up and
      -- on the front face (4 pixels forward). Rotation follows native head.
      local scale=require('presentation.native_steve_pose').scale
      local eye=require('presentation.rigid_transform').compose(binding.render_pose.head,
        {position={X=4.05*scale,Y=0,Z=6*scale},rotation={Pitch=0,Yaw=0,Roll=0}})
      current.position=eye.position
      -- Head animation supplies eye position. Mouse is the sole view heading:
      -- feeding WASD-facing back into controller yaw makes strafing spin in a
      -- loop. Native action translation/root motion remains entirely native.
      local control=self.eye_look and self.eye_look.rotation or rotation(pc.ControlRotation)
      local function delta(a,b) return (a-b+180)%360-180 end
      current.rotation={Pitch=delta(control.Pitch,0),Yaw=control.Yaw,Roll=0}
    elseif self.movement and self.movement.frame and self.movement.frame.sneak then current.position.Z=current.position.Z-15 end
    if binding.mc_boat_riding then current.position.Z=current.position.Z-12*require('presentation.native_steve_pose').scale end
    return current
  end
  function self:acquire(binding,pc)
    self.source=self:equipment().group
    local current=self:camera_view(binding,pc)
    self.binding=binding;self.pc=pc;self.pc_id=identity.capture(pc)
    self.camera=binding.actor:GetWorld():SpawnActor(StaticFindObject('/Script/Engine.CameraActor'),current.position,current.rotation)
    assert(valid(self.camera),'first-person-camera-create-failed')
    self.camera_id=identity.capture(self.camera);self.created=self.created+1
    self.component=self.camera.CameraComponent
    assert(valid(self.component),'first-person-camera-component-unavailable')
    self.component.bConstrainAspectRatio=false
    self.component.bEnableFirstPersonScale=true;self.component.FirstPersonScale=.3
    self.component:SetFieldOfView(current.fov)
    self.model=require('host.pbz.first_person_model').new(self.camera,binding)
    assert(not self.model.creation_failure,self.model.creation_failure)
    self.hidden={}
    for _,entry in ipairs(binding.parts) do
      self.hidden[#self.hidden+1]={component=entry.component,id=identity.capture(entry.component),before=entry.component.bHiddenInGame,name=entry.part.name}
    end
    pc:SetViewTargetWithBlend(self.camera,0,0,0,false)
    assert(identity.matches(pc.PlayerCameraManager.ViewTarget.Target,self.camera_id),'first-person-viewtarget-not-accepted')
    self:set_body(true);self.reason='first-person'
    self.log('camera acquired first-person owner='..binding.actor_id.name)
  end
  function self:toggle()
    if self.closed then return false end
    local binding,pc,manager=self:context()
    if not binding or self.inventory or self:story(binding,pc,manager) then return false end
    if self.desired=='mc_first_person' then
      self:release('F5-native',true);self.desired='pbz_native'
    else
      local ok,why=pcall(self.acquire,self,binding,pc)
      if not ok then pcall(self.release,self,'acquire-failed');error(why) end
      self.desired='mc_first_person'
    end
    self.toggles=self.toggles+1;self.log('F5 camera='..self.desired);return true
  end
  function self:input(batch,allowed,epoch)
    if self.closed then return end
    if (batch.latest.width or 0)>=320 and (batch.latest.height or 0)>=240 then
      self.width,self.height=batch.latest.width,batch.latest.height
    end
    local binding,pc,manager=self:context()
    allowed=allowed and binding~=nil and not self.inventory and not self:story(binding,pc,manager)
    local focused=batch.latest.focused and not batch.overflow
    if not focused then self.viewport_pending=true end
    if focused and (self.viewport_pending or self.focused==nil) and allowed then
      local gameplay=StaticFindObject('/Script/Engine.Default__GameplayStatics')
      if not pc.bShowMouseCursor and not gameplay:IsGamePaused(pc) then
        -- OS foreground is not Slate viewport focus. After a minimize/restore
        -- the global item hook sees keys while Unreal receives no mouse axes.
        -- Recover only on a foreground edge in normal gameplay, never UI or a
        -- cinematic. This also activates the native relative mouse path.
        local widgets=StaticFindObject('/Script/UMG.Default__WidgetBlueprintLibrary')
        widgets:SetInputMode_GameOnly(pc,false)
        gameplay:SetViewportMouseCaptureMode(pc,2) -- CapturePermanently_IncludingInitialMouseDown
        widgets:SetFocusToGameViewport()
        self.viewport_pending=false
      end
    end
    local function sample(pointer)
      if batch.overflow then self.edges.armed=false;self.edges.down=true;return end
      if self.edges:update(pointer,allowed,epoch) then
        local ok,why=pcall(self.toggle,self)
        if not ok then self.error=tostring(why);self.log('F5 camera rejected: '..self.error) end
      end
    end
    for _,pointer in ipairs(batch.samples or {}) do sample(pointer) end
    sample(batch.latest)
    self.focused=focused
    self.last_batch=batch;self.batch_allowed=allowed
    local flight_input=allowed and not self.transition and not binding.mc_native_selection_pending
    if self.creative_flight then self.creative_flight:input_batch(batch,flight_input)end
    if self.flight then self.flight:input_batch(batch,flight_input)end
    if allowed and focused and self.desired=='mc_first_person' and self:equipment().group=='pbz' and not binding.mc_creative_flight and not binding.mc_gliding and not binding.mc_boat_riding and not self.transition and not self:traversal(binding) then
      if not self.eye_input then self.eye_input=require('input.first_person_controls').new(pc.ControlRotation) end
      local x,y=self.eye_input:sample_batch(batch,true)
      if x then pc:SetMouseLocation(x,y) end
      self.eye_look=self.eye_input:frame()
    else self.eye_input=nil;self.eye_look=nil end
    if allowed and focused and self.desired=='pbz_native' and self:equipment().group=='pbz' and not binding.mc_creative_flight and not binding.mc_gliding and not binding.mc_boat_riding and not self.transition then
      if not self.native_input then self.native_input=require('input.first_person_controls').new(pc.ControlRotation) end
      local dx,dy={},{};pc:GetInputMouseDelta(dx,dy)
      local x,y,r=self.native_input:native_sample(batch,true,rotation(pc.ControlRotation),dx.DeltaX or 0,dy.DeltaY or 0)
      if x then pc:SetMouseLocation(x,y) end
      if r then pc:SetControlRotation(r) end
    else self.native_input=nil end
    if self.movement then
      if not batch.first_person_controls then self:release_movement()
      else self.movement:input_batch(batch,allowed and self:mc_controls()) end
    end
  end
  function self:native_takeover()
    local binding,pc,manager=self:context()
    return not binding or self:story(binding,pc,manager)~=nil
  end
  function self:is_active() return self.camera~=nil and not self.suspended end
  function self:tick()
    -- Cancellation can leave one callback already queued by UE4SS. Closing is
    -- terminal: that callback must not reacquire a movement/input lease.
    if self.closed then return end
    self.ticks=self.ticks+1
    local binding,pc,manager=self:context()
    if self.camera and (not binding or self.binding~=binding or not valid(self.camera)
        or not identity.matches(pc,self.pc_id)) then self:release('owner-replaced') end
    if self.movement and (not binding or self.movement.binding~=binding or not identity.matches(pc,self.movement.pc_id)) then self:release_movement() end
    if self.collision and (not binding or self.collision.binding~=binding)then self:release_collision()end
    if self.flight and (not binding or self.flight.binding~=binding or not identity.matches(pc,self.flight.pc_id))then self.flight:close();self.flight=nil end
    if self.creative_flight and (not binding or self.creative_flight.binding~=binding or not identity.matches(pc,self.creative_flight.pc_id))then self.creative_flight:close();self.creative_flight=nil end
    if not binding then self:release_free_look();self:release_facing();self.reason='waiting-player';return end
    local reason=self:story(binding,pc,manager)
    -- A short camera blend also occurs on native attacks. BeginPlay and mesh
    -- assignments cover new doubles immediately. Reconcile pre-existing
    -- actors for sustained takeovers, without rescanning on each combat cut.
    if reason then
      self.story_frames=(self.story_frames or 0)+1
      if binding.lifecycle and self.story_frames==3 and (not self.scan_after or os.clock()>=self.scan_after) then
        binding.lifecycle.scan_requested=true;self.scan_after=os.clock()+4
      end
    else self.story_frames=0 end
    self.in_story=reason~=nil
    if not self.creative_flight then self.creative_flight=require('host.pbz.creative_flight').new(binding,pc)end
    if not self.flight then self.flight=require('host.pbz.elytra_flight').new(binding,pc)end
    local flight_allowed=not reason and not self.inventory and self.focused==true and not self.transition and not binding.mc_native_selection_pending
    local toggle=self.creative_flight:take_request(self)
    -- Consume both edges this tick. A double tap, including one which ends
    -- creative flight, cannot also deploy the wings.
    local glide=self.flight:wants_start(self,flight_allowed and not toggle)
    if not binding.mc_creative_flight then self.flight:observe_fall()end
    if flight_allowed and toggle=='stop' then
      self.creative_flight:stop('double-tap')
    elseif flight_allowed and (toggle=='start' or glide) then
      self:release_movement();self:release_facing();self:release_free_look()
      if toggle=='start' then
        local velocity=self.flight.active and self.flight.velocity or nil
        if self.flight.active then self.flight:stop('creative-flight')end
        self.flight:reset_fall();self.creative_flight:start(velocity)
      else
        self.flight:start()
      end
    end
    if self.creative_flight.active then self:release_movement();self.creative_flight:tick(self,reason)end
    if self.flight.active then self:release_movement();self.flight:tick(self,reason)end
    local equipment=self:equipment();self.source=equipment.group;self.native_motion=self:traversal(binding)
    if reason or self.native_motion then self:release_collision()
    elseif not self.collision then self.collision=require('host.pbz.player_collision').new(binding)end
    local move=not binding.mc_creative_flight and not binding.mc_gliding and (equipment.group=='mc' or binding.mc_boat_riding) and not reason and not self.native_motion and not self.inventory and self.focused and not self.transition
    -- Restore MC's rotation policy before snapshotting PBZ first-person facing.
    -- These two owners must never capture each other's temporary settings.
    if not move then self:release_movement() end
    local facing=equipment.group=='pbz' and not binding.mc_creative_flight and not binding.mc_gliding and not binding.mc_boat_riding and self.desired=='mc_first_person' and self.eye_look
      and not reason and not self.native_motion and not self.inventory and not self.transition
    self:update_facing(binding,facing and not binding.actor:IsPlayingRootMotion() and not binding.actor.DisableMovement)
    if facing
        and not reason and not self.native_motion and not self.inventory and not self.transition then
      -- Native first person keeps native locomotion/combat, but mouse aim must
      -- also reach the controller and idle/walking body. A playing montage
      -- retains its authored rotation and root motion (attacks and climbing).
      pc:SetControlRotation(self.eye_look.rotation)
      if self.desired=='mc_first_person' and not binding.actor:IsPlayingRootMotion() and not binding.actor.DisableMovement then
        binding.actor:K2_SetActorRotation({Pitch=0,Yaw=self.eye_look.rotation.Yaw,Roll=0},false)
      end
    end
    if move then
      if not self.movement then
        self.movement=require('host.pbz.first_person_movement').new(binding,pc)
        if self.last_batch and self.last_batch.first_person_controls then self.movement:input_batch(self.last_batch,self.batch_allowed) end
      end
      self.movement:tick()
    end
    self:update_free_look(binding,pc,(equipment.group=='mc' or binding.mc_boat_riding or binding.mc_gliding or binding.mc_creative_flight) and self.last_batch~=nil and not reason and not self.native_motion and not self.transition)
    if self.desired~='mc_first_person' then self.reason='native';return end
    if reason then
      -- Sequencer saves the incoming view target for its restore pass. Keep our
      -- actor alive while it owns the camera, otherwise restore can fall back
      -- to the PlayerController instead of the pawn/camera it recorded.
      self:release_movement()
      if self.camera then self:set_body(false);self.model:hide();self.suspended=true end
      if self.reason~=reason then self.log('camera yielded: '..reason) end
      self.reason=reason;return
    end
    if not self.camera then
      if self.inventory or pc.bShowMouseCursor or StaticFindObject('/Script/Engine.Default__GameplayStatics'):IsGamePaused(pc) then return end
      self:acquire(binding,pc)
    end
    if self.suspended then
      pc:SetViewTargetWithBlend(self.camera,0,0,0,false)
      self.suspended=nil;self.reason='first-person';self.log('camera resumed after native takeover')
    end
    local current=self:camera_view(binding,pc)
    self.camera:K2_SetActorLocationAndRotation(current.position,current.rotation,false,{},true)
    if self.fov~=current.fov then self.component:SetFieldOfView(current.fov);self.fov=current.fov end
    self:set_body(true)
    local presentation=require('host.pbz.item_interface').combat_presentation()
    if presentation and equipment.group=='mc' then equipment=presentation end
    self.model:update(current,self.native_motion and {group='pbz'} or equipment);self.view=current
  end
  function self:state()
    local binding,pc,manager=self:context()
    return {desired=self.desired,active=self:is_active(),reason=self.reason,toggles=self.toggles,
      created=self.created,destroyed=self.destroyed,retired=self.retired,camera=object(self.camera),player=binding and binding.actor_id,
      viewtarget=manager and object(manager.ViewTarget.Target),pending=manager and object(manager.PendingViewTarget.Target),
      position=binding and vector(binding.actor:K2_GetActorLocation()),control=pc and rotation(pc.ControlRotation),
      actor_rotation=binding and rotation(binding.actor:K2_GetActorRotation()),
      camera_position=manager and vector(manager.CameraCachePrivate.POV.Location),
      camera_rotation=manager and rotation(manager.CameraCachePrivate.POV.Rotation),fov=manager and manager.CameraCachePrivate.POV.FOV,
      inventory=self.inventory,source=self.source,selected=self:equipment().selected,transition=self.transition,native_motion=self.native_motion,mc_movement=self.movement and self.movement.frame,
      free_look=self.free_look and {active=true,kind=self.free_look.kind,rotation=self.free_look.rotation},locomotion=binding and binding.locomotion,
      eye_look=self.eye_look,
      native_mouse=self.native_input and {pending=self.native_input.native_pending~=nil,applied=self.native_input.native_applied or 0},
      facing_lease=self.facing~=nil,
      hp=self.movement and self.movement.hp,view=self.view,error=self.error,held=self.model and self.model.held and self.model.held.report,
      flight=self.flight and self.flight.report,gliding=binding and binding.mc_gliding~=nil,
      creative_flight=self.creative_flight and self.creative_flight.report,creative_flying=binding and binding.mc_creative_flight~=nil,
      body_held=binding and binding.held and binding.held.report,body_pose=binding and binding.render_pose,
      combat=require('host.pbz.item_interface').combat_state()}
  end
  function self:close()
    if self.closed then return end
    self.closed=true
    self:release_collision()
    if self.creative_flight then self.creative_flight:close();self.creative_flight=nil end
    if self.flight then self.flight:close();self.flight=nil end
    self:release('shutdown');self.desired='pbz_native'
    if self.action then CancelDelayedAction(self.action);self.action=nil end
    if self.trace then self.trace:close();self.trace=nil end
    active=nil
  end
  self.action=LoopInGameThreadAfterFrames(1,function()
    local ok,why=pcall(self.tick,self)
    if not ok then
      pcall(self.release_collision,self)
      if self.flight then pcall(self.flight.stop,self.flight,'camera-error')end
      pcall(self.release,self,'camera-error');self.desired='pbz_native'
      if self.error~=tostring(why) then self.error=tostring(why);log('first-person camera failed: '..self.error) end
    end
    if self.trace and self.ticks%15==0 then
      local success,value=pcall(self.state,self)
      if success then value.tick=self.ticks;self.trace:write(require('dkjson').encode(value)..'\n');self.trace:flush() end
      if self.ticks>=self.trace_until then self.trace:close();self.trace=nil end
    end
  end)
  log('camera ready: F5 MC first-person / PBZ native; default native')
  return self
end
return M
