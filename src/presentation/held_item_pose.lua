-- Unbaked original display followed by the pinned Steve hand/camera holder.
-- See ExtractMinecraftWeapons.hand and SteveMesh.cs in third_party provenance.
local rigid=require('presentation.rigid_transform')
local display=require('presentation.item_model_transform')
local M={}
local function transform(x,y,z,p,yaw,r)
  return {position=rigid.vector(x,y,z),rotation={Pitch=p or 0,Yaw=yaw or 0,Roll=r or 0}}
end
function M.third_person(model,arm,left,motion)
  assert(model.context==(left and 'thirdperson_lefthand' or 'thirdperson_righthand'),'wrong-held-model-context')
  local units=model.units
  -- MC item frame (z,-x,y) -> Steve hand (y,x,z). The arm owns its pose;
  -- the grip is 2 forward, +/-1 right, 10 down, in original model units.
  local holder=transform(2*units,(left and -1 or 1)*units,-10*units,90,0,180)
  if motion then holder=rigid.compose(motion,holder) end
  return rigid.compose(arm,rigid.compose(holder,display.solve(model.display,model.context,units)))
end
function M.first_person(model,camera,left,holder)
  assert(model.context==(left and 'firstperson_lefthand' or 'firstperson_righthand'),'wrong-held-model-context')
  holder=holder or transform(72,left and -56 or 56,-52)
  -- Original first-person conversion (-z,x,y), applied once after display.
  local converted=rigid.compose(transform(0,0,0,0,180,0),display.solve(model.display,model.context,model.units))
  return rigid.compose(camera,rigid.compose(holder,converted))
end
return M
