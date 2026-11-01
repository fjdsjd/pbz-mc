-- Camera-owned visual parts. They never drive the pawn, weapon collision or damage.
local identity=require('host.pbz.object_identity')
local valid=require('host.pbz.appearance').valid
local bundle=require('host.pbz.mesh_bundle')
local math3=require('presentation.first_person_camera')
local M={};M.__index=M
local function transform()
  return {Rotation={X=0,Y=0,Z=0,W=1},Translation={X=0,Y=0,Z=0},Scale3D={X=1,Y=1,Z=1}}
end
function M.new(owner,binding)
  local self=setmetatable({owner=owner,owner_id=identity.capture(owner),binding=binding,parts={}},M)
  local class=StaticFindObject('/Script/ProceduralMeshComponent.ProceduralMeshComponent')
  assert(valid(class),'first-person-mesh-class-unavailable')
  -- Return partial ownership to the camera so failures can be cleaned up.
  local ok,why=pcall(function()
    for _,source in ipairs(binding.parts) do
      if source.part.name=='right_arm' or source.part.name=='left_arm' then
        local c=owner:AddComponentByClass(class,true,transform(),false)
        assert(valid(c),'first-person-arm-allocation-failed')
        self.parts[#self.parts+1]={component=c,id=identity.capture(c),name=source.part.name}
        c:SetHiddenInGame(true,false);c:SetCollisionEnabled(0);c:SetCastShadow(false)
        c.FirstPersonPrimitiveType=1 -- Exact PBZ EFirstPersonPrimitiveType::FirstPerson metadata.
        bundle.apply(c,source.part);c:SetMaterial(0,binding.material)
        local scale=6.25/require('presentation.native_steve_pose').scale
        c:SetWorldScale3D({X=scale,Y=scale,Z=scale})
      end
    end
    assert(#self.parts==2,'first-person-steve-arms-required')
  end)
  if not ok then self.creation_failure=tostring(why) end
  return self
end
function M:update(camera,equipment)
  equipment=equipment or {group='pbz'}
  if equipment.group=='pbz' then self:hide();return end
  if equipment.group~='pbz' and (equipment.main or equipment.offhand) and not self.held then
    self.held=require('host.pbz.held_items').new(self.owner,
      require('host.pbz.item_models').new(self.binding.item_models_root),self.binding.material,
      {on_create=function(c) c.FirstPersonPrimitiveType=1;c:SetCastShadow(false) end})
  end
  local arm_pose,arm_visible={},{}
  for _,entry in ipairs(self.parts) do
    assert(valid(entry.component) and identity.matches(entry.component,entry.id),'first-person-arm-stale')
    local left=entry.name=='left_arm'
    -- MC renders held offhand items without an additional free arm mesh.
    local shown=not left and equipment.main==nil
    local target=math3.arm(camera,left,equipment)
    arm_pose[entry.name]=target;arm_visible[entry.name]=shown
    entry.component:K2_SetWorldLocationAndRotation(target.position,target.rotation,false,{},true)
    entry.component:SetHiddenInGame(not shown,false)
  end
  local armor=require('host.pbz.armor_state').get(require('host.pbz.campaign_inventory').armor_slots(self.binding))
  if armor.count>0 and not self.armor then
    local worn=require('host.pbz.worn_armor')
    self.armor=worn.new(self.owner,
      require('host.pbz.armor_models').new(self.binding.armor_models_root),self.binding.material,
      {first_person=true,parents=worn.parents(self.parts)})
  end
  if self.armor then self.armor:set_hidden(nil);self.armor:update(armor,arm_pose,arm_visible)end
  if self.held then
    -- PBZ's aspect-correct world FOV needs a slightly farther holder than the
    -- upstream camera. Original per-item MC display transforms stay unchanged.
    self.held:update(equipment,nil,camera,math3.holders(equipment,camera))
  end
  self.equipment=equipment
end
function M:hide()
  if self.armor then self.armor:hide()end
  for _,entry in ipairs(self.parts) do
    if valid(entry.component) and identity.matches(entry.component,entry.id) then entry.component:SetHiddenInGame(true,false) end
  end
  if self.held then self.held:hide() end
end
function M:close()
  if self.closed then return end
  if self.held then self.held:close() end
  if self.armor then self.armor:close() end
  for _,entry in ipairs(self.parts) do
    if valid(self.owner) and identity.matches(self.owner,self.owner_id)
      and valid(entry.component) and identity.matches(entry.component,entry.id) then
      entry.component:K2_DestroyComponent(self.owner)
    end
  end
  self.closed=true
end
return M
