-- Separate render-only MC parts, owned by the preview actor. No world-player
-- transforms, skeleton setters, collision, animation notifications or damage.
local identity=require('host.pbz.object_identity')
local valid=require('host.pbz.appearance').valid
local bundle=require('host.pbz.mesh_bundle')
local pose=require('presentation.inventory_preview_pose')
local M={};M.__index=M
local function transform()
  return {Rotation={X=0,Y=0,Z=0,W=1},Translation={X=0,Y=0,Z=0},Scale3D={X=1,Y=1,Z=1}}
end
function M.new(owner,binding)
  assert(valid(owner) and binding:is_current(),'preview-model-owner-unavailable')
  local class=StaticFindObject('/Script/ProceduralMeshComponent.ProceduralMeshComponent')
  assert(valid(class),'preview-model-component-class-unavailable')
  local self=setmetatable({owner=owner,owner_id=identity.capture(owner),parts={},geometry={},binding=binding},M)
  local ok,why=pcall(function()
    for _,source in ipairs(binding.parts) do
      assert(valid(source.component),'preview-model-source-unavailable')
      -- Manual attachment keeps the parts independent from the moving camera.
      local component=owner:AddComponentByClass(class,true,transform(),false)
      assert(valid(component),'preview-model-allocation-failed')
      local entry={component=component,identity=identity.capture(component),part=source.part}
      self.parts[#self.parts+1]=entry;self.geometry[#self.geometry+1]=source.part
      component:SetHiddenInGame(true,false)
      component:SetCollisionEnabled(0);component:SetCastShadow(false)
      component:SetVisibleInSceneCaptureOnly(true)
      assert(component.bVisibleInSceneCaptureOnly,'preview-model-main-view-isolation-failed')
      bundle.apply(component,source.part)
      local material=source.component:GetMaterial(0)
      assert(valid(material),'preview-model-material-unavailable')
      component:SetMaterial(0,material)
      component:SetHiddenInGame(false,false)
    end
  end)
  if not ok then self.creation_failure=tostring(why) end
  return self -- A partial construction remains owned for retryable cleanup.
end
function M:valid()
  if self.closed or not identity.matches(self.owner,self.owner_id) then return false end
  for _,entry in ipairs(self.parts) do
    if not valid(entry.component) or not identity.matches(entry.component,entry.identity) or not entry.component.bVisibleInSceneCaptureOnly then return false end
  end
  if self.held and not self.held:is_current() then return false end
  if self.armor and not self.armor:is_current() then return false end
  if self.elytra and not self.elytra:is_current() then return false end
  return true
end
function M:set_equipment(equipment,catalog,on_create)
  assert(self:valid(),'preview-model-stale')
  if not self.held then
    local material=assert(self.parts[1]).component:GetMaterial(0)
    self.held=require('host.pbz.held_items').new(self.owner,catalog,material,
      {capture_only=true,on_create=on_create})
  end
  self.equipment=equipment
  local armor=require('host.pbz.armor_state').get(equipment.armor)
  if armor.count>0 and not self.armor then
    local worn=require('host.pbz.worn_armor')
    self.armor=worn.new(self.owner,
      require('host.pbz.armor_models').new(self.binding.armor_models_root),self.binding.material,
      {capture_only=true,on_create=on_create,parents=worn.parents(self.parts)})
  end
  self.armor_snapshot=armor
  if equipment.armor and equipment.armor.chest and equipment.armor.chest.content_id=='pbzmc:elytra'and not self.elytra then
    local worn=require('host.pbz.worn_elytra')
    self.elytra=worn.new(self.owner,self.binding.item_models_root..'/../elytra-firework',self.binding.material,
      {capture_only=true,on_create=on_create,parents=worn.parents(self.parts)})
  end
end
function M:update(anchor,look)
  assert(self:valid(),'preview-model-stale')
  local output=pose.solve(self.geometry,look,anchor)
  for _,entry in ipairs(self.parts) do
    local target=assert(output[entry.part.name])
    entry.component:K2_SetWorldLocationAndRotation(target.position,target.rotation,false,{},true)
  end
  self.pose=output
  if self.held then self.held:update(self.equipment,output) end
  if self.armor then self.armor:update(self.armor_snapshot,output) end
  if self.elytra then self.elytra:update(self.equipment,{gliding=false,crouching=false,dt=0})end
end
function M:close()
  if self.closed then return true end
  if not valid(self.owner) or not identity.matches(self.owner,self.owner_id) then self.closed=true;return true end
  local errors={}
  if self.elytra then
    local ok,why=pcall(self.elytra.close,self.elytra)
    if not ok then errors[#errors+1]=tostring(why)end
  end
  if self.held then
    local ok,why=pcall(self.held.close,self.held)
    if not ok then errors[#errors+1]=tostring(why) end
  end
  if self.armor then
    local ok,why=pcall(self.armor.close,self.armor)
    if not ok then errors[#errors+1]=tostring(why) end
  end
  for _,entry in ipairs(self.parts) do
    if valid(entry.component) and identity.matches(entry.component,entry.identity) then
      local ok,why=pcall(function()
        entry.component:K2_DestroyComponent(self.owner)
        assert(not valid(entry.component),'preview-model-component-still-active')
      end)
      if not ok then errors[#errors+1]=tostring(why) end
    end
  end
  assert(#errors==0,table.concat(errors,'; '));self.closed=true;return true
end
return M
