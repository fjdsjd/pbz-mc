-- Vanilla 182x5 sprites, cropped progress and the original 19 px row spacing.
local M={}
local colors={pink={R=1,G=.33,B=1,A=1},blue={R=.33,G=.33,B=1,A=1},red={R=1,G=.33,B=.33,A=1},
 green={R=.33,G=1,B=.33,A=1},yellow={R=1,G=1,B=.33,A=1},purple={R=.67,G=0,B=.67,A=1},white={R=1,G=1,B=1,A=1}}
function M.draw(bars,player,assets,skin,view,scale)
 local out={};if not bars then return out end
 local ids={};for id,bar in pairs(bars)do if bar.visible and bar.players and bar.players[player]then ids[#ids+1]=id end end
 if #ids==0 then return out end
 table.sort(ids);assert(skin and skin.bossbars,'original-bossbar-sprites-required')
 scale=math.max(.5,math.min(scale or 1,4,view.width/190))
 local left=(view.width-182*scale)/2;local top=12*scale
 local function sprite(path,width,y)
  if width>0 then out[#out+1]={texture=path,x=left,y=y,w=width*scale,h=5*scale,
   region={x=0,y=0,w=width,h=5,tw=182,th=5}}end
 end
 for _,id in ipairs(ids)do
  local bar=bars[id];local pair=assert(skin.bossbars[bar.color],'invalid-bossbar-color')
  local ratio=bar.max==0 and (bar.value>0 and 1 or 0)or bar.value/bar.max
  local width=math.floor(182*math.max(0,math.min(1,ratio)))
  sprite(pair.background,182,top);sprite(pair.progress,width,top)
  if bar.style~='progress'then
   local overlay=assert(skin.bossbars[bar.style],'invalid-bossbar-style')
   sprite(overlay.background,182,top);sprite(overlay.progress,width,top)
  end
  local letters,total={},0
  for _,cp in utf8.codes(bar.name or '')do
   local g=assets.glyphs[utf8.char(cp)]or assets.glyphs['?']or {advance=6}
   if total+g.advance>182 then break end
   letters[#letters+1]={glyph=g,x=total};total=total+g.advance
  end
  for _,letter in ipairs(letters)do
   local g=letter.glyph
   if g.path then
    local x=(view.width-total*scale)/2+letter.x*scale;local y=top-9*scale
    out[#out+1]={texture=g.path,x=x+scale,y=y+scale,w=g.width*scale,h=g.height*scale,region=g.region,tint={R=0,G=0,B=0,A=1}}
    out[#out+1]={texture=g.path,x=x,y=y,w=g.width*scale,h=g.height*scale,region=g.region,tint=colors[bar.color]}
   end
  end
  top=top+19*scale;if top>=view.height/3 then break end
 end
 return out
end
return M
