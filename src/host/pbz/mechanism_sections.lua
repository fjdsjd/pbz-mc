-- A clock usually alternates between two already uploaded MC models. Keep
-- one spare section on a bounded set of active mechanisms in each world.
local bundle=require('host.pbz.mesh_bundle')
local M={}
local alternating={piston=true,sticky_piston=true,wire=true,repeater=true,comparator=true,
  observer=true,torch=true,lever=true,door=true}
function M.clear(world,handle)
  if handle.spare_model then
    world.spare_sections=world.spare_sections-1
    handle.spare_model=nil
  end
  handle.visible_section=nil
end
function M.switch(world,handle,record,model,previous)
  local mesh=handle.mesh
  local section=handle.visible_section or 0
  local spare=1-section
  if not previous or model~=handle.spare_model then
    local can_cache=alternating[handle.mechanism] and previous
      and (handle.spare_model or (world.spare_sections or 0)<32)
    if can_cache then
      if previous:sub(1,13)=='construction/' and model:sub(1,13)=='construction/' then
        -- Vanilla doors are tiny textured quads. Keep the alternate uploaded
        -- section under the existing per-world cap, just like original doors.
        can_cache=#world:part(previous).positions<=4096 and #world:part(model).positions<=4096
      else
        local models=world:mechanism_catalog().manifest.models
        can_cache=models[previous] and models[model] and models[previous].bytes<=256*1024 and models[model].bytes<=256*1024
      end
    end
    if not can_cache then
      M.clear(world,handle);mesh:ClearAllMeshSections()
      mesh:SetMaterial(0,world:material_for(record,model));bundle.apply(mesh,world:part(model))
      return
    end
    mesh:SetMaterial(spare,world:material_for(record,model));bundle.apply(mesh,world:part(model),spare)
    if not handle.spare_model then world.spare_sections=(world.spare_sections or 0)+1 end
    handle.spare_model=previous
  end
  mesh:SetMeshSectionVisible(section,false);mesh:SetMeshSectionVisible(spare,true)
  handle.spare_model=previous;handle.visible_section=spare
end
return M
