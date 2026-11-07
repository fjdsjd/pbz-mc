-- Production inventory and hotbar. Every item intent uses the campaign store.
-- Original MC resources and a realtime preview are shared with the host UI.
local M={}
local instance,data,interaction,loop,close_pending
local slots=require('rules.container_slots')
local definitions=require('content.items')
local input
local json=require('dkjson')
local campaign=require('host.pbz.campaign_inventory')
local auto_defense=require('host.pbz.auto_defense')
local revision=0
local controls,controls_binding,controls_pc,controls_pc_id,controls_loop,controls_controller,controls_stats
local controls_load_epoch
local controls_group,controls_epoch,shown,render_revision='mc',0,true,-1
local controls_width,controls_height,controls_camera
local controls_fault,stopping
local keep_ui_on_close
local selector,selection_context,combat
local display_binding,display_pc
local command_session
local ui_retry_at
local function camera() return require('host.pbz.first_person_camera').get() end
function M.view_state() return data end
function M.pick_target(binding)
  if not combat or combat.binding~=binding then return end
  local building=require('host.pbz.building_service').get(binding)
  if not building then return end
  local _,handle=building:target(function()return combat:aim()end)
  if handle then
    local record=building.session.data.buildings[handle.id]
    return record and {content_id=record.content_id,metadata=require('storage.state').object()}
  end
end
function M.combat_presentation() return combat and combat.presentation end
function M.equipment_available(binding)
  return not command_session and controls_binding==binding and controls_group=='mc' and not (selector and selector.pending)
end
function M.command_state()
  return {open=command_session~=nil,text=command_session and command_session.editor.text,
    mode=controls_binding and campaign.game_mode(controls_binding),native=controls and controls.last.command_controls}
end
function M.reset_fall_after_teleport(binding)
  binding.mc_wind_lift=nil
  if combat and combat.binding==binding then combat.fall_state=nil end
  local c=require('host.pbz.first_person_camera').get()
  if c and c.flight and c.flight.binding==binding then c.flight:reset_fall()end
end
function M.combat_state()
  return combat and {fired=combat.fired,hits=combat.hits,projectiles=#combat.projectiles,
    damage=combat.damage.report,shield=combat.shield and combat.shield.report,error=combat.error,presentation=combat.presentation}
end
local function current_binding()
  local lifecycle=require('host.pbz.appearance_lifecycle').get()
  return lifecycle and lifecycle:current()
end
local function local_controller(binding)
  local pc=binding.actor.Controller
  if pc and pc:IsValid() and pc:IsLocalPlayerController()
    and require('host.pbz.object_identity').matches(pc.Pawn,binding.actor_id) then return pc end
end
local function cleanup()
  if instance then
    if keep_ui_on_close and instance:valid() then instance:set_visible(false)
    else instance:close();instance=nil end
  end
  if interaction and interaction.lease then
    if not interaction.lease:release() then return false end
  end
  if campaign.enabled() then
    local ok,why=campaign.reconcile()
    if not ok then return false end
  end
  interaction=nil;close_pending=nil;keep_ui_on_close=nil;render_revision=-1
  if camera() then camera().inventory=false end
  if loop then CancelDelayedAction(loop);loop=nil end
  return true
end
local function request_close(normal,log)
  keep_ui_on_close=normal and shown and not stopping
  campaign.close(normal)
  close_pending=true
  if not cleanup() then log('inventory input release waits for game focus and released buttons') end
end
local function dispatch(request,log)
  if request.kind=='close' then return request_close(true,log) end
  campaign.dispatch(interaction.binding,request)
  data,revision=campaign.view(interaction.binding)
