-- At most six reusable render-only components per avatar. No timers, damage,
-- collision or skeleton writes. Each part inherits its matching Steve mesh's
-- transform, including native root motion that happens after the Lua pose tick.
local identity=require('host.pbz.object_identity')
local valid=require('host.pbz.appearance').valid
local bundle=require('host.pbz.mesh_bundle')
local M={};M.__index=M
local bones={'head','body','left_arm','right_arm','left_leg','right_leg'}
local bone_set={};for _,bone in ipairs(bones)do bone_set[bone]=true end
local function transform()
  return {Rotation={X=0,Y=0,Z=0,W=1},Translation={X=0,Y=0,Z=0},Scale3D={X=1,Y=1,Z=1}}
end
function M.new(owner,catalog,material,options)
  assert(valid(owner) and valid(material),'armor-owner-or-material-unavailable')
  assert(options and options.parents,'armor-steve-parents-required')
  return setmetatable({owner=owner,owner_id=identity.capture(owner),world_id=identity.capture(owner:GetWorld()),
    catalog=catalog,material=material,options=options,parts={},by_bone={},hidden={},
    report={uploads=0,pose_writes=0,attachments=0,changes=0,components=0,visible=0}},M)
end
function M.parents(parts)
  local result={}
  for _,entry in ipairs(parts)do
    local name=entry.name or entry.part and entry.part.name
    if bone_set[name]then
      assert(not result[name],'armor-duplicate-steve-part:'..name)
      result[name]=entry.component
    end
  end
  return result
end
local function parent(self,bone,parents)
  local p=assert(parents[bone],'armor-steve-part-missing:'..bone)
  assert(valid(p) and identity.matches(p:GetOwner(),self.owner_id)
    and identity.matches(p:GetWorld(),self.world_id),'armor-steve-part-owner-mismatch:'..bone)
  return p
end
function M:attach(entry,p)
  local id=identity.capture(p)
  if entry.parent_id and identity.matches(p,entry.parent_id)
    and identity.matches(entry.component:GetAttachParent(),id)then return end
  -- PBZ-reflected EAttachmentRule::SnapToTarget = 2 for all three channels.
  -- Unit relative scale also inherits the first-person arm's scale exactly once.
  assert(entry.component:K2_AttachToComponent(p,FName('None'),2,2,2,false),'armor-attachment-rejected')
  assert(identity.matches(entry.component:GetAttachParent(),id),'armor-attachment-readback-failed')
  entry.parent=p;entry.parent_id=id;entry.pose=nil
  self.report.attachments=(self.report.attachments or 0)+1
end
function M:bind_parents(parents)
  -- Used only when the render owner changes or by the narrow live updater.
  for _,entry in ipairs(self.parts)do parent(self,entry.bone,parents)end
  self.options.parents=parents
  for _,entry in ipairs(self.parts)do self:attach(entry,parents[entry.bone])end
end
function M:is_current()
  if self.closed or not valid(self.owner) or not identity.matches(self.owner,self.owner_id)
    or not identity.matches(self.owner:GetWorld(),self.world_id) then return false end
  for _,entry in ipairs(self.parts)do
    if not valid(entry.component) or not identity.matches(entry.component,entry.id) then return false end
    if not identity.matches(entry.parent,entry.parent_id)
      or not identity.matches(entry.component:GetAttachParent(),entry.parent_id)then return false end
    if self.options.capture_only and not entry.component.bVisibleInSceneCaptureOnly then return false end
  end
  return true
end
function M:component(bone)
  local entry=self.by_bone[bone]
  if entry then assert(entry.ready,'armor-partial-component');return entry end
  local p=parent(self,bone,self.options.parents)
  local class=StaticFindObject('/Script/ProceduralMeshComponent.ProceduralMeshComponent')
  assert(valid(class),'armor-component-class-unavailable')
  local c=self.owner:AddComponentByClass(class,true,transform(),false)
  assert(valid(c),'armor-component-allocation-failed')
  entry={component=c,id=identity.capture(c),bone=bone,shown=false}
  self.parts[#self.parts+1]=entry;self.by_bone[bone]=entry
  if self.options.owned then self.options.owned[entry.id.address]=true end
  c:SetHiddenInGame(true,false);c:SetCollisionEnabled(0);c:SetCastShadow(not self.options.capture_only and not self.options.first_person)
  if self.options.capture_only then
    c:SetVisibleInSceneCaptureOnly(true);assert(c.bVisibleInSceneCaptureOnly,'armor-preview-isolation-failed')
  end
  if self.options.first_person then
    c.FirstPersonPrimitiveType=1
  end
  self:attach(entry,p)
  c:SetMaterial(0,self.material)
  if self.options.on_create then self.options.on_create(c)end
  entry.ready=true;self.report.components=#self.parts;return entry
end
function M:set_hidden(hidden)
  -- 'all' for MC camera; 'head' retains native PBZ body/head-eye behavior.
  self.hidden_mode=hidden
  for _,entry in ipairs(self.parts)do
    if entry.shown and (hidden=='all' or hidden=='head' and entry.bone=='head')then
      entry.component:SetHiddenInGame(true,false);entry.shown=false
    end
  end
end
function M:update(snapshot,pose,visible)
  assert(self:is_current(),'armor-stale-owner')
  if self.signature~=snapshot.signature then
    local planned=self.catalog:resolve(snapshot) -- Verify before changing visible meshes.
    self.planned=planned;self.signature=snapshot.signature;self.report.changes=self.report.changes+1
  end
  local shown=0
  for _,bone in ipairs(bones)do
    local plan=self.planned[bone];local entry=self.by_bone[bone]
    local allowed=pose[bone] and (not visible or visible[bone])
      and self.hidden_mode~='all' and not(self.hidden_mode=='head' and bone=='head')
    if plan and allowed then
      entry=entry or self:component(bone)
      if entry.key~=plan.key then
        if entry.shown then entry.component:SetHiddenInGame(true,false);entry.shown=false end
        entry.key=nil;bundle.apply(entry.component,plan.part);entry.key=plan.key;self.report.uploads=self.report.uploads+1
      end
      if not entry.shown then entry.component:SetHiddenInGame(false,false);entry.shown=true end
      shown=shown+1
    elseif entry and entry.shown then entry.component:SetHiddenInGame(true,false);entry.shown=false end
  end
  self.report.visible=shown;self.report.signature=snapshot.signature;self.report.points=snapshot.points
end
function M:hide()self:set_hidden('all')end
function M:close()
  if self.closed then return end
  if valid(self.owner) and identity.matches(self.owner,self.owner_id)then
    for _,entry in ipairs(self.parts)do
      if valid(entry.component) and identity.matches(entry.component,entry.id)then
        entry.component:SetHiddenInGame(true,false);entry.component:K2_DestroyComponent(self.owner)
        assert(not valid(entry.component),'armor-component-still-active')
      end
      if self.options.owned then self.options.owned[entry.id.address]=nil end
    end
  end
  self.closed=true
end
return M
