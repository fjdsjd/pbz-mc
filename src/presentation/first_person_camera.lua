-- Camera/visual math only. No actor orientation, input or damage writes.
local rigid=require('presentation.rigid_transform')
local spears=require('presentation.minecraft_spear_animation')
local M={}
local cached_layout
local vertical_tangent=math.tan(math.rad(103)/2)/(16/9)
local default_span=90*vertical_tangent*(16/10)*.68
function M.viewport_layout(width,height)
  assert(type(width)=='number' and type(height)=='number' and width==width and height==height,'invalid-first-person-viewport')
  -- Unfocused native input snapshots report 0x0 (the old adapter clamped this
  -- to 1x1). Keep the last real viewport instead of changing FOV/hand spacing.
  if width<320 or height<240 then
    if cached_layout then return cached_layout end
    width,height=1920,1080
  end
  if cached_layout and cached_layout.width==width and cached_layout.height==height then return cached_layout end
  local aspect=width/height
  cached_layout={width=width,height=height,aspect=aspect,
    fov=math.deg(2*math.atan(vertical_tangent*aspect)),
    -- Anchor the holder at +/-68% of horizontal clip space (16%/84% of
    -- viewport width). Model extent then leaves roughly 1/2..3/4 in view.
    hand_span=90*vertical_tangent*math.max(.75,math.min(21/9,aspect))*.68,
    arm_span=70*vertical_tangent*math.max(.75,math.min(21/9,aspect))*.88}
  return cached_layout
end
function M.view(location,half_height,rotation,width,height)
  assert(half_height>0 and width>0 and height>0,'invalid-first-person-view')
  local layout=M.viewport_layout(width,height)
  return {position={X=location.X,Y=location.Y,Z=location.Z+half_height*.74},
    rotation={Pitch=rotation.Pitch,Yaw=rotation.Yaw,Roll=0},fov=layout.fov,hand_span=layout.hand_span,arm_span=layout.arm_span,viewport_layout=layout}
end
function M.arm(camera,left,state)
  -- Original SteveMesh empty-hand swing, with its base moved forward so the
  -- complete arm stays beyond PBZ's near plane after first-person depth scale.
  local swing=state and state.swing or 0
  if state and state.swing_hand=='offhand' and not left then swing=0 end
  local lift=math.sin(math.max(0,math.min(1,swing))*math.pi)
  local side=camera.arm_span or default_span
  return rigid.compose(camera,{position={X=70-lift*18,Y=left and -side or side,Z=-42+lift*10},
    rotation={Pitch=65+lift*45,Yaw=left and 8 or -8,Roll=0}})
end
-- Pinned SteveMesh first-person swing/charge curves. Camera-holder translation
-- is calibrated for PBZ's aspect-correct FOV; original item display stays intact.
local holder_cache
function M.holders(state,camera)
  local side=camera and camera.hand_span or default_span
  local swing=state.swing or 0
  local off_swing=swing>0 and state.swing_hand=='offhand'
  local bow=state.bow_charge or 0;local ticks=bow>0 and (state.bow_ticks or 0) or 0
  local eating=state.eating or 0;local hand=eating>0 and state.use_hand or nil
  local charge,weight=spears.use(state)
  local jab=state.spear_jab or 0
  local spear=(charge>0 or jab>0) and state.main and state.main.content_id or nil
  local stats=spear and require('content.combat_profiles').get(spear).spear
  if stats then charge=spears.sample_time(stats,charge) end
  local recoil=charge>0 and state.spear_recoil or 10
  if holder_cache and holder_cache.side==side and holder_cache.swing==swing and holder_cache.off_swing==off_swing and holder_cache.bow==bow
    and holder_cache.ticks==ticks and holder_cache.eating==eating and holder_cache.hand==hand
    and holder_cache.spear==spear and holder_cache.charge==charge and holder_cache.jab==jab
    and holder_cache.recoil==recoil and holder_cache.weight==weight then return holder_cache.value end
  local wave,strike=math.sin(math.sqrt(swing)*math.pi),math.sin(swing*math.pi)
  local sign=off_swing and -1 or 1
  local moving={position={X=90+strike*20,Y=sign*(side-wave*40),Z=-48+math.sin(math.sqrt(swing)*math.pi*2)*20},
    rotation={Pitch=-wave*80,Yaw=-sign*math.sin(swing*swing*math.pi)*20,Roll=-sign*wave*20}}
  local resting={position={X=90,Y=-sign*side,Z=-48},rotation={Pitch=0,Yaw=0,Roll=0}}
  local main=off_swing and resting or moving
  if stats then
    main=spears.first_person(stats,charge,jab,recoil,side,weight)
  elseif bow>0 then
    local power=math.min(1,(bow*bow+2*bow)/3)
    local shake=power>.1 and math.sin(((state.bow_ticks or 0)-.1)*1.3)*(power-.1)*.4 or 0
    local r=rigid.compose({position={X=0,Y=0,Z=0},rotation={Pitch=-13.935,Yaw=0,Roll=0}},
      {position={X=0,Y=0,Z=0},rotation={Pitch=0,Yaw=-35.3,Roll=0}})
    r=rigid.compose(r,{position={X=0,Y=0,Z=0},rotation={Pitch=0,Yaw=0,Roll=9.785}})
    local delta=rigid.rotate(r.rotation,{X=-power*4,Y=0,Z=shake})
    main={position={X=90-15.731531+delta.X,Y=side-27.85682+delta.Y,Z=-48+18.344387+delta.Z},rotation=r.rotation}
  end
  local holders={main=main,offhand=off_swing and moving or resting}
  if eating>0 then
    -- MC HeldItemRenderer's 27th-power mouth approach and four-tick bite bob,
    -- using the pinned SteveMesh camera holder conversion. No gameplay writes.
    local remaining=1-math.min(1,eating);local progress=1-remaining^27
    local bob=remaining<.8 and math.abs(math.cos(remaining*32/4*math.pi)) * 3 or 0
    local hand=state.use_hand=='offhand' and 'offhand' or 'main';local sign=hand=='main' and 1 or -1
    -- PBZ's world-space hand is much larger than the MC GUI hand. Keep the
    -- original approach/bite timing but bound the pose to its lower corner;
    -- Translation remains on its own side while the 90-degree turn cancels
    -- item/generated's original first-person side-on display orientation.
    holders[hand]={position={X=90-progress*8,Y=sign*(side-progress*6),Z=-48+progress*8+bob},
      rotation={Pitch=progress*10,Yaw=sign*progress*90,Roll=sign*progress*10}}
  end
  holder_cache={side=side,swing=swing,off_swing=off_swing,bow=bow,ticks=ticks,eating=eating,hand=hand,
    spear=spear,charge=charge,jab=jab,recoil=recoil,weight=weight,value=holders}
  return holders
end
return M