end
local function tick(log)
  if close_pending then cleanup();return end
  if not interaction then return end
  if not instance or not instance:valid() or not interaction.binding:is_current()
    or (campaign.enabled() and not campaign.current(interaction.binding)) then request_close(false,log);return end
  local batch=controls and controls:read() or input.events()
  if camera() then camera():input(batch,false,controls_epoch) end
  interaction.input_stats={};for key,value in pairs(batch) do if key~='samples' then interaction.input_stats[key]=value end end
  if batch.overflow then interaction.controller=require('presentation.inventory_pointer').new() end
  local function normalize(pointer)
    local copy={};for key,value in pairs(pointer) do copy[key]=value end;pointer=copy
    if pointer.focused then
    -- Win32 coordinates use the host DPI context. Normalize into the physical
    -- viewport coordinates used by the original artwork and hit rectangles.
      pointer.x=pointer.x*instance.viewport.width/pointer.width
      pointer.y=pointer.y*instance.viewport.height/pointer.height
    end
    return pointer
  end
  local samples=batch.samples or {}
  samples[#samples+1]=batch.latest
  for _,pointer in ipairs(samples) do
    local requests=interaction.controller:update(normalize(pointer),data,instance.layout)
    for _,request in ipairs(requests) do
      local ok,why=pcall(function()
        if request.kind=='catalogue_category' or request.kind=='catalogue_page'then
          if instance:set_catalogue(request)then
            -- View navigation is not an inventory/storage transaction. Rebuild
            -- this page before processing the next queued click in the batch.
            instance:render(data,{inventory=true,preview_binding=interaction.preview_binding,pointer=normalize(pointer)})
            interaction.feedback_signature=nil
          end
        else dispatch(request,log)end
      end)
      if not ok then log('inventory intent rejected: '..tostring(why)) end
      if close_pending or not interaction then return end
    end
  end
  local pointer=normalize(batch.latest)
  local feedback=interaction.controller:feedback(pointer,data,instance.layout,definitions)
  local previous=interaction.pointer
  local changed=not previous or previous.focused~=pointer.focused or previous.inside~=pointer.inside
    or previous.x~=pointer.x or previous.y~=pointer.y
  local resized=pointer.focused and (pointer.width~=interaction.window_width or pointer.height~=interaction.window_height)
  if interaction.revision~=revision or (data.cursor and changed) or resized or interaction.feedback_signature~=feedback.signature then
    instance:render(data,{inventory=true,preview_binding=interaction.preview_binding,pointer=pointer,feedback=feedback})
    interaction.revision=revision
  end
  if instance.preview then instance.preview:set_pointer(pointer,instance.layout) end
  interaction.feedback_signature=feedback.signature
  interaction.pointer=pointer
  if pointer.focused then interaction.window_width,interaction.window_height=pointer.width,pointer.height end
end
local function begin(binding,preview,log)
  assert(not interaction and not close_pending,'inventory-release-pending')
  input=require('host.pbz.inventory_input')
  interaction={binding=binding,preview_binding=preview,controller=require('presentation.inventory_pointer').new()}
  if combat then combat:cancel('inventory') end
  if camera() then camera().inventory=true;camera():release_movement() end
  loop=LoopInGameThreadAfterFrames(1,function()
    local ok,why=pcall(tick,log)
    if not ok then
      if interaction and interaction.last_error~=tostring(why) then interaction.last_error=tostring(why);log('inventory input failed: '..tostring(why)) end
      close_pending=true;pcall(cleanup)
    end
  end)
  assert(controls and controls_binding==binding,'item-input-not-ready')
  controls:set_context('inventory')
  interaction.lease=input.acquire(instance,binding,log,{external_events=true,pointer=function() return controls:read().latest end,
    quarantine_held=function()
      if not controls or controls.closed or controls_group~='mc' or not controls.last
          or controls.last.protocol~=2 or not controls.last.first_person_controls then return false end
      controls:set_context('inactive') -- Native queue keeps held controls blocked until their release.
      return true
    end})
  assert(not interaction.lease.creation_failure,interaction.lease.creation_failure)
  if campaign.enabled() then campaign.open(binding,interaction.lease) end
end
function M.start(log,directory)
  assert(not controls_loop,'item-input-monitor-already-started')
  campaign.start(log,directory)
  local lifecycle=require('host.pbz.appearance_lifecycle').get()
  local pose_clock={}
  local presentation_source=function(binding)
    if binding~=lifecycle:current() then return end
    if display_binding~=binding then display_binding=binding;display_pc=local_controller(binding) end
    if not display_pc then return end
    if not data or binding~=controls_binding then
      local ready,value,generation=pcall(campaign.view,binding)
      if not ready then return end
      data,revision=value,generation
    end
    local current_camera=camera()
    local native_owner=not current_camera or current_camera:native_takeover() or current_camera:traversal(binding)
    local selected=slots.get(data,'player/hotbar/'..data.player.selected)
    local minecraft=not require('rules.native_slot_reference').is(selected)
    binding.suppress_native_weapons=minecraft and not native_owner
    if (not minecraft and not binding.mc_boat_riding and not binding.mc_gliding) or native_owner
        or current_camera:is_active() and not binding.mc_boat_riding and not binding.mc_gliding then pose_clock={};return end
    if pose_clock.binding~=binding then pose_clock={binding=binding} end
    local source=combat and combat.presentation or {group='mc',main=selected,offhand=slots.get(data,'player/offhand')}
    local frame={};for key,value in pairs(source) do frame[key]=value end
    frame.group='mc'
    local game=StaticFindObject('/Script/Engine.Default__GameplayStatics');local now=game:GetTimeSeconds(binding.actor)
    if binding.mc_command_presentation then frame=binding.mc_command_presentation:apply_frame(frame,now)end
    local dt=pose_clock.now and math.max(0,math.min(.1,now-pose_clock.now)) or 0;pose_clock.now=now
    local look=display_pc.ControlRotation;frame.look={Pitch=look.Pitch,Yaw=look.Yaw,Roll=look.Roll}
    local velocity=binding.actor:GetVelocity()
    local walk=require('presentation.minecraft_third_person_pose').locomotion(pose_clock,dt,
      {yaw=look.Yaw,vx=velocity.X,vy=velocity.Y,
        aiming=(frame.swing or 0)>0 or (frame.bow_charge or 0)>0 or (frame.trident_charge or 0)>0 or (frame.spear_charge or 0)>0})
    for key,value in pairs(walk) do frame[key]=value end
    frame.crouching=current_camera.movement and current_camera.movement.frame and current_camera.movement.frame.sneak or false
    if binding.mc_gliding then
      frame.gliding=true;frame.crouching=false;frame.velocity=binding.mc_gliding.velocity
      frame.glide_ticks=binding.mc_gliding.physics.ticks;frame.partial_tick=1-(binding.mc_gliding.accumulator or 0)/.05
    end
    if binding.mc_boat_riding then
      frame.riding=true;frame.crouching=false;frame.speed=0;frame.walk_amplitude=0
      frame.body_yaw=binding.mc_boat_riding.yaw
    end
    return frame
  end
  lifecycle.presentation_source=presentation_source
  local last_error
  local load_notice=require('host.pbz.inventory_load_notice').new(directory,log)
  local function defense_notice(message,kind,duration)
    if not instance or not instance:valid() or not controls_binding then return end
    instance.command_layer=instance.command_layer or require('host.pbz.command_ui').new(instance)
    instance.command_message=message
    instance.command_message_until=StaticFindObject('/Script/Engine.Default__GameplayStatics'):GetRealTimeSeconds(controls_binding.actor)+(duration or 2)
  end
  local monitor_closed=false
  local function acquire_combat()
    if not combat then combat=require('host.pbz.minecraft_combat').new(controls_binding,controls_pc,controls_epoch,log) end
    return combat
  end
  local function acquire_summons() return acquire_combat():summon_group() end
  controls_loop=LoopInGameThreadAfterFrames(1,function()
    if monitor_closed then return end
    auto_defense.begin_frame()
    local ok,why=pcall(function()
      if stopping then
        load_notice:close()
        auto_defense.suspend()
        if command_session then if not command_session:close()then return end;command_session=nil end
        if not cleanup() then return end
        assert(require('host.pbz.tnt_service').close(),'tnt-cleanup-pending')
        assert(require('host.pbz.building_service').close(),'building-cleanup-pending')
        assert(require('host.pbz.boat_service').close(),'boat-cleanup-pending')
        if lifecycle.presentation_source==presentation_source then lifecycle.presentation_source=nil end
        if controls_binding then controls_binding.suppress_native_weapons=false end
        if combat then combat:close();combat=nil end
        if selector then selector:close();selector=nil end
        if controls then controls:close();controls=nil end
        controls_binding=nil;controls_pc=nil;controls_pc_id=nil;controls_controller=nil
        monitor_closed=true;CancelDelayedAction(controls_loop);controls_loop=nil;stopping=nil
        log('item input monitor stopped; native message hook released');return
      end
      local binding=current_binding()
      local bound=binding and binding:is_current()
      local epoch_changed=controls and controls_load_epoch~=campaign.load_epoch()
      if command_session and (not bound or binding~=controls_binding or epoch_changed or not campaign.current(binding))then
        if not command_session:close()then return end
        command_session=nil
      end
      if command_session then
        local command_service=require('host.pbz.command_service').get(controls_binding)
        if command_service then
          command_service:tick(StaticFindObject('/Script/Engine.Default__GameplayStatics'):GetTimeSeconds(controls_binding.actor))
          require('host.pbz.building_service').ensure(controls_binding,directory,log,acquire_summons)
        end
        local success,err=pcall(command_session.tick,command_session)
        if not success then command_session.closing=true;log('MC command failed: '..tostring(err));pcall(command_session.close,command_session)end
        if command_session.closed then command_session=nil;render_revision=-1;controls_controller=require('presentation.hotbar_input').new()end
        return
      end
      if not bound or not campaign.notice()then load_notice:close()end
      local controller=bound and local_controller(binding) or nil
      if controls and (binding~=controls_binding or not bound or epoch_changed
          or not require('host.pbz.object_identity').matches(controller,controls_pc_id)) then
        assert(require('host.pbz.building_service').close(),'building-lifecycle-cleanup-pending')
        assert(require('host.pbz.tnt_service').close(),'tnt-lifecycle-cleanup-pending')
        assert(require('host.pbz.boat_service').close(),'boat-lifecycle-cleanup-pending')
        if combat then combat:close();combat=nil end
        if selector then selector:close();selector=nil end
        shown=true;controls_group='mc';controls_epoch=controls_epoch+1;request_close(false,log)
        if close_pending then return end
        controls:close();controls=nil;controls_binding=nil;controls_pc=nil;controls_pc_id=nil;controls_controller=nil;controls_fault=nil
        return -- Native hook retirement must cross a clock tick before Begin.
      end
      if not bound then return end
      if controls_fault then
        if controls then controls:set_context('inactive') end
        if interaction or close_pending then request_close(false,log) end
        return
      end
      if not controls then
        if not require('host.pbz.inventory_input').pointer().focused then
          -- Visual state does not require stealing focus or acquiring input.
          -- Show the saved hotbar/held model after load or a developer refresh
          -- even while the user is reading another window.
          if shown and data and display_binding==binding and camera() and not camera():native_takeover() then
            if instance and not instance:valid() then instance:close();instance=nil end
            if not instance then
              local ready,value=pcall(require('host.pbz.item_ui').new,directory..'/pbzmc-assets/ui',log)
              if ready then instance=value;render_revision=-1 end
            end
            if instance and render_revision~=revision then
              local selected=slots.get(data,'player/hotbar/'..data.player.selected)
              instance:render(data,{inventory=false,crosshair=not require('rules.native_slot_reference').is(selected)})
              render_revision=revision
            end
          end
          return
        end
        local adapter=require('host.pbz.item_controls')
        local identity=require('host.pbz.object_identity')
        assert(controller,'item-input-controller-unavailable')
        controls=adapter.new(adapter.load_bindings(directory..'/pbzmc-data/item-bindings.json'))
        controls_load_epoch=campaign.load_epoch()
        controls_pc=controller;controls_pc_id=identity.capture(controller)
        controls_binding=binding;controls_controller=require('presentation.hotbar_input').new()
        log('production item input ready; group='..controls_group)
      end
      local gameplay=StaticFindObject('/Script/Engine.Default__GameplayStatics')
      local now=gameplay:GetTimeSeconds(binding.actor)
      local commands_pumped=false
      local command_service=require('host.pbz.command_service').get(binding)
      if command_service and campaign.current(binding) and not gameplay:IsGamePaused(controls_pc)then
        command_service:tick(now)
        if binding:is_current()then require('host.pbz.building_service').ensure(binding,directory,log,acquire_summons)end
        commands_pumped=true
      end
      if not binding:is_current()then return end
      if interaction or close_pending then return end -- Inventory loop owns input drains, not world ticks.
      -- Native attacks/weapon stages temporarily ignore locomotion/look. They
      -- do not transfer number keys or wheel ownership back to PBZ bindings.
      local available=controls_pc:IsValid() and not gameplay:IsGamePaused(controls_pc)
        and not controls_pc.bShowMouseCursor and binding.actor.AttributeSetBase.Health.CurrentValue>0
        and (not camera() or not camera():native_takeover())
      if campaign.notice()then
        load_notice:update(binding,campaign.notice(),available,gameplay:GetRealTimeSeconds(binding.actor))
      end
      if campaign.enabled() and available then
        local ready,why=pcall(function() data,revision=campaign.view(binding) end)
        if not ready then
          controls:set_context('inactive')
          if instance then instance:close();instance=nil end
          if last_error~=tostring(why) then last_error=tostring(why);log('formal inventory waiting: '..last_error) end
          return
        end
        local buildings=commands_pumped and require('host.pbz.building_service').get(binding)
          or require('host.pbz.building_service').ensure(binding,directory,log,acquire_summons)
        require('host.pbz.command_service').ensure(binding,buildings,directory,acquire_summons,log,defense_notice)
        require('host.pbz.tnt_service').ensure(binding,directory,log)
        require('host.pbz.boat_service').ensure(binding,directory,log)
      end
      local selected=data and slots.get(data,'player/hotbar/'..data.player.selected)
      controls_group=require('rules.native_slot_reference').is(selected) and 'pbz' or 'mc'
      local first=camera() and camera():mc_controls() and not (selector and selector.pending)
      local traversal=camera() and camera():traversal(binding)
      controls:set_context(available and (binding.mc_creative_flight and controls_group=='pbz' and 'game-creative-pbz' or first and 'game-first-person' or
        ((controls_group=='pbz' or traversal) and 'game-pbz-hotbar' or 'game-mc')) or 'inactive')
      local batch=controls:read();local samples={}
      if available and binding.command_block_edit then
        local commands=require('host.pbz.command_service').get(binding)
        local block=commands and commands.build.session.data.buildings[binding.command_block_edit]
        binding.command_block_edit=nil
        if block then
          if selector and selector.pending then selector:abort('command-block-opened')end
          if combat then combat:cancel('command')end
          if not instance or not instance:valid()then instance=require('host.pbz.item_ui').new(directory..'/pbzmc-assets/ui',log)end
          instance:render(data,{inventory=false,crosshair=false})
          local success,value=pcall(require('host.pbz.command_console').new,instance,binding,controls,camera(),log,{service=commands,block=block})
          if success then command_session=value else log('MC command editor unavailable: '..tostring(value))end
          return
        end
      end
      for _,sample in ipairs(batch.samples) do samples[#samples+1]=sample end
      if instance and instance.quick_help then instance.quick_help:input(batch,available,controls_epoch)end
      if camera() then camera():input(batch,available,controls_epoch) end
      local boats=require('host.pbz.boat_service').get(binding)
      if boats then boats:input_batch(batch,available and not (selector and selector.pending),controls_group,data) end
      controls_stats={};for key,value in pairs(batch) do if key~='samples' then controls_stats[key]=value end end
      samples[#samples+1]=batch.latest
      local context={kind=available and 'game' or 'inactive',weapon_group=controls_group,epoch=controls_epoch,unified_hotbar=true}
      selection_context=context
      if selector and selector.pending and available and batch.latest.focused then
        selector:tick(now)
        data,revision=campaign.view(binding)
      end
      if batch.overflow then controls_controller=require('presentation.hotbar_input').new() end
      for _,pointer in ipairs(samples) do
        for _,request in ipairs(controls_controller:update(pointer,context)) do
          if request.kind=='open_command'then
            if selector and selector.pending then selector:abort('command-opened')end
            if combat then combat:cancel('command')end
            if not instance or not instance:valid()then instance=require('host.pbz.item_ui').new(directory..'/pbzmc-assets/ui',log)end
            instance:render(data,{inventory=false,crosshair=false})
            local success,value=pcall(require('host.pbz.command_console').new,instance,binding,controls,camera(),log,
              {service=require('host.pbz.command_service').get(binding)})
            if success then command_session=value else log('MC command unavailable: '..tostring(value))end
            return
          end
          if selector and selector.pending then
            if request.kind=='open_inventory' then selector:abort('inventory-opened')
            else selector:queue(request);break end
          end
          if request.kind=='open_inventory' then M.command('avatar_ui_preview',log,directory);return end
          local success,why=pcall(function()
            if request.kind=='select_slot' or request.kind=='scroll_slots' then
              local index=request.kind=='select_slot' and request.index or ((data.player.selected-1+request.steps)%9)+1
              local refs=require('rules.native_slot_reference')
              if refs.is(slots.get(data,'player/hotbar/'..data.player.selected)) or refs.is(slots.get(data,'player/hotbar/'..index)) then
                if not selector then selector=require('host.pbz.hotbar_equipment').new(binding,controls_pc,controls_epoch,
                  function() return selection_context end,log) end
                if selector:request(request,data,revision,context,now) then return end
              end
            end
            return campaign.dispatch(binding,request,context)
          end)
          if success then data,revision=campaign.view(binding)
          else log('hotbar intent rejected: '..tostring(why)) end
        end
      end
      if data then
        local healthy_keys=not batch.overflow and not batch.timed_out_since_read
        local pbz_selected=require('rules.native_slot_reference').is(slots.get(data,'player/hotbar/'..data.player.selected))
        auto_defense.update(binding,controls_pc,available and batch.latest.focused,
          pbz_selected and controls_group=='pbz' and not (selector and selector.pending) and not traversal
          and not binding.mc_boat_riding and not binding.mc_gliding and not binding.mc_creative_flight,
          now,defense_notice,log,healthy_keys)
        local off=slots.get(data,'player/offhand')
        local flight_rocket=binding.mc_gliding and binding.mc_gliding.active and off and off.content_id=='pbzmc:firework_rocket'
        local allowed=available and first and (controls_group=='mc' or flight_rocket) and not (selector and selector.pending)
        local success,why=pcall(function()
          if allowed then acquire_combat() end
          if combat and not combat.error then combat:update(batch,data,revision,context,allowed) end
        end)
        if not success then
          if combat then combat.error=tostring(why);combat:cancel('adapter-error') end
          log('MC combat adapter unavailable: '..tostring(why))
        end
      end
      if not available then
        if instance then instance:set_visible(false);render_revision=-1 end
        return
      end
      if shown and batch.latest.focused and batch.latest.width>=320 and batch.latest.height>=240 then
        if instance and not instance:valid() then instance:close();instance=nil end
        if not instance then
          if ui_retry_at and now<ui_retry_at and now>=ui_retry_at-0.25 then return end
          local ready,value=pcall(require('host.pbz.item_ui').new,directory..'/pbzmc-assets/ui',log)
          if not ready then
            if tostring(value):find('live-pbz-overlay-unavailable',1,true) then ui_retry_at=now+.25;return end
            error(value)
          end
          ui_retry_at=nil
          instance=value;render_revision=-1
        end
        local pointer=batch.latest
        local first_person=camera() and camera():is_active() or false
        if render_revision~=revision or controls_width~=pointer.width or controls_height~=pointer.height or controls_camera~=first_person then
          instance:render(data,{inventory=false,crosshair=first_person or controls_group=='mc'});render_revision=revision;controls_camera=first_person
          controls_width,controls_height=pointer.width,pointer.height
        end
        if instance.command_layer then
          local real=gameplay:GetRealTimeSeconds(binding.actor)
          local message=instance.command_message_until and real<instance.command_message_until and instance.command_message or nil
          instance.command_layer:render(nil,real,message)
        end
      end
    end)
    if not ok then
      controls_fault=tostring(why)
      if controls then pcall(controls.set_context,controls,'inactive') end
      if last_error~=controls_fault then last_error=controls_fault;log('item input monitor failed: '..last_error) end
    end
  end)
end
function M.command(command,log,directory,diagnostic_group)
  if command=='avatar_inventory_enable' or command=='avatar_inventory_take_arrows' then
    assert(not interaction and not close_pending,'close-inventory-before-formal-setup')
    local binding=assert(current_binding(),'formal-current-player-required')
    if command=='avatar_inventory_enable' then
      request_close(false,log);assert(not close_pending,'formal-setup-release-pending');campaign.enable(binding)
    else campaign.take_arrows(binding) end
    data,revision=campaign.view(binding)
    return M.command('avatar_ui_hotbar',log,directory)
  end
  if command=='avatar_inventory_observe' then campaign.observe();return end
  if command=='avatar_ui_stop' then
    if not controls_loop and not controls and not interaction and not instance and not close_pending and not loop then stopping=nil;return end
    shown=false;stopping=true;controls_group='pbz';controls_epoch=controls_epoch+1
    request_close(false,log)
    return
  end
  if command=='avatar_ui_start' then
    assert(not stopping,'item-input-stop-pending');controls_fault=nil
    if not controls_loop then M.start(log,directory) end
    return
  end
  if command=='avatar_ui_controls_mc' or command=='avatar_ui_controls_pbz' then
    assert(controls_loop and controls,'item-input-not-ready-use-avatar_ui_start')
    assert(not interaction and not close_pending,'close-inventory-before-input-context-change')
    local group=command=='avatar_ui_controls_mc' and 'mc' or 'pbz'
    log('development input controls group='..group..'; not a combat equipment handoff')
    return M.command('avatar_ui_hotbar',log,directory,group)
  end
  if command=='avatar_ui_preview_unlit' then
    assert(instance and instance.preview,'preview-not-created');instance.preview:configure_unlit();return
  end
  if command=='avatar_ui_items_observe' then
    local state={fixture=false,formal=true,revision=revision,data=data,opened=interaction~=nil,close_pending=close_pending or false,
      pointer=interaction and interaction.pointer,input_stats=interaction and interaction.input_stats or controls_stats,layout=instance and instance.layout,
      controls_group=controls_group,controls_context=controls and controls.context,bindings=controls and controls.bindings.names,
      selector=selector and selector:state(),
      controls_fault=controls_fault,stopping=stopping or false}
    local file=assert(io.open(directory..'/pbzmc-data/inventory-ui-state.json','w'))
    assert(file:write(json.encode(state)));assert(file:close());log('production inventory state revision='..revision);return
  end
  if command=='avatar_ui_preview_rgb' then
    assert(instance and instance.preview,'preview-not-created')
    instance.preview:use_rgb_material();return
  end
  if command=='avatar_ui_preview_hdr' or command=='avatar_ui_preview_ldr' then
    assert(instance and instance.preview,'preview-not-created')
    instance.preview:set_capture_source(command=='avatar_ui_preview_hdr' and 'SCS_SceneColorHDR' or 'SCS_FinalColorLDR')
    log('preview capture source changed '..instance.preview.capture_source);return
  end
  if command=='avatar_ui_preview_observe' then
    assert(instance and instance.preview,'preview-not-created')
    local value=instance.preview:state()
    local json=require('dkjson');local file=assert(io.open(directory..'/pbzmc-data/preview-state.json','w'))
    assert(file:write(json.encode(value)));assert(file:close())
    log('preview state '..json.encode(value));return
  end
  if command=='avatar_ui_clear' then
    shown=false
    controls_group='pbz';controls_epoch=controls_epoch+1
    controls_controller=require('presentation.hotbar_input').new()
    request_close(true,log)
    if controls and not interaction then controls:set_context('inactive') end
    return
  end
  assert(command=='avatar_ui_hotbar' or command=='avatar_ui_inventory' or command=='avatar_ui_resources' or command=='avatar_ui_preview','unknown-item-ui-command')
  assert(controls_loop and controls,'item-input-not-ready-use-avatar_ui_start')
  assert(not stopping,'item-input-stop-pending')
  controls_fault=nil
  if close_pending then assert(cleanup(),'inventory-release-pending') end
  assert(command~='avatar_ui_resources','development-fixture-removed-use-give')
  data,revision=campaign.view(assert(current_binding(),'formal-current-player-required'))
  -- Item keys are active immediately and after each controller replacement.
  controls_group=diagnostic_group or 'mc';controls_epoch=controls_epoch+1
  controls_controller=require('presentation.hotbar_input').new()
  shown=true;render_revision=-1
  local binding
  if command~='avatar_ui_hotbar' then
    binding=assert(require('host.pbz.appearance_lifecycle').get():current(),'preview-current-appearance-required')
    assert(binding:is_current(),'preview-appearance-stale')
  end
  if instance and not instance:valid() then instance:close();instance=nil end
  if not instance then instance=require('host.pbz.item_ui').new(directory..'/pbzmc-assets/ui',log) end
  local ok,err=pcall(function()
    if command=='avatar_ui_hotbar' and interaction then
      request_close(true,log);assert(not close_pending,'inventory-release-pending')
      instance=require('host.pbz.item_ui').new(directory..'/pbzmc-assets/ui',log)
    end
    local preview=command=='avatar_ui_preview' and binding or nil
    if binding and not interaction then begin(binding,preview,log) end
    instance:render(data,{inventory=command~='avatar_ui_hotbar',preview_binding=preview})
  end)
  if not ok then close_pending=true;pcall(cleanup);error(err) end
end
return M
