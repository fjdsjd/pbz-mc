-- MC InGameHud: 40 ticks of selected-item text, alpha=remaining*256/10.
-- PBZ adaptations: numbered native slot references and a hint on each actual
-- hotbar slot change (including two stacks of the same item). No native reads.
local native=require('rules.native_slot_reference')
local M={};M.__index=M
function M.resolve(stack,assets,snapshot,epoch)
  if not stack then return end
  if native.is(stack) then
    local value=require('content.native_slot_icons').describe(stack,snapshot,epoch)
    return {text=value.label,fallback=value.slot_name,key=stack.content_id..'/'..value.badge,
      native_name=value.equipment_name,number=value.number}
  end
  return {text=assets.labels[stack.content_id] or stack.content_id,key=stack.content_id}
end
function M.new()return setmetatable({builds=0},M)end
function M:update(data,assets,snapshot,epoch,now,view,scale,armor_top)
  local index=data.player.selected;local stack=data.player.hotbar[tostring(index)]
  local name=M.resolve(stack,assets,snapshot,epoch)
  local signature=name and (index..'\0'..name.key..'\0'..name.text) or ''
  if self.signature~=signature or (self.last_time and now<self.last_time) then
    self.signature=signature;self.began=now;self.ends=now+2;self.geometry=nil
  end
  self.last_time=now
  local remaining=name and math.max(0,math.ceil((self.ends-now)*20-1e-6)) or 0
  local alpha=math.min(255,math.floor(remaining*256/10))/255
  self.report={text=name and name.text,slot=index,alpha=alpha,visible=alpha>0,
    began=self.began,ends=self.ends,remaining_ticks=remaining,builds=self.builds}
  if alpha<=0 then return {} end
  local geometry=table.concat({view.width,view.height,scale,armor_top or 0},'/')
  if self.geometry~=geometry or self.assets~=assets then
    local title=name.text;local missing=false
    for _,code in utf8.codes(title)do if not assets.glyphs[utf8.char(code)]then missing=true;break end end
    if missing and name.fallback then title=name.fallback end
    local glyphs,width={},0;local limit=view.width-12*scale
    for _,code in utf8.codes(title)do
      local g=assets.glyphs[utf8.char(code)] or assets.glyphs['?']
      if width+g.advance*scale>limit then break end
      glyphs[#glyphs+1]=g;width=width+g.advance*scale
    end
    -- Our hotbar is eight GUI pixels above vanilla's bottom edge; keep the
    -- same gap to its health/experience bars (vanilla height minus 59).
    local x=math.floor((view.width-width)/2);local y=view.height-67*scale
    if armor_top then y=math.min(y,armor_top-11*scale)end
    local draw={}
    for _,g in ipairs(glyphs)do
      if g.path then
        draw[#draw+1]={texture=g.path,region=g.region,x=x+scale,y=y+scale,w=g.width*scale,h=g.height*scale,tint={R=0,G=0,B=0,A=alpha}}
        draw[#draw+1]={texture=g.path,region=g.region,x=x,y=y,w=g.width*scale,h=g.height*scale,tint={R=1,G=1,B=1,A=alpha}}
      end
      x=x+g.advance*scale
    end
    self.draw=draw;self.geometry=geometry;self.assets=assets;self.drawn=title;self.missing_font=missing;self.builds=self.builds+1
  else
    for _,entry in ipairs(self.draw)do entry.tint.A=alpha end
  end
  self.report.drawn=self.drawn;self.report.missing_font=self.missing_font;self.report.builds=self.builds
  return self.draw
end
return M
