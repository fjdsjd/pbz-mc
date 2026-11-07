-- MC experience bar, item cooldown fill, and the pinned floating-item curve.
-- Source textures/model frames remain byte-verified private MC resources.
local rules=require('rules.status_effects')
local slots=require('rules.container_slots')
local M={}
function M.draw(status,assets,layout,view,inventory,containers,stamina,activation,now,icons,real_time,submerged)
 local out={};local scale=layout.scale
 local left=math.floor((view.width-182*scale)/2);local top=view.height-30*scale
 local function add(e)out[#out+1]=e end
 if not inventory and status then
  local breath=status.effects and status.effects.water_breathing
  if breath then
   local x=view.width-25*scale;local ticks=breath.ticks;local alpha=1
   if ticks<200 then
    alpha=math.max(0,math.min(.5,ticks/100)+math.cos(ticks*math.pi/5)*(10-math.floor(ticks/20))*.025)
   end
   add{texture=assets.player_status.effect_background,x=x,y=scale,w=24*scale,h=24*scale}
   add{texture=assets.status_effects.water_breathing,x=x+3*scale,y=4*scale,w=18*scale,h=18*scale,tint={R=1,G=1,B=1,A=alpha}}
  end
  if stamina~=nil and (submerged or status.air~=nil) then
   local air=math.max(0,status.air or rules.max_air)
   local full=math.ceil((air-2)*10/rules.max_air)
   for i=1,math.ceil(air*10/rules.max_air) do
    add{texture=i<=full and assets.player_status.air or assets.player_status.air_bursting,
     x=left+(181-8*i)*scale,y=top-17*scale,w=9*scale,h=9*scale}
   end
  end
 end
 -- Overlay only the visible item rectangles. The main inventory is not rebuilt
 -- for animation; this also follows the dragged cursor and original count font.
 for _,icon in ipairs(icons or {}) do
  local frame=math.floor((real_time or now)*12)%12
  add{texture=icon.glint_texture or assets.enchanted_apple_animation,x=icon.x,y=icon.y,w=icon.w,h=icon.h,
   region={x=(frame%4)*16,y=math.floor(frame/4)*16,w=16,h=16,tw=64,th=48}}
  if icon.count and icon.count>1 then
   local text=tostring(icon.count);local width=0
   for _,c in utf8.codes(text) do width=width+assets.glyphs[utf8.char(c)].advance*scale end
   local x=icon.x+18*scale-width;local y=icon.y+9*scale
   for _,c in utf8.codes(text) do local g=assets.glyphs[utf8.char(c)]
    add{texture=g.path,x=x+scale,y=y+scale,w=g.width*scale,h=g.height*scale,tint={R=0,G=0,B=0,A=1}}
    add{texture=g.path,x=x,y=y,w=g.width*scale,h=g.height*scale};x=x+g.advance*scale
   end
  end
 end
 if not inventory and stamina then
  local fill=math.min(182,math.floor(math.max(0,math.min(1,stamina))*183))
  add{texture=assets.stamina_bar.background,x=left,y=top-7*scale,w=182*scale,h=5*scale}
  if fill>0 then add{texture=assets.stamina_bar.progress,x=left,y=top-7*scale,w=fill*scale,h=5*scale,
    region={x=0,y=0,w=fill,h=5,tw=182,th=5}} end
 end
 if status and containers then
  local function item(stack,r)
   local remaining=stack and rules.remaining(status,stack.content_id) or 0
   if remaining<=0 then return end
   local ratio=math.min(1,remaining/rules.cooldown_ticks[stack.content_id])
   add{texture=assets.feedback.drag_fill,x=r.x,y=r.y+r.h*(1-ratio),w=r.w,h=r.h*ratio,
    tint={R=.6,G=.6,B=.6,A=.6},cooldown=stack.content_id,remaining=remaining}
  end
  if inventory then for address,r in pairs(layout.slots) do item(slots.get(containers,address),r) end
  else
   for i=1,9 do item(containers.player.hotbar[tostring(i)],{x=left+(3+(i-1)*20)*scale,y=top+3*scale,w=16*scale,h=16*scale}) end
   item(containers.player.offhand,{x=left-26*scale,y=top+3*scale,w=16*scale,h=16*scale})
  end
 end
 if activation and now>=activation and now-activation<2 then
  local f=(now-activation)/2
  local phase=(10.25*f^5-24.95*f^4+25.5*f^3-13.8*f*f+4*f)*math.pi
  local size=(50+175*math.sin(phase))*scale*256/224
  local frame=math.min(119,math.floor(f*120));local a=assets.totem_activation
  add{texture=a.path,x=(view.width-size)/2,y=(view.height-size)/2,w=size,h=size,
   region={x=(frame%a.columns)*256,y=math.floor(frame/a.columns)*256,w=256,h=256,tw=a.columns*256,th=a.rows*256},activation=true,frame=frame}
 end
 return out
end
return M
