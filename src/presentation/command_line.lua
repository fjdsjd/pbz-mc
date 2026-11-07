-- Original Minecraft font and widget sprites. Geometry is clipped before it
-- reaches UMG, so long commands allocate only the glyphs visible in the field.
local M={}
local white={R=1,G=1,B=1,A=1};local black={R=0,G=0,B=0,A=.5}
local function printable(value)return tostring(value or ''):gsub('[%z\1-\31\127]',' ')end
local function glyph(assets,cp)return assets.glyphs[utf8.char(cp)] or assets.glyphs['?'] or {advance=6}end
function M.metrics(editor,assets)
 local known=editor.metrics
 if known and known.text==editor.text and known.assets==assets then return known end
 local m={text=editor.text,assets=assets,letters={},positions={[0]=0},width=0}
 for at,cp in utf8.codes(editor.text)do
  local g=glyph(assets,cp);local finish=at-1+#utf8.char(cp)
  m.letters[#m.letters+1]={start=at-1,finish=finish,x=m.width,glyph=g}
  m.width=m.width+g.advance;m.positions[finish]=m.width
 end
 editor.metrics=m;return m
end
function M.cursor_at(editor,assets,x)
 local m=M.metrics(editor,assets)
 for _,row in ipairs(m.letters)do if x<row.x+row.glyph.advance/2 then return row.start end end
 return #editor.text
end
function M.draw(editor,assets,width,height,scale,blink,message)
 local out,layout={},{hits={}}
 scale=math.max(.5,math.min(scale or 1,4));width=math.max(1,width);height=math.max(1,height)
 if editor and editor.block then scale=math.min(scale,width/324,height/220)end
 layout.scale=scale
 local function emit(texture,x,y,w,h,tint,region,clip)
  local left,top=math.max(0,x,clip and clip.x or 0),math.max(0,y,clip and clip.y or 0)
  local right,bottom=math.min(width,x+w,clip and clip.x+clip.w or width),math.min(height,y+h,clip and clip.y+clip.h or height)
  if right<=left or bottom<=top or not texture then return end
  if left~=x or top~=y or right~=x+w or bottom~=y+h then
   local r=region or {x=0,y=0,w=w/scale,h=h/scale,tw=w/scale,th=h/scale}
   region={x=r.x+(left-x)*r.w/w,y=r.y+(top-y)*r.h/h,w=(right-left)*r.w/w,h=(bottom-top)*r.h/h,tw=r.tw,th=r.th}
  end
  out[#out+1]={texture=texture,x=left,y=top,w=right-left,h=bottom-top,tint=tint,region=region}
 end
 local function rect(x,y,w,h,color,clip)emit(assets.feedback.drag_fill,x,y,w,h,color,nil,clip)end
 local function measure(value)
  local length=0;for _,cp in utf8.codes(printable(value))do length=length+glyph(assets,cp).advance*scale end;return length
 end
 local function text(value,x,y,color,clip)
  for _,cp in utf8.codes(printable(value))do
   local g=glyph(assets,cp)
   if g.path then emit(g.path,x,y,g.width*scale,g.height*scale,color or white,g.region,clip)end
   x=x+g.advance*scale;if clip and x>clip.x+clip.w then break end
  end
  return x
 end
 local function nine(sprite,x,y,w,h)
  local b=assert(sprite.border);local sw,sh=sprite.width,sprite.height
  local dx={x,x+b*scale,x+w-b*scale,x+w};local dy={y,y+b*scale,y+h-b*scale,y+h}
  local sx={0,b,sw-b,sw};local sy={0,b,sh-b,sh}
  for iy=1,3 do for ix=1,3 do
   emit(sprite.path,dx[ix],dy[iy],dx[ix+1]-dx[ix],dy[iy+1]-dy[iy],white,
    {x=sx[ix],y=sy[iy],w=sx[ix+1]-sx[ix],h=sy[iy+1]-sy[iy],tw=sw,th=sh})
  end end
 end
 local function hit(id,x,y,w,h,extra)
  local row=extra or {};row.id=id;row.x=x;row.y=y;row.w=w;row.h=h;layout.hits[#layout.hits+1]=row;return row
 end
 if not editor then
  if message then
   local box={x=2*scale,y=math.max(0,height-54*scale),w=width-4*scale,h=12*scale}
   rect(box.x,box.y,box.w,box.h,black);text(message,4*scale,box.y+2*scale,white,box)
  end
  return out,layout
 end
 local field={x=4*scale,y=height-12*scale,w=width-9*scale,h=9*scale}
 local y=height-14*scale
 if editor.block then
  local skin=assert(assets.command_ui,'original-command-widget-assets-missing')
  local labels=skin.labels or {};local x=(width-300*scale)/2
  local top=math.max(12*scale,(height-190*scale)/2)
  rect(0,0,width,height,{R=0,G=0,B=0,A=.65})
  local title=labels.set_command or '设置方块的控制台命令'
  text(title,(width-measure(title))/2,top,white)
  text(labels.command or '控制台命令',x,top+20*scale,white)
  y=top+32*scale;nine(skin.text_field_highlighted,x,y,300*scale,20*scale)
  field={x=x+4*scale,y=y+6*scale,w=292*scale,h=9*scale}
  text(labels.previous_output or '上一次输出',x,top+62*scale,white)
  nine(skin.text_field,x,top+74*scale,276*scale,20*scale)
  text(editor.previous_output or '',x+4*scale,top+80*scale,{R=.7,G=.7,B=.7,A=1},
   {x=x+4*scale,y=top+78*scale,w=268*scale,h=12*scale})
  local function button(id,label,bx,by,bw)
   local sprite=editor.pending and skin.button_disabled or editor.hover==id and skin.button_highlighted or skin.button
   nine(sprite,bx,by,bw,20*scale)
   text(label,bx+math.max(3*scale,(bw-measure(label))/2),by+6*scale,editor.pending and {R=.5,G=.5,B=.5,A=1}or white,
    {x=bx+3*scale,y=by+2*scale,w=bw-6*scale,h=16*scale})
   hit(id,bx,by,bw,20*scale)
  end
  local p=editor.block_settings
  button('track_output',p.track_output and 'O' or 'X',x+280*scale,top+74*scale,20*scale)
  button('mode',labels[p.mode] or p.mode,x,top+108*scale,98*scale)
  button('conditional',p.conditional and (labels.conditional or '条件制约')or(labels.unconditional or '无条件'),x+101*scale,top+108*scale,98*scale)
  button('auto',p.auto and (labels.always_active or '保持开启')or(labels.needs_redstone or '红石控制'),x+202*scale,top+108*scale,98*scale)
  button('submit',labels.done or '完成',x,top+144*scale,148*scale)
  button('close',labels.cancel or '取消',x+152*scale,top+144*scale,148*scale)
 else rect(2*scale,y,width-4*scale,12*scale,black)end
 local metrics=M.metrics(editor,assets);local cursor=metrics.positions[editor.cursor] or metrics.width
 local visible=field.w/scale;local scroll=math.max(0,editor.scroll or 0)
 if cursor<scroll then scroll=cursor elseif cursor>scroll+visible-1 then scroll=cursor-visible+1 end
 scroll=math.min(scroll,math.max(0,metrics.width-visible+1));editor.scroll=scroll
 layout.field=hit('field',field.x,field.y-2*scale,field.w,field.h+4*scale,{scroll=scroll})
 local first,last=editor.cursor,editor.cursor
 if editor.selection then first,last=editor:selection()elseif editor.selected_all then first,last=0,#editor.text end
 if first~=last then rect(field.x+((metrics.positions[first] or 0)-scroll)*scale,field.y-scale,
  ((metrics.positions[last] or metrics.width)-(metrics.positions[first] or 0))*scale,10*scale,{R=.1,G=.2,B=.8,A=.6},field)end
 local lo,hi=1,#metrics.letters
 while lo<=hi do
  local mid=(lo+hi)//2;local row=metrics.letters[mid]
  if row.x+row.glyph.advance<=scroll then lo=mid+1 else hi=mid-1 end
 end
 for index=lo,#metrics.letters do
  local row=metrics.letters[index]
  local g=row.glyph;local gx=field.x+(row.x-scroll)*scale
  if gx>field.x+field.w then break end
  if gx+g.advance*scale>field.x and g.path then emit(g.path,gx,field.y,g.width*scale,g.height*scale,white,g.region,field)end
 end
 if blink and not editor.pending then rect(field.x+(cursor-scroll)*scale,field.y-scale,scale,9*scale,white,field)end
 local status=editor.error or editor.message
 if status then
  local box={x=2*scale,y=math.max(0,y-14*scale),w=width-4*scale,h=12*scale}
  rect(box.x,box.y,box.w,box.h,black);text(status,box.x+2*scale,box.y+2*scale,editor.error and {R=1,G=.3,B=.3,A=1}or white,box)
 else
  local values
  if editor.visible_suggestions then values=editor:visible_suggestions()else
   values={};local all=editor.completion and editor.completion.values or editor:suggestions()
   for i=1,math.min(10,#all)do values[i]={text=all[i],index=i,selected=editor.completion and editor.completion.index==i or not editor.completion and i==1}end
  end
  local count=math.min(10,#values,math.floor(y/(12*scale)))
  local boxwidth=math.min(field.w,math.max(155*scale,math.min(300*scale,field.w)))
  for i=1,count do
   local value=values[i];local box={x=field.x-2*scale,y=y-(count-i+1)*12*scale,w=boxwidth,h=11*scale}
   rect(box.x,box.y,box.w,box.h,{R=0,G=0,B=0,A=1})
   text(value.text,box.x+2*scale,box.y+scale,value.selected and {R=1,G=1,B=0,A=1}or {R=.75,G=.75,B=.75,A=1},box)
   hit('suggestion',box.x,box.y,box.w,box.h,{index=value.index})
  end
 end
 return out,layout
end
return M
