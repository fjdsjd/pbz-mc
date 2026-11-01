-- Pure third-person part animation from SteveMesh.Update, wukong-steve 0.11.0.
-- Pinned commit 9f213556519dca4498fd46f02af6236ae121ecae, PolyForm Noncommercial.
-- No host mesh writes, native root-motion changes, input or damage dispatch.
local native=require('presentation.native_steve_pose')
local rigid=require('presentation.rigid_transform')
local spear_animation=require('presentation.minecraft_spear_animation')
local profiles=require('content.combat_profiles')
local M={}
local function combat_profile(stack)
  -- A seated PBZ slot is only a native equipment reference, never an MC item.
  return profiles.get(stack and not require('rules.native_slot_reference').is(stack) and stack.content_id or nil)
end
local function number(value)
  assert(type(value)=='number' and value==value and math.abs(value)<math.huge,'invalid-minecraft-pose-number')
  return value
end
local function clamp(v,a,b) return math.max(a,math.min(b,v)) end
local function f32(value) return string.unpack('<f',string.pack('<f',value)) end
function M.advance(clock,dt,speed)
  assert(number(dt)>=0 and number(speed)>=0,'invalid-minecraft-pose-time-or-speed')
  return {age=number(clock.age)+dt*20,stride=number(clock.stride)+speed/100*dt*4}
end
local function angle(value) return (value+180)%360-180 end
-- Vanilla 26.3 LivingEntity.tickHeadTurn / WalkAnimationState, adapted from
-- the user's local client: 20 Hz body easing (.3), head/body limit (50 deg),
-- walking envelope (.4) and interpolation between simulation ticks. Units
-- here are UE centimetres; only presentation changes, never physics or aim.
function M.locomotion(clock,dt,motion)
  number(dt);assert(dt>=0 and dt<=.1,'invalid-locomotion-delta')
  local look=number(motion.yaw)
  local speed=math.sqrt(number(motion.vx)^2+number(motion.vy)^2)
  if not clock.body then
    clock.body=look;clock.previous_body=look;clock.speed=0;clock.previous_speed=0
    clock.position=0;clock.previous_position=0;clock.remainder=0;clock.age=0
  end
  clock.age=clock.age+dt*20;clock.remainder=clock.remainder+dt
  while clock.remainder+1e-9>=.05 do
    clock.remainder=math.max(0,clock.remainder-.05)
    clock.previous_body=clock.body;clock.previous_speed=clock.speed;clock.previous_position=clock.position
    local target=clock.body
    if speed>100 then -- Vanilla: horizontal displacement squared > .0025.
      target=math.deg(math.atan(motion.vy,motion.vx))
      if math.abs(angle(look-target))>95 then target=target+180 end
    end
    if motion.aiming then target=look end
    clock.body=clock.body+angle(target-clock.body)*.3
    local head=angle(look-clock.body)
    clock.body=clock.body+head-clamp(head,-50,50)
    clock.speed=clock.speed+(math.min(speed/500,1)-clock.speed)*.4
    clock.position=clock.position+clock.speed
  end
  local partial=clock.remainder/.05
  return {body_yaw=clock.previous_body+angle(clock.body-clock.previous_body)*partial,
    walk_amplitude=clock.previous_speed+(clock.speed-clock.previous_speed)*partial,
    stride=clock.previous_position+(clock.position-clock.previous_position)*partial,age=clock.age}
