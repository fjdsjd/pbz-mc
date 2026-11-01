-- A small independent HUD update loop. It never drains input or renders the
-- inventory, and a health/UI failure cannot disable combat or hotbar controls.
local identity=require('host.pbz.object_identity')
local valid=require('host.pbz.appearance').valid
local hearts=require('presentation.health_hearts')
local M={};M.__index=M
function M.new(ui)
  local self=setmetatable({ui=ui,images={},cache={},animation=hearts.new(),epoch=0,report={}},M)
  self.canvas=StaticConstructObject(StaticFindObject('/Script/UMG.CanvasPanel'),ui.tree)
  assert(valid(self.canvas),'health-canvas-required');self.canvas_id=identity.capture(self.canvas)
  local slot=ui.canvas:AddChildToCanvas(self.canvas)
  slot:SetAnchors({Minimum={X=0,Y=0},Maximum={X=1,Y=1}});slot:SetOffsets({Left=0,Top=0,Right=0,Bottom=0});slot:SetZOrder(500)
  self.canvas:SetVisibility(1)
  -- Keep the atlas in a native widget reference, ready before a lethal hit.
  self.activation_keeper=StaticConstructObject(StaticFindObject('/Script/UMG.Image'),ui.tree)
  self.canvas:AddChildToCanvas(self.activation_keeper);self.activation_keeper:SetVisibility(1)
  self.activation_keeper:SetBrushFromTexture(ui:texture(ui.assets.totem_activation.path),false)
  self.loop=LoopInGameThreadAfterFrames(1,function()
    if self.closed then return end
    local ok,why=pcall(self.tick,self)
    if not ok then
      self:hide();self.report.error=tostring(why)
      if self.error~=tostring(why) then self.error=tostring(why);ui.log('health HUD unavailable: '..self.error) end
    end
  end)
  return self
end
function M:set_enabled(value)
  self.enabled=value==true
  if not self.enabled then self:hide() end
end
function M:set_inventory(value)
  if self.inventory~=value then self.inventory=value;self.read_tick=nil end
  self.enabled=not value
end
function M:hide()
  if identity.matches(self.canvas,self.canvas_id) then self.canvas:SetVisibility(1) end
  if self.native then self.native:release() end
