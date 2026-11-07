-- An independently cached command layer; typing never rebuilds inventory,
-- preview, held meshes, textures or world objects.
local id=require('host.pbz.object_identity')
local M={};M.__index=M
function M.attach_assets(ui)
 if ui.assets.command_ui then return ui.assets.command_ui end
 local file=assert(io.open(ui.asset_path..'/command/manifest.json','rb'),'original-command-widgets-manifest-missing')
 local raw=file:read('*a');file:close()
 local manifest=assert(require('dkjson').decode(raw))
 assert(manifest.schema==1 and manifest.minecraft_version=='26.3' and manifest.layout_profile=='java-command-widgets-v1','unsupported-command-widget-layout')
 local outputs={}
 for _,entry in ipairs(manifest.outputs or {})do
  assert(type(entry.path)=='string' and entry.path:sub(1,8)=='command/' and not entry.path:find('..',1,true)
   and not entry.path:find(':',1,true) and type(entry.sha256)=='string' and #entry.sha256==64,'invalid-command-widget-resource')
  local old=ui.records[entry.path];assert(not old or old.sha256==entry.sha256,'command-widget-resource-conflict')
  outputs[entry.path]=entry
 end
 local skin=assert(manifest.widgets)
 for _,name in ipairs({'button','button_highlighted','button_disabled','text_field','text_field_highlighted'})do
  local sprite=assert(skin[name],'missing-original-command-widget:'..name)
  assert(outputs[sprite.path] and sprite.width==200 and sprite.height==20
   and (sprite.border==1 or sprite.border==3),'invalid-original-command-widget:'..name)
 end
 for path,record in pairs(outputs)do ui.records[path]=record end
 skin.labels=manifest.labels;skin.bossbars=manifest.bossbars;ui.assets.command_ui=skin;return skin
end
function M.new(ui)
 local self=setmetatable({ui=ui,images={},cache={}},M)
 local canvas=StaticConstructObject(StaticFindObject('/Script/UMG.CanvasPanel'),ui.tree)
 self.canvas=canvas;self.id=id.capture(canvas)
 local slot=ui.canvas:AddChildToCanvas(canvas);slot:SetZOrder(5000);canvas:SetVisibility(1)
 return self
end
function M:render(editor,now,message)
 if not self.ui:valid() or not id.matches(self.canvas,self.id)then return false end
 local view=self.ui.viewport;if not view then return end
 local blink=editor~=nil and math.floor(now*2)%2==0
 if editor and editor.block then M.attach_assets(self.ui)end
 local signature=table.concat({tostring(editor),editor and editor.revision or -1,tostring(blink),view.width,view.height,self.ui.layout.scale,self.ui.dpi,message or ''},'/')
 if self.signature==signature then return end
 self.signature=signature
 local draw,layout=require('presentation.command_line').draw(editor,self.ui.assets,view.width,view.height,self.ui.layout.scale,blink,message)
 self.layout=layout
 local dpi=self.ui.dpi
 for i,e in ipairs(draw)do
  local row=self.images[i]
  if not row then
   local clip=StaticConstructObject(StaticFindObject('/Script/UMG.CanvasPanel'),self.ui.tree)
   local image=StaticConstructObject(StaticFindObject('/Script/UMG.Image'),self.ui.tree)
   self.canvas:AddChildToCanvas(clip);clip:SetClipping(1);clip:AddChildToCanvas(image)
   row={clip=clip,image=image};self.images[i]=row
  end
  local key=table.concat({e.texture,e.x,e.y,e.w,e.h,dpi,require('storage.canonical_json')(e.tint or {}),require('storage.canonical_json')(e.region or {})},'|')
  if self.cache[i]~=key then
   row.image:SetBrushFromTexture(self.ui:texture(e.texture),false)
   row.image:SetColorAndOpacity(e.tint or {R=1,G=1,B=1,A=1})
   row.clip.Slot:SetPosition({X=e.x/dpi,Y=e.y/dpi});row.clip.Slot:SetSize({X=e.w/dpi,Y=e.h/dpi})
   local r=e.region
   row.image.Slot:SetPosition({X=r and -r.x*e.w/r.w/dpi or 0,Y=r and -r.y*e.h/r.h/dpi or 0})
   row.image.Slot:SetSize({X=r and r.tw*e.w/r.w/dpi or e.w/dpi,Y=r and r.th*e.h/r.h/dpi or e.h/dpi})
   row.clip:SetVisibility(3);self.cache[i]=key
  end
 end
 for i=#draw+1,#self.images do if self.cache[i]then self.images[i].clip:SetVisibility(1);self.cache[i]=nil end end
 self.canvas:SetVisibility(#draw>0 and 3 or 1)
 return true
end
function M:hit(x,y)
 local hits=self.layout and self.layout.hits or {}
 for i=#hits,1,-1 do local hit=hits[i]
  if x>=hit.x and x<hit.x+hit.w and y>=hit.y and y<hit.y+hit.h then return hit end
 end
end
return M
