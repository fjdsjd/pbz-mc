-- Two render-only native components attached to the existing Steve torso.
-- No physics, input, durability, actor transforms, or persistence writes.
local identity=require('host.pbz.object_identity')
local valid=require('host.pbz.appearance').valid
local bundle=require('host.pbz.mesh_bundle')
local pose=require('presentation.elytra_pose')
local M={};M.__index=M
local names={'left_wing','right_wing'}
local function transform()
  return {Rotation={X=0,Y=0,Z=0,W=1},Translation={X=0,Y=0,Z=0},Scale3D={X=1,Y=1,Z=1}}
end
function M.parents(parts)
  local result={}
  for _,entry in ipairs(parts)do
    if (entry.name or entry.part and entry.part.name)=='body'then
      assert(not result.body,'elytra-duplicate-steve-body');result.body=entry.component
    end
  end
  return result
end
function M.equipped(equipment)
  local chest=equipment and equipment.armor and equipment.armor.chest
  return chest and chest.content_id=='pbzmc:elytra' and chest.count==1 or false
end
function M.new(owner,root,material,options)
  assert(valid(owner) and valid(material),'elytra-owner-or-material-unavailable')
  assert(options and options.parents,'elytra-steve-parents-required')
  return setmetatable({owner=owner,owner_id=identity.capture(owner),world_id=identity.capture(owner:GetWorld()),root=root,
    material=material,material_id=identity.capture(material),options=options,parts={},by_name={},clock={},report={uploads=0,pose_writes=0,attachments=0,components=0,visible=0}},M)
end
function M:parent(parents)
  local p=assert(parents.body,'elytra-steve-body-missing')
  assert(valid(p) and identity.matches(p:GetOwner(),self.owner_id)
    and identity.matches(p:GetWorld(),self.world_id),'elytra-steve-body-owner-mismatch')
  return p
end
function M:attach(entry,p)
  local id=identity.capture(p)
  if identity.matches(entry.parent,entry.parent_id) and identity.matches(p,entry.parent_id)
    and identity.matches(entry.component:GetAttachParent(),id)then return end
  assert(entry.component:K2_AttachToComponent(p,FName('None'),2,2,2,false),'elytra-attachment-rejected')
  assert(identity.matches(entry.component:GetAttachParent(),id),'elytra-attachment-readback-failed')
  entry.parent=p;entry.parent_id=id;entry.pose=nil;self.report.attachments=self.report.attachments+1
end
function M:bind_parents(parents)
  assert(not self.closed and identity.matches(self.owner,self.owner_id),'elytra-stale-owner')
  local p=self:parent(parents)
  for _,entry in ipairs(self.parts)do
    assert(valid(entry.component) and identity.matches(entry.component,entry.id),'elytra-stale-component')
  end
  self.options.parents=parents
  for _,entry in ipairs(self.parts)do self:attach(entry,p)end
end
function M:is_current()
  if self.closed or not valid(self.owner) or not identity.matches(self.owner,self.owner_id)
    or not identity.matches(self.owner:GetWorld(),self.world_id)or not identity.matches(self.material,self.material_id)then return false end
  for _,entry in ipairs(self.parts)do
    if not entry.ready or not valid(entry.component) or not identity.matches(entry.component,entry.id)
      or not identity.matches(entry.component:GetOwner(),self.owner_id)
      or not identity.matches(entry.component:GetWorld(),self.world_id)
      or not identity.matches(entry.parent,entry.parent_id)
      or not identity.matches(entry.parent:GetOwner(),self.owner_id)
      or not identity.matches(entry.parent:GetWorld(),self.world_id)
      or not identity.matches(entry.component:GetAttachParent(),entry.parent_id)then return false end
    if self.options.capture_only and not entry.component.bVisibleInSceneCaptureOnly then return false end
  end
  return true