end
function M:tick()
  if not self.ui:valid() then self:close();return end
  -- The parent gate also covers full-screen video with an unchanged camera.
  -- Check before the 20 TPS dedup, including when native game time is paused.
  if self.ui.visibility_reason then self:hide();self.report.visible=false;return end
  local lifecycle=require('host.pbz.appearance_lifecycle').get();local binding=lifecycle and lifecycle:current()
  if not binding or not binding:is_current() then self:hide();self.reader=nil;self.binding=nil;return end
  local now=StaticFindObject('/Script/Engine.Default__GameplayStatics'):GetTimeSeconds(binding.actor)
  local real_time=StaticFindObject('/Script/Engine.Default__GameplayStatics'):GetRealTimeSeconds(binding.actor)
  if self.binding~=binding then
    self:hide();self.binding=binding;self.epoch=self.epoch+1;self.read_tick=nil
    self.reader=assert(require('host.pbz.player_vitals').new(binding,require('UEHelpers').GetPlayerController(),self.epoch))
    self.native=require('host.pbz.native_player_status_visibility').new(binding)
    self.animation=hearts.new()
    self.selected_name=require('presentation.selected_item_name').new()
  end
  local service=binding.mc_status_service
  local activation=service and service.activation_at
  local tick=math.floor((self.inventory and real_time or now)*(activation and now-activation<2 and 60 or 20)+1e-6)
  if self.read_tick==tick then return end
  self.read_tick=tick;local start=os.clock()
  local snapshot,why=self.reader:read(self.epoch);assert(snapshot,why)
  local status=binding.mc_status or {}
  if service and service:current() then
    snapshot.absorption_authoritative=true;snapshot.absorption=service.value.absorption
  end
  snapshot.regenerating=status.regeneration==true
  snapshot.heart_kind=status.poisoned and 'poisoned_' or status.withered and 'withered_' or status.frozen and 'frozen_' or ''
  local frame=self.animation:update(snapshot,now)
  local last_activation=self.report.last_activation
  self.report={epoch=self.epoch,hp=snapshot.hp,max_hp=snapshot.max_hp,units=frame.units,previous=frame.previous,
    tick=frame.tick,blinking=frame.blinking,low=frame.low,regenerating=frame.regenerating,visible=false,
    updates=(self.report.updates or 0)+1,peak_ms=self.report.peak_ms or 0}
  self.report.stamina=snapshot.stamina;self.report.max_stamina=snapshot.max_stamina
  self.report.last_activation=last_activation
  if not (self.enabled or self.inventory) or not self.ui.viewport or not self.ui.layout then self:hide();return end
  local camera=require('host.pbz.first_person_camera').get()
  if camera and camera:native_takeover() then self:hide();return end
  local scale=self.ui.layout.scale;local view=self.ui.viewport;local dpi=self.ui.dpi
  local left=math.floor((view.width-182*scale)/2);local top=view.height-(30+17)*scale
  local draw=self.inventory and service and require('presentation.status_effect_ui').draw(service.value,self.ui.assets,self.ui.layout)
    or (self.inventory or binding.mc_creative) and {} or hearts.draw(frame,self.ui.assets.player_status,left,top,scale)
  local campaign=require('host.pbz.campaign_inventory')
  local containers=campaign.view(binding)
  local armor=require('host.pbz.armor_state').get(containers.player.armor)
  self.report.armor_points=armor.points;self.report.armor_toughness=armor.toughness
  local armor_top
  if not self.inventory and not binding.mc_creative then
    local armor_ui=require('presentation.armor_hud')
    local armor_draw=armor_ui.draw(armor.hud_points,frame.gold,self.ui.assets.player_status,left,top,scale)
    for _,entry in ipairs(armor_draw)do draw[#draw+1]=entry end
    if #armor_draw>0 then armor_top=armor_ui.row_top(frame.gold,top,scale)end
  end
  local extra=require('presentation.status_hud').draw(service and service.value,self.ui.assets,self.ui.layout,view,self.inventory,
    containers,not binding.mc_creative and snapshot.stamina/snapshot.max_stamina or nil,activation,now,self.ui.enchanted_icons,real_time)
  for _,entry in ipairs(extra) do draw[#draw+1]=entry end
  if not self.inventory then
    local session=campaign.ensure(binding);local sync=session.native_slot_sync
    local title=self.selected_name:update(containers,self.ui.assets,sync and sync.snapshot,session.epoch,now,view,scale,armor_top)
    for _,entry in ipairs(title)do draw[#draw+1]=entry end
    self.report.selected_name=self.selected_name.report
  end
  for index,entry in ipairs(draw) do
    local row=self.images[index]
    if not row or not identity.matches(row.image,row.id) then
      local image=StaticConstructObject(StaticFindObject('/Script/UMG.Image'),self.ui.tree)
      local clip=StaticConstructObject(StaticFindObject('/Script/UMG.CanvasPanel'),self.ui.tree)
      assert(valid(image) and valid(clip),'health-image-required');self.canvas:AddChildToCanvas(clip)
      clip:SetClipping(1);clip:SetVisibility(3);clip:AddChildToCanvas(image)
      row={image=image,id=identity.capture(image),clip=clip};self.images[index]=row;self.cache[index]=nil
    end
    local old=self.cache[index] or {};local image=row.image
    if not old.shown then row.clip:SetVisibility(3);image:SetVisibility(3) end
    if old.texture~=entry.texture then image:SetBrushFromTexture(self.ui:texture(entry.texture),false) end
    local tint=entry.tint or {R=1,G=1,B=1,A=1};local color=table.concat({tint.R,tint.G,tint.B,tint.A},',')
    if old.color~=color then image:SetColorAndOpacity(tint) end
    if old.x~=entry.x or old.y~=entry.y or old.dpi~=dpi then row.clip.Slot:SetPosition({X=entry.x/dpi,Y=entry.y/dpi}) end
    if old.w~=entry.w or old.h~=entry.h or old.dpi~=dpi then row.clip.Slot:SetSize({X=entry.w/dpi,Y=entry.h/dpi}) end
    local r=entry.region;local region=r and table.concat({r.x,r.y,r.w,r.h,r.tw,r.th},',') or ''
    if old.region~=region or old.w~=entry.w or old.h~=entry.h or old.dpi~=dpi then
      image.Slot:SetPosition({X=r and -r.x*entry.w/r.w/dpi or 0,Y=r and -r.y*entry.h/r.h/dpi or 0})
      image.Slot:SetSize({X=(r and r.tw*entry.w/r.w or entry.w)/dpi,Y=(r and r.th*entry.h/r.h or entry.h)/dpi})
    end
    local z=entry.activation and 2500 or index
    if old.z~=z then row.clip.Slot:SetZOrder(z) end
    self.report.activation_frame=entry.activation and entry.frame or self.report.activation_frame
    if entry.activation then
      self.report.last_activation={at=activation,frame=entry.frame,center_x=entry.x+entry.w/2,center_y=entry.y+entry.h/2,
        viewport_width=view.width,viewport_height=view.height,size=entry.w}
    end
    self.cache[index]={shown=true,texture=entry.texture,x=entry.x,y=entry.y,w=entry.w,h=entry.h,color=color,dpi=dpi,region=region,z=z}
  end
  for i=#draw+1,#self.images do
    local row=self.images[i]
    if self.cache[i] and self.cache[i].shown and identity.matches(row.image,row.id) then row.clip:SetVisibility(1);self.cache[i].shown=false end
  end
  self.canvas:SetVisibility(3);self.report.visible=true;self.report.images=#draw
  if self.native then self.native:apply(now) end
  self.report.gold=frame.gold;self.report.inventory=self.inventory
  self.report.peak_ms=math.max(self.report.peak_ms,(os.clock()-start)*1000)
  self.error=nil
end
function M:close()
  if self.closed then return end
  self.closed=true;self:hide()
  if self.loop then CancelDelayedAction(self.loop);self.loop=nil end
  if identity.matches(self.canvas,self.canvas_id) then self.canvas:RemoveFromParent() end
  self.images={};self.cache={};self.reader=nil
end
return M
