-- Owns only an appended CanvasPanel. Never hides or edits the PBZ HUD subtree.
-- Construction and all subsequent calls must run on the native game thread.
local identity=require('host.pbz.object_identity')
local valid=require('host.pbz.appearance').valid
local presentation=require('presentation.item_ui')
local M={}
-- Also used by the narrowly scoped live updater. It preserves the input
-- monitor, inventory, world, selected equipment and existing widget objects.
function M.attach_visibility(self)
  if self.visibility_gate then return end
  self.visibility_gate=require('host.pbz.native_hud_visibility').new(self.log)
  self.visibility_requested=self.canvas:GetVisibility()~=1 and self.canvas:GetVisibility()~=2
  self.visibility_preview_requested=self.preview and self.preview.active or false
  function self:sync_visibility()
    if self.visibility_closed or not self:valid()then return end
    local lifecycle=require('host.pbz.appearance_lifecycle').get()
    local binding=lifecycle and lifecycle:current()
    local game=StaticFindObject('/Script/Engine.Default__GameplayStatics')
    local now=binding and game:GetRealTimeSeconds(binding.actor)or 0
    local reason=self.visibility_gate:reason(binding,now)
    self.visibility_reason=reason
    local visible=self.visibility_requested and not reason
    local wanted=visible and 3 or 1
    if self.canvas:GetVisibility()~=wanted then self.canvas:SetVisibility(wanted)end
    if self.health_hud then self.health_hud:set_enabled(visible)end
    if self.preview then self.preview:set_active(visible and self.visibility_preview_requested)end
    if self.quick_help then self.quick_help:update(binding,now,visible)end
  end
  self.visibility_gate.on_change=function()self:sync_visibility()end
  local original_render,original_visible,original_close=self.render,self.set_visible,self.close
  function self:render(...)
    local layout=original_render(self,...)
    self.visibility_preview_requested=self.preview and self.preview.active or false
    self.visibility_requested=true;self:sync_visibility();return layout
  end
  function self:set_visible(value)
    self.visibility_requested=value==true
    original_visible(self,value);self:sync_visibility()
  end
  function self:close()
    self.visibility_closed=true
    if self.visibility_loop then CancelDelayedAction(self.visibility_loop);self.visibility_loop=nil end
    self.visibility_gate:close();return original_close(self)
  end
  self.visibility_loop=LoopInGameThreadAfterFrames(1,function()
    if self.visibility_closed then return end
    local ok,why=pcall(self.sync_visibility,self)
    if not ok and self.visibility_error~=tostring(why)then
      self.visibility_error=tostring(why);self.log('native HUD visibility unavailable: '..self.visibility_error)
    end
  end)
  self:sync_visibility()
end
function M.attach_catalogue_view(self)
  self.catalogue_state=self.catalogue_state or {category='construction',page=1}
  function self:load_catalogue()
    if self.assets.catalogue_ui then return end
    local file=assert(io.open(self.asset_path..'/bedrock_catalogue/manifest.json','rb'),'original-bedrock-catalogue-manifest-missing')
    local raw=file:read('*a');file:close()
    presentation.catalogue_assets(self.assets,assert(require('dkjson').decode(raw)),self.records)
  end
  function self:set_catalogue(request)
    local next=require('rules.item_catalogue').change(self.catalogue_state,request)
    local changed=next.category~=self.catalogue_state.category or next.page~=self.catalogue_state.page
    self.catalogue_state=next
    return changed
  end
end
local function object(path)
  local value=StaticFindObject(path);assert(value and value:IsValid(),'missing-native-ui:'..path);return value
end
local function find_owner()
  for _,widget in ipairs(FindAllOf('WB_OverLayerOut_C') or {}) do
    local name=widget:GetFullName()
    if name:find('/Engine/Transient.',1,true) and widget:IsInViewport() then
      local tree=widget.WidgetTree
      local root=tree and tree:IsValid() and tree.RootWidget
      if root and root:IsValid() and root:IsA(object('/Script/UMG.Overlay')) then return widget,tree,root end
    end
  end
  error('live-pbz-overlay-unavailable')
end
local cached_assets
local function construction_icon_hashes(asset_path)
  if package.searchpath('content.construction_icon_hashes',package.path) then
    return require('content.construction_icon_hashes')
  end
  -- A development install may have only the verified resource receipt.
  local file=assert(io.open(asset_path..'/../ready.json','rb'),'missing-construction-icon-receipt')
  local raw=file:read('*a');file:close()
  local receipt=assert(require('dkjson').decode(raw))
  local hashes={}
  for _,entry in ipairs(receipt.files)do
    local name=entry.path:match('^ui/construction/([a-z0-9_]+)%.png$')
    if name then hashes[name]=entry.sha256 end
  end
  return hashes