end
function M:component(name)
  local entry=self.by_name[name]
  if entry then assert(entry.ready,'elytra-partial-component');return entry end
  local p=self:parent(self.options.parents)
  local class=StaticFindObject('/Script/ProceduralMeshComponent.ProceduralMeshComponent')
  assert(valid(class),'elytra-component-class-unavailable')
  local c=self.owner:AddComponentByClass(class,true,transform(),false)
  assert(valid(c),'elytra-component-allocation-failed')
  entry={component=c,id=identity.capture(c),name=name,shown=false}
  self.parts[#self.parts+1]=entry;self.by_name[name]=entry
  if self.options.owned then self.options.owned[entry.id.address]=true end
  c:SetHiddenInGame(true,false);c:SetCollisionEnabled(0);c:SetCastShadow(not self.options.capture_only)
  if self.options.capture_only then
    c:SetVisibleInSceneCaptureOnly(true);assert(c.bVisibleInSceneCaptureOnly,'elytra-preview-isolation-failed')
  end
  self:attach(entry,p);c:SetMaterial(0,self.material)
  if self.options.on_create then self.options.on_create(c)end
  entry.ready=true;self.report.components=#self.parts;return entry
end
function M:set_hidden(hidden)
  self.hidden=hidden=='all' or hidden==true
  if self.hidden then
    for _,entry in ipairs(self.parts)do
      if entry.shown and identity.matches(self.owner,self.owner_id) and valid(entry.component)
        and identity.matches(entry.component,entry.id)and identity.matches(entry.component:GetOwner(),self.owner_id)then
        entry.component:SetHiddenInGame(true,false);entry.shown=false
      end
    end
    self.report.visible=0
  end
end
local function same(a,b)
  if not a then return false end
  for _,key in ipairs({'X','Y','Z'})do if math.abs(a.position[key]-b.position[key])>1e-5 then return false end end
  for _,key in ipairs({'Pitch','Yaw','Roll'})do if math.abs(a.rotation[key]-b.rotation[key])>1e-4 then return false end end
  return true
end
function M:update(equipment,state)
  assert(self:is_current(),'elytra-stale-owner')
  local equipped=M.equipped(equipment)
  if not equipped or self.hidden or self.options.first_person then
    for _,entry in ipairs(self.parts)do
      if entry.shown then entry.component:SetHiddenInGame(true,false);entry.shown=false end
    end
    if not equipped then self.clock={}end
    self.report.visible=0;self.report.equipped=equipped;return
  end
  if not self.catalog then self.catalog=require('host.pbz.elytra_models').new(self.root)end
  if not self.planned then self.planned,self.wings=self.catalog:resolve()end
  local output=pose.solve(self.clock,state,self.wings)
  for _,name in ipairs(names)do
    local plan=self.planned[name];local entry=self:component(name)
    if entry.key~=plan.key then
      if entry.shown then entry.component:SetHiddenInGame(true,false);entry.shown=false end
      entry.key=nil;bundle.apply(entry.component,plan.part);entry.key=plan.key;self.report.uploads=self.report.uploads+1
    end
    local target=output[name]
    if not same(entry.pose,target)then
      entry.component:K2_SetRelativeLocationAndRotation(target.position,target.rotation,false,{},true)
      entry.pose=target;self.report.pose_writes=self.report.pose_writes+1
    end
    if not entry.shown then entry.component:SetHiddenInGame(false,false);entry.shown=true end
  end
  self.report.visible=2;self.report.equipped=true;self.report.gliding=state and state.gliding==true
end
function M:hide()self:set_hidden('all')end
function M:close()
  if self.closed then return true end
  local errors={}
  for _,entry in ipairs(self.parts)do
    local ok,why=pcall(function()
      if valid(self.owner) and identity.matches(self.owner,self.owner_id)
        and valid(entry.component) and identity.matches(entry.component,entry.id)
        and identity.matches(entry.component:GetOwner(),self.owner_id)then
        entry.component:SetHiddenInGame(true,false);entry.component:K2_DestroyComponent(self.owner)
        assert(not valid(entry.component),'elytra-component-still-active')
      end
      if self.options.owned then self.options.owned[entry.id.address]=nil end
    end)
    if not ok then errors[#errors+1]=tostring(why)end
  end
  assert(#errors==0,table.concat(errors,'; '));self.closed=true;return true
end
return M
