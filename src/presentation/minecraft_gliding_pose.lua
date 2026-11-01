-- Original MC 1.21.1 PlayerEntityRenderer.setupTransforms and flying branches
-- of BipedEntityModel.setAngles, layered over the existing combat pose solver.
-- All transforms are render data; native capsule/root motion stays untouched.
local base=require('presentation.minecraft_third_person_pose')
local native=require('presentation.native_steve_pose')
local rigid=require('presentation.rigid_transform')
local M={}
local function finite(n)
  assert(type(n)=='number' and n==n and math.abs(n)<math.huge,'invalid-gliding-pose-number');return n
end
local function clamp(n,a,b)return math.max(a,math.min(b,n))end
function M.anchor(state)
  if not state.gliding then return state.anchor end
  local ticks=math.max(0,finite(state.glide_ticks or 0))+clamp(finite(state.partial_tick or 0),0,1)
  local pitch=((finite(state.look.Pitch)+180)%360)-180
  local lean=clamp(ticks*ticks/100,0,1)*(-90+pitch)
  local v=state.velocity or {X=0,Y=0,Z=0};local vx,vy=finite(v.X),finite(v.Y)
  local yaw=math.rad(finite(state.look.Yaw));local lx,ly=math.cos(yaw),math.sin(yaw)
  local bank=0
  if vx*vx+vy*vy>1e-12 then bank=-math.deg(math.atan(vx*ly-vy*lx,vx*lx+vy*ly))end
  local root=rigid.compose(state.anchor,{position={X=0,Y=0,Z=-24*native.scale},rotation={Pitch=0,Yaw=0,Roll=0}})
  local tilted=rigid.compose({position={X=0,Y=0,Z=0},rotation={Pitch=lean,Yaw=0,Roll=0}},
    {position={X=0,Y=0,Z=0},rotation={Pitch=0,Yaw=bank,Roll=0}})
  return rigid.compose(rigid.compose(root,tilted),
    {position={X=0,Y=0,Z=24*native.scale},rotation={Pitch=0,Yaw=0,Roll=0}})
end
function M.solve(parts,state)
  if not state.gliding then return base.solve(parts,state),state.anchor end
  local adjusted={};for key,value in pairs(state)do adjusted[key]=value end
  adjusted.crouching=false;adjusted.riding=false;adjusted.anchor=M.anchor(state)
  local ticks=finite(state.glide_ticks or 0)
  if ticks>4 then
    local v=state.velocity or {X=0,Y=0,Z=0}
    -- UE cm/s -> Minecraft blocks/tick. A block is 100 cm and a tick .05 s.
    local speed2=(finite(v.X)^2+finite(v.Y)^2+finite(v.Z)^2)/(2000*2000)
    local damping=math.max(1,(speed2/.2)^3)
    adjusted.walk_amplitude=(state.walk_amplitude or math.min(1,finite(state.speed)/431.7))/damping
    adjusted.look={Pitch=45,Yaw=state.look.Yaw,Roll=state.look.Roll or 0}
  end
  local output=base.solve(parts,adjusted)
  -- Vanilla's tiny mirrored leg yaw/roll are independent of the walk swing.
  local amplitude=adjusted.walk_amplitude or math.min(1,state.speed/431.7)
  for _,part in ipairs(parts)do
    if part.name:sub(-3)=='leg' or part.name:sub(-5)=='pants'then
      local right=part.name:sub(1,6)=='right_';local sign=right and 1 or -1
      local x=math.cos(state.stride*.6662+(right and 0 or math.pi))*1.4*amplitude
      output[part.name]=rigid.compose(adjusted.anchor,{position=part.pivot,
        rotation={Pitch=-math.deg(x),Yaw=math.deg(sign*.005),Roll=-math.deg(sign*.005)}})
    end
  end
  return output,adjusted.anchor
end
M.relative=require('presentation.elytra_pose').relative
return M
