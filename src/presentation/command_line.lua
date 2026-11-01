-- Vanilla ChatScreen's translucent fill and original Minecraft font. There is
-- no invented chat-frame artwork; rectangles reuse the existing MC white texel.
local M={}
function M.draw(editor,assets,width,height,scale,blink,message)
 local out={};scale=math.min(scale,4)
 local function rect(x,y,w,h,color)
  out[#out+1]={texture=assets.feedback.drag_fill,x=x,y=y,w=w,h=h,tint=color}
 end
 local white={R=1,G=1,B=1,A=1};local black={R=0,G=0,B=0,A=.5}
 local function text(value,x,y,color)
  for _,cp in utf8.codes(value)do
   local g=assert(assets.glyphs[utf8.char(cp)],'command-original-glyph-missing:'..cp)
   if g.path then out[#out+1]={texture=g.path,x=x,y=y,w=g.width*scale,h=g.height*scale,region=g.region,tint=color or white}end
   x=x+g.advance*scale
  end
  return x
 end
 if not editor then
  if message then rect(2*scale,height-54*scale,math.min(width-4*scale,360*scale),12*scale,black);text(message,4*scale,height-52*scale)end
  return out
 end
 local y=height-14*scale
 rect(2*scale,y,width-4*scale,12*scale,black)
 if editor.selected_all then rect(4*scale,y+1*scale,math.min(#editor.text*6*scale,width-10*scale),10*scale,{R=.1,G=.2,B=.8,A=.6})end
 local x=text(editor.text,4*scale,y+2*scale)
 if blink then
  local cursor=4*scale
  for _,cp in utf8.codes(editor.text:sub(1,editor.cursor))do cursor=cursor+assets.glyphs[utf8.char(cp)].advance*scale end
  rect(cursor,y+1*scale,scale,9*scale,white)
 end
 local values=editor.completion and editor.completion.values or editor:suggestions()
 if editor.error then
  rect(2*scale,y-14*scale,math.min(width-4*scale,390*scale),12*scale,black)
  text(editor.error,4*scale,y-12*scale,{R=1,G=.3,B=.3,A=1})
 else
  for i,value in ipairs(values)do
   local top=y-(#values-i+1)*12*scale
   rect(2*scale,top,155*scale,11*scale,black)
   local active=editor.completion and editor.completion.index==i or not editor.completion and i==1
   text(value,4*scale,top+scale,active and {R=1,G=1,B=0,A=1}or {R=.75,G=.75,B=.75,A=1})
  end
 end
 return out
end
return M
