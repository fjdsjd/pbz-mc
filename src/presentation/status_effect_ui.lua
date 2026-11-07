-- Vanilla AbstractInventoryScreen's 120x32 effect cards, original font/sprites.
local rules=require('rules.status_effects')
local M={}
function M.draw(value,assets,layout)
 local list=rules.list(value);local out={};local s=layout.scale
 local x=layout.inventory.x+layout.inventory.w+2*s;local y=layout.inventory.y
 local function image(texture,a,b,w,h,tint)out[#out+1]={texture=texture,x=a,y=b,w=w,h=h,tint=tint}end
 local function text(str,a,b,color)
  for _,c in utf8.codes(str) do
   local g=assert(assets.glyphs[utf8.char(c)],'status-original-glyph-missing:'..c)
   if g.path then
    image(g.path,a+s,b+s,g.width*s,g.height*s,{R=0,G=0,B=0,A=1})
    image(g.path,a,b,g.width*s,g.height*s,color)
   end
   a=a+g.advance*s
  end
 end
 for _,e in ipairs(list) do
  image(assets.status_effects.background,x,y,120*s,32*s)
  image(assets.status_effects[e.id],x+6*s,y+7*s,18*s,18*s)
  local roman=({'II','III','IV','V','VI'})[e.amplifier]or(e.amplifier>0 and tostring(e.amplifier+1)or nil)
  text(e.name..(roman and ' '..roman or ''),x+28*s,y+6*s,{R=1,G=1,B=1,A=1})
  local seconds=math.floor(e.ticks/20)
  text(string.format('%d:%02d',math.floor(seconds/60),seconds%60),x+28*s,y+16*s,{R=.5,G=.5,B=.5,A=1})
  y=y+math.min(33,160/math.max(1,#list))*s
 end
 return out
end
return M
