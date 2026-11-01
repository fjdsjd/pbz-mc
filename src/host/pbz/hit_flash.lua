-- Generic short red override of every model material slot, including attached
-- equipment. No monster names or original shader parameters are special-cased.
local valid=require('host.pbz.appearance').valid
local identity=require('host.pbz.object_identity')
local M={};M.__index=M
local function now(actor) return StaticFindObject('/Script/Engine.Default__GameplayStatics'):GetTimeSeconds(actor) end
function M.new(binding) return setmetatable({binding=binding,active={}},M) end
function M:material()
  if valid(self.red) then return self.red end
  local base=StaticFindObject('/Game/LevelPrototyping/Materials/MI_BaseColor_DarkGrey.MI_BaseColor_DarkGrey')
  assert(valid(base) and valid(base.Parent) and base.Parent.bUsedWithSkeletalMesh,'hit-flash-skeletal-shader-required')
  local red=StaticFindObject('/Script/Engine.Default__KismetMaterialLibrary'):CreateDynamicMaterialInstance(
    self.binding.actor,base,FName('PBZMC_HitRed'),1)
  assert(valid(red),'hit-flash-material-failed')
  red:SetVectorParameterValue(FName('Color'),{R=1,G=.018,B=.018,A=1})
  -- Lua wrappers are not GC roots. A non-rendering native component retains
  -- the replacement and displaced MIDs until each flash has been restored.
  self.keepalive=self.binding.actor:AddComponentByClass(StaticFindObject('/Script/Engine.StaticMeshComponent'),true,
    {Rotation={X=0,Y=0,Z=0,W=1},Translation={X=0,Y=0,Z=0},Scale3D={X=1,Y=1,Z=1}},false)
  assert(valid(self.keepalive),'hit-flash-material-retention')
  self.keepalive:SetVisibility(false,false);self.keepalive:SetCollisionEnabled(0);self.keepalive:SetMaterial(0,red)
  self.next_slot=1;self.free_slots={};self.red=red;return red
end
function M:retain(material)
  local slot=table.remove(self.free_slots) or self.next_slot
  if slot==self.next_slot then self.next_slot=self.next_slot+1 end
  self.keepalive:SetMaterial(slot,material);return slot
end
function M:release(slot)
  if slot and valid(self.keepalive) then self.keepalive:SetMaterial(slot,nil);self.free_slots[#self.free_slots+1]=slot end
end
function M:restore(row)
  local report={meshes=0,restored=0,changed=0,errors=0}
  for _,part in ipairs(row.parts) do
    local ok=pcall(function()
      if not identity.matches(part.mesh,part.id) then return end
      report.meshes=report.meshes+1
      for slot,saved in pairs(part.slots) do
        if slot<part.mesh:GetNumMaterials() and identity.matches(part.mesh:GetMaterial(slot),part.applied) then
          if not saved.prior or valid(saved.prior) then part.mesh:SetMaterial(slot,saved.prior);report.restored=report.restored+1 end
        else report.changed=report.changed+1 end
      end
      if part.overlay_saved and not valid(part.mesh:GetOverlayMaterial()) then part.mesh:SetOverlayMaterial(part.overlay) end
    end)
    if not ok then report.errors=report.errors+1 end
    for _,saved in pairs(part.slots) do self:release(saved.keep_slot) end
    self:release(part.overlay_keep)
  end
  self.last_restore=report
end
function M:show(target)
  if not self.binding:is_current() or not valid(target) then return false end
  local stamp=now(self.binding.actor);local key=target:GetAddress();local row=self.active[key]
  local red=self:material()
  if not row or not identity.matches(target,row.id) then row={id=identity.capture(target),parts={},by_mesh={}} end
  row.until_time=stamp+.16
  self.active[key]=row
  if not self.timer then
    self.timer=LoopInGameThreadAfterFrames(1,function()
      local current=self.binding:is_current() and now(self.binding.actor) or math.huge
      for id,item in pairs(self.active) do
        if current>=item.until_time then pcall(self.restore,self,item);self.active[id]=nil end
      end
      if next(self.active)==nil then CancelDelayedAction(self.timer);self.timer=nil end
    end)
  end
  local mesh_class=StaticFindObject('/Script/Engine.MeshComponent')
  local character_class=StaticFindObject('/Script/ProjectPBZ.PBZCharacter')
  local seen={};local meshes,slots=0,0
  local function belongs(mesh)
    local owner=mesh:GetOwner();local chain={}
    while valid(owner) and not chain[owner:GetAddress()] do
      if identity.matches(owner,row.id) then return true end
      if owner:IsA(character_class) then return false end -- not another attached character
      chain[owner:GetAddress()]=true;owner=owner:GetAttachParentActor()
    end
    return false
  end
  local function visit(mesh)
    if not valid(mesh) or not mesh:IsA(mesh_class) or seen[mesh:GetAddress()] or not belongs(mesh) then return end
    local address=mesh:GetAddress();seen[address]=true;meshes=meshes+1
    local part=row.by_mesh[address]
    if not part or not identity.matches(mesh,part.id) then
      part={mesh=mesh,id=identity.capture(mesh),slots={},applied=identity.capture(red)}
      row.by_mesh[address]=part;row.parts[#row.parts+1]=part
    end
    for slot=0,mesh:GetNumMaterials()-1 do
      slots=slots+1;local current=mesh:GetMaterial(slot)
      if not identity.matches(current,part.applied) then
        if part.slots[slot] then self:release(part.slots[slot].keep_slot) end
        part.slots[slot]={prior=current,keep_slot=self:retain(current)};mesh:SetMaterial(slot,red)
      end
    end
    local overlay=mesh:GetOverlayMaterial()
    if valid(overlay) then
      self:release(part.overlay_keep);part.overlay=overlay;part.overlay_saved=true;part.overlay_keep=self:retain(overlay);mesh:SetOverlayMaterial(nil)
    end
  end
  for _,wrapped in ipairs(target:K2_GetComponentsByClass(mesh_class)) do visit(wrapped:get()) end
  if valid(target.RootComponent) then
    local children={};target.RootComponent:GetChildrenComponents(true,children)
    for _,wrapped in ipairs(children) do visit(wrapped:get()) end
  end
  self.report={mode='all-mesh-material-slots',meshes=meshes,slots=slots,target=target:GetFullName()}
  return slots>0
end
function M:close()
  if self.timer then CancelDelayedAction(self.timer);self.timer=nil end
  for _,row in pairs(self.active) do pcall(self.restore,self,row) end
  self.active={}
  if valid(self.keepalive) then self.keepalive:K2_DestroyComponent(self.binding.actor);self.keepalive=nil end
end
return M