end
function M.resource_index(asset_path)
  if cached_assets and cached_assets.path==asset_path then return cached_assets end
  local file=assert(io.open(asset_path..'/manifest.json','rb'))
  local raw=file:read('*a');file:close()
  local assets=assert(require('dkjson').decode(raw))
  assert(assets.schema==1 and assets.layout_profile=='java-inventory-176x166-v1','unsupported-ui-asset-layout')
  local records={}
  for _,entry in ipairs(assets.outputs)do records[entry.path]=entry end
  for name,hash in pairs(construction_icon_hashes(asset_path))do
    local id='pbzmc:'..name
    if not assets.item_icons[id] then
      local path='construction/'..name..'.png'
      assets.item_icons[id]=path
      records[path]=records[path] or {path=path,sha256=hash}
    end
  end
  local ok,why=pcall(require('presentation.original_mc_font').attach,assets,asset_path,records)
  cached_assets={path=asset_path,assets=assets,records=records,font_error=not ok and tostring(why)or nil}
  return cached_assets
end
function M.new(asset_path,log)
  local owner,tree,root=find_owner()
  local index=M.resource_index(asset_path)
  local self={asset_path=asset_path,assets=index.assets,records=index.records,font_error=index.font_error,
    log=log or function() end,textures={},texture_ids={},texture_refs={},images={},image_ids={},clips={},clip_ids={},draw_cache={}}
  if self.font_error then self.log('original font fallback: '..self.font_error)end
  M.attach_catalogue_view(self)
  self.owner,self.tree,self.root=owner,tree,root
  self.owner_identity=identity.capture(owner);self.root_identity=identity.capture(root);self.tree_identity=identity.capture(tree)
  self.original_children=root:GetChildrenCount()
  self.log('item ui stage=construct-canvas children-before='..self.original_children)
  self.canvas=StaticConstructObject(object('/Script/UMG.CanvasPanel'),tree)
  assert(self.canvas and self.canvas:IsValid(),'item-ui-canvas-allocation-failed')
  self.canvas_identity=identity.capture(self.canvas)
  local ok,err=pcall(function()
    -- Input ownership is acquired separately by inventory_input; these images
    -- never forward widget events into the PBZ HUD beneath this canvas.
    self.canvas:SetVisibility(3)
    self.log('item ui stage=attach-canvas')
    self.slot=root:AddChildToOverlay(self.canvas)
    assert(self.slot and self.slot:IsValid(),'item-ui-attach-failed')
    self.slot:SetHorizontalAlignment(0);self.slot:SetVerticalAlignment(0)
    self.slot:SetPadding({Left=0,Top=0,Right=0,Bottom=0})
    assert(root:GetChildrenCount()==self.original_children+1,'item-ui-parent-count-mismatch')
  end)
  if not ok then pcall(function() self.canvas:RemoveFromParent() end);error(err) end
  function self:valid()
    local lifecycle=require('host.pbz.appearance_lifecycle').get()
    if lifecycle and self.valid_tick==lifecycle.ticks then
      return self.owner:IsValid() and self.canvas:IsValid() and self.owner:IsInViewport()
    end
    local current=valid(self.owner) and identity.matches(self.owner,self.owner_identity) and self.owner:IsInViewport()
      and valid(self.tree) and identity.matches(self.owner.WidgetTree,self.tree_identity)
      and valid(self.root) and identity.matches(self.tree.RootWidget,self.root_identity)
      and valid(self.canvas) and identity.matches(self.canvas,self.canvas_identity)
      and identity.matches(self.canvas:GetParent(),self.root_identity)
    self.valid_tick=current and lifecycle and lifecycle.ticks or nil
    return current
  end
  function self:texture(path)
    local record=assert(self.records[path],'unlisted-ui-texture:'..path)
    assert(path:match('%.png$') and not path:find('..',1,true) and not path:find(':',1,true),'invalid-ui-texture-path')
    local cached=self.textures[path]
    if valid(cached) and identity.matches(cached,self.texture_ids[path]) then return cached end
    local file=assert(io.open(self.asset_path..'/'..path,'rb'))
    local raw=file:read('*a');file:close()
    assert(require('storage.sha256')(raw)==record.sha256,'ui-texture-hash-mismatch:'..path)
    self.log('item ui stage=import-texture path='..path)
    local fn=object('/Script/Engine.KismetRenderingLibrary:ImportFileAsTexture2D')
    local library=object('/Script/Engine.Default__KismetRenderingLibrary')
    local texture=fn(library,self.owner,self.asset_path..'/'..path)
    assert(texture and texture:IsValid(),'ui-texture-import-failed:'..path)
    texture.Filter=0 -- TF_Nearest; the PNG pixels are never smoothed.
    -- Lua wrappers are not native GC roots. Retain imported textures in hidden
    -- owned brushes; changing slots/heart states cannot evict and re-import them.
    if not self.texture_keeper then
      self.texture_keeper=StaticConstructObject(object('/Script/UMG.CanvasPanel'),self.tree)
      self.canvas:AddChildToCanvas(self.texture_keeper);self.texture_keeper:SetVisibility(1)
    end
    local keeper=StaticConstructObject(object('/Script/UMG.Image'),self.tree)
    self.texture_keeper:AddChildToCanvas(keeper);keeper:SetVisibility(1);keeper:SetBrushFromTexture(texture,false)
    self.texture_refs[path]=keeper
    self.textures[path]=texture;self.texture_ids[path]=identity.capture(texture);return texture
  end
  -- A failed campaign has no inventory to render. Show a diagnostic using
  -- only the existing MC font layer, without manufacturing an empty store.
  function self:show_message(message,now)
    assert(self:valid(),'stale-item-ui-owner')
    local library=object('/Script/UMG.Default__WidgetLayoutLibrary')
    local size=object('/Script/UMG.WidgetLayoutLibrary:GetViewportSize')(library,self.owner)
    assert(size.X>=320 and size.Y>=240,'item-ui-viewport-unavailable')
    self.dpi=object('/Script/UMG.WidgetLayoutLibrary:GetViewportScale')(library,self.owner)
    assert(self.dpi>0,'invalid-viewport-dpi')
    self.viewport={width=size.X,height=size.Y}
    self.layout={scale=math.max(1,math.min(4,math.floor(math.min(size.X/320,size.Y/240))))}
    self.command_layer=self.command_layer or require('host.pbz.command_ui').new(self)
    self.command_layer:render(nil,now,message)
    self:set_visible(true)
  end
  function self:render(data,options)
    assert(self:valid(),'stale-item-ui-owner')
    options=options or {}
    if options.inventory then self:load_catalogue();options.catalogue_state=self.catalogue_state end
    -- Native references resolve through the actual local equipment snapshot.
    -- Cache reads briefly during pointer hover; no asset or gameplay data is
    -- copied into inventory, and preview redraws do not rescan every frame.
    local binding=require('host.pbz.appearance_lifecycle').get():current()
    options.has_effects=binding and binding.mc_status_service and next(binding.mc_status_service.value.effects)~=nil
    if self.native_reader and self.native_binding~=binding then self.native_reader:close();self.native_reader=nil;self.native_snapshot=nil end
    if binding and binding:is_current() and (not self.native_read_at or os.clock()-self.native_read_at>.5) then
      if not self.native_reader then
        local pc=require('host.pbz.local_player').controller()
        self.native_reader=require('host.pbz.native_equipment').new(binding,pc,1);self.native_binding=binding
      end
      if self.native_reader then self.native_snapshot=self.native_reader:read(1) end
      self.native_read_at=os.clock()
    end
    options.native_equipment=self.native_snapshot;options.native_equipment_epoch=1
    local library=object('/Script/UMG.Default__WidgetLayoutLibrary')
    local size=object('/Script/UMG.WidgetLayoutLibrary:GetViewportSize')(library,self.owner)
    assert(size.X>=320 and size.Y>=240,'item-ui-viewport-unavailable')
    local dpi=object('/Script/UMG.WidgetLayoutLibrary:GetViewportScale')(library,self.owner)
    assert(dpi>0,'invalid-viewport-dpi')
    local draw,layout=presentation.draw(data,self.assets,size.X,size.Y,options)
    self.enchanted_icons={}
    for _,entry in ipairs(draw) do if entry.enchanted then self.enchanted_icons[#self.enchanted_icons+1]=entry end end
    for index,entry in ipairs(draw) do
      local image=self.images[index]
      local clip=self.clips[index]
      if not valid(image) or not identity.matches(image,self.image_ids[index]) or not identity.matches(clip,self.clip_ids[index]) then
        image=StaticConstructObject(object('/Script/UMG.Image'),self.tree)
        clip=StaticConstructObject(object('/Script/UMG.CanvasPanel'),self.tree)
        assert(image and image:IsValid() and valid(clip),'item-ui-image-allocation-failed')
        self.canvas:AddChildToCanvas(clip);clip:SetClipping(1);clip:AddChildToCanvas(image)
        self.clips[index]=clip;self.clip_ids[index]=identity.capture(clip)
        self.images[index]=image;self.image_ids[index]=identity.capture(image)
        self.draw_cache[index]=nil
      end
      local old=self.draw_cache[index] or {}
      if not old.shown then clip:SetVisibility(3);image:SetVisibility(3) end
      if old.texture~=entry.texture then image:SetBrushFromTexture(self:texture(entry.texture),false) end
      local tint=entry.tint or {R=1,G=1,B=1,A=1}
      local color=table.concat({tint.R,tint.G,tint.B,tint.A},',')
      if old.color~=color then image:SetColorAndOpacity(tint) end
      local slot=clip.Slot
      if old.x~=entry.x or old.y~=entry.y or old.dpi~=dpi then slot:SetPosition({X=entry.x/dpi,Y=entry.y/dpi}) end
      if old.w~=entry.w or old.h~=entry.h or old.dpi~=dpi then slot:SetSize({X=entry.w/dpi,Y=entry.h/dpi}) end
      local r=entry.region;local region=r and table.concat({r.x,r.y,r.w,r.h,r.tw,r.th},',') or ''
      if old.region~=region or old.w~=entry.w or old.h~=entry.h or old.dpi~=dpi then
        image.Slot:SetPosition({X=r and -r.x*entry.w/r.w/dpi or 0,Y=r and -r.y*entry.h/r.h/dpi or 0})
        image.Slot:SetSize({X=r and r.tw*entry.w/r.w/dpi or entry.w/dpi,Y=r and r.th*entry.h/r.h/dpi or entry.h/dpi})
      end
      local z=entry.z or index
      if old.z~=z then slot:SetZOrder(z) end
      self.draw_cache[index]={texture=entry.texture,color=color,x=entry.x,y=entry.y,w=entry.w,h=entry.h,dpi=dpi,region=region,z=z,shown=true}
    end
    for i=#draw+1,#self.images do
      if self.draw_cache[i] and self.draw_cache[i].shown and valid(self.images[i]) and identity.matches(self.images[i],self.image_ids[i]) then
        self.clips[i]:SetVisibility(1);self.draw_cache[i].shown=false
      end
    end
    local wants_preview=options.inventory and options.preview_binding
    if self.preview and ((wants_preview and self.preview.binding~=options.preview_binding) or not self.preview:is_current()
        or self.preview.width~=layout.preview.w or self.preview.height~=layout.preview.h) then
      self.preview:close();self.preview=nil
    end
    if wants_preview and not self.preview then
      self.preview=require('host.pbz.realtime_preview').new(options.preview_binding,self,layout.preview,dpi,self.log)
      assert(not self.preview.creation_failure,self.preview.creation_failure)
    end
    if self.preview then
      self.preview:set_active(wants_preview~=nil and wants_preview~=false)
      if wants_preview then self.preview:set_equipment(data) end
      self.preview.image.Slot:SetPosition({X=layout.preview.x/dpi,Y=layout.preview.y/dpi})
      self.preview.image.Slot:SetSize({X=layout.preview.w/dpi,Y=layout.preview.h/dpi})
    end
    self.canvas:SetVisibility(3)
    local signature=string.format('%s/%.0fx%.0f/%.3f/%d',tostring(options.inventory),size.X,size.Y,dpi,layout.scale)
    if self.render_signature~=signature then
      self.render_signature=signature
      self.log(string.format('item ui rendered images=%d viewport=%.0fx%.0f dpi=%.3f scale=%d children=%d',
        #draw,size.X,size.Y,dpi,layout.scale,self.root:GetChildrenCount()))
    end
    self.layout,self.dpi,self.viewport=layout,dpi,{width=size.X,height=size.Y}
    if self.quick_help then self.quick_help:bind(draw,options.inventory)end
    if not self.health_hud then
      local success,hud=pcall(require('host.pbz.health_hud').new,self)
      if success then self.health_hud=hud else self.log('health HUD creation failed: '..tostring(hud)) end
    end
    if self.health_hud then self.health_hud:set_inventory(options.inventory==true) end
    return layout
  end
  function self:set_visible(visible)
    if self.health_hud then self.health_hud:set_enabled(visible) end
    if valid(self.canvas) and identity.matches(self.canvas,self.canvas_identity) then
      self.canvas:SetVisibility(visible and 3 or 1)
    end
    if not visible and self.preview then self.preview:set_active(false) end
  end
  function self:close()
    if self.quick_help then self.quick_help:close();self.quick_help=nil end
    if self.health_hud then self.health_hud:close();self.health_hud=nil end
    if self.native_reader then self.native_reader:close();self.native_reader=nil end
    if self.preview then self.preview:close();self.preview=nil end
    if valid(self.canvas) and identity.matches(self.canvas,self.canvas_identity) then self.canvas:RemoveFromParent() end
    self.canvas=nil;self.images={};self.image_ids={};self.clips={};self.clip_ids={};self.textures={};self.texture_ids={};self.texture_refs={};self.texture_keeper=nil;self.draw_cache={}
    if identity.matches(self.root,self.root_identity) then
      self.log('item ui removed children-after='..self.root:GetChildrenCount()..' original='..self.original_children)
    end
  end
  self.quick_help=require('host.pbz.quick_help').new(self)
  M.attach_visibility(self)
  return self
end
return M