end
function M.solve(parts,state)
  local scale=native.scale
  local anchor=state.anchor
  if state.riding then
    -- Lower the visual hip to the seat while retaining an upright, clear
    -- native capsule for damage and safe dismount collision tests.
    anchor=rigid.compose(anchor,{position={X=0,Y=0,Z=-12*scale},rotation={Pitch=0,Yaw=0,Roll=0}})
  end
  local age,stride=number(state.age),number(state.stride)
  local speed=number(state.speed);assert(speed>=0,'invalid-minecraft-pose-speed')
  local amplitude=state.walk_amplitude or math.min(1,speed/100/4.317)
  local swing=number(state.swing or 0);assert(swing>=0 and swing<=1,'invalid-minecraft-swing')
  local eating=number(state.eating or 0);assert(eating>=0 and eating<=1,'invalid-minecraft-eating')
  local bow,trident=number(state.bow_charge or 0),number(state.trident_charge or 0)
  local charge,jab=number(state.spear_charge or 0),number(state.spear_jab or 0)
  assert(bow>=0 and trident>=0 and charge>=0 and jab>=0 and jab<=1,'invalid-minecraft-use-progress')
  local profile=combat_profile(state.main)
  local spear=profile.kind=='spear'
  local body_yaw=swing>0 and not spear and math.sin(math.sqrt(swing)*math.pi*2)*.2 or 0
  local head_yaw=math.rad(clamp((number(state.look.Yaw)-number(state.actor_yaw)+540)%360-180,-75,75))
  local head_pitch=-math.rad(clamp((number(state.look.Pitch)+540)%360-180,-60,60))
  local main_shield=state.main and state.main.content_id=='pbzmc:shield' or false
  local output={}
  for _,part in ipairs(parts) do
    local name=part.name
    local right=name:sub(1,6)=='right_'
    local arm=name:sub(-3)=='arm' or name:sub(-6)=='sleeve'
    local head=name=='head' or name=='hat'
    local x,y,z=0,0,0
    local px,py,pz=-part.pivot.Y/scale,-part.pivot.Z/scale,-part.pivot.X/scale
    if head then y=head_yaw;x=head_pitch end
    if name=='body' or name=='jacket' then y=body_yaw;if state.crouching then x=.5;py=f32(3.2) end end
    if name:sub(-3)=='leg' or name:sub(-5)=='pants' then
      x=math.cos(stride*.6662+(right and 0 or math.pi))*1.4*amplitude
      if state.riding then
        x=-1.4137167;y=(right and 1 or -1)*math.pi/10;z=(right and 1 or -1)*.07853982
      end
      if state.crouching then py=f32(12.2);pz=4 end
    end
    if state.crouching and head then py=f32(4.2) end
    if arm then
      x=math.cos(stride*.6662+(right and math.pi or 0))*amplitude
      if state.riding then x=x-math.pi/5 end
      if state.blocking and right==main_shield then
        x=x*.5-math.pi*.3+clamp(head_pitch,-math.pi*4/9,.43633232)
        y=(right and -1 or 1)*math.pi/6+clamp(head_yaw,-math.pi/6,math.pi/6)
      elseif right or state.offhand then x=x*.5-math.pi/10 end
      x=x+(right and 1 or -1)*math.sin(age*.067)*.05
      z=(right and 1 or -1)*(math.cos(age*.09)*.05+.05)
      if bow>0 then x=-math.pi/2+head_pitch;y=(right and -.1 or .5)+head_yaw;z=0 end
      if trident>0 and right then x=x*.5-math.pi;y=0;z=0 end
      if state.crouching then x=x+.4;py=f32(5.2) end
      if eating>0 and right then x=-1.7+math.abs(math.sin(age*1.5))*.15;y=-.3 end
      if swing>0 and bow<=0 and trident<=0 and not spear then
        px=f32((right and -1 or 1)*math.cos(body_yaw)*5)
        pz=f32((right and 1 or -1)*math.sin(body_yaw)*5)
        y=body_yaw
        if right then
          local ease=1-(1-swing)^4
          x=x-math.sin(ease*math.pi)*1.2-math.sin(swing*math.pi)*-(head_pitch-.7)*.75
          y=y+body_yaw*2;z=z-math.sin(swing*math.pi)*.4
        else x=x+body_yaw end
      end
      if right and spear then
        x=clamp(-math.pi/2+head_pitch+.8,-math.pi*2/3,math.pi/6)
        y=clamp(-.1+head_yaw,-math.pi/3,math.pi/3);z=0
        if charge>0 then
          local p=spear_animation.solve(profile.spear,charge)
          y=y-p.fast*math.pi/180*p.intensity;z=z-p.slow*math.pi/180*p.intensity*.5
          x=x+math.pi/180*(-40*p.start+30*p.middle-20*p.finish+20*p.lower+10*p.back+.6*p.slow*p.intensity)
        end
        if jab>0 then
          local a=spear_animation.in_out_sine(spear_animation.progress(jab,0,.05))
          local b=spear_animation.progress(jab,.05,.2)^2
          local c=spear_animation.in_out_expo(spear_animation.progress(jab,.4,1))
          x=x+(90*a-120*b+30*c)*math.pi/180
        end
      end
    end
    output[name]=rigid.compose(anchor,{position=rigid.vector(-pz*scale,-px*scale,-py*scale),
      rotation={Pitch=-math.deg(x),Yaw=math.deg(y),Roll=-math.deg(z)}})
  end
  return output
end
function M.item_motion(state)
  local profile=combat_profile(state.main)
  if profile.kind~='spear' then return nil end
  local charge,jab=number(state.spear_charge or 0),number(state.spear_jab or 0)
  local recoil=number(state.spear_recoil or 0)
  assert(charge>=0 and jab>=0 and jab<=1 and recoil>=0,'invalid-minecraft-spear-progress')
  local function hand(x,y,z) return rigid.vector(y*16*native.scale,x*16*native.scale,z*16*native.scale) end
  local function add(a,b) return rigid.vector(a.X+b.X,a.Y+b.Y,a.Z+b.Z) end
  local function sub(a,b) return rigid.vector(a.X-b.X,a.Y-b.Y,a.Z-b.Z) end
  local grip,offset=hand(.0625,.125,-.625),rigid.vector(0,0,0)
  local rotation={Pitch=0,Yaw=0,Roll=0}
  local function rotate(axis,degrees,pivot)
    local next_rotation={Pitch=axis==0 and degrees or 0,Yaw=0,Roll=axis==1 and degrees or 0}
    offset=add(offset,rigid.rotate(rotation,sub(pivot,rigid.rotate(next_rotation,pivot))))
    rotation=rigid.compose({position=rigid.vector(0,0,0),rotation=rotation},
      {position=rigid.vector(0,0,0),rotation=next_rotation}).rotation
  end
  local hit=spear_animation.hit_feedback(recoil)
  local b=spear_animation.progress(jab,.05,.2)^2
  local c=spear_animation.in_out_expo(spear_animation.progress(jab,.4,1))
  if charge>0 then
    local p=spear_animation.solve(profile.spear,charge)
    local forward=1-spear_animation.out_back(1-p.raise)
    offset=add(offset,hand(0,-hit*.4,-.38*(forward-p.back)+hit))
    rotate(0,-70*(p.raise-p.back)+40*(b-c),hand(0,-.03125,.125))
    rotate(1,90*(p.raise-p.sway+3*c+b),hand(0,0,.125))
  end
  if jab>0 then
    rotate(0,-70*(b-c),hand(0,-.125,.125))
    offset=add(offset,rigid.rotate(rotation,hand(0,.38*(b-c),0)))
  end
  return {position=sub(add(grip,offset),rigid.rotate(rotation,grip)),rotation=rotation}
end
return M
