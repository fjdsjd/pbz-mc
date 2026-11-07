-- Original MC artwork and one authoritative container snapshot. No native API.
local slots=require('rules.container_slots')
local native=require('rules.native_slot_reference')
local native_icons=require('content.native_slot_icons')
local M={}
local gui='original/textures/gui/'
local layouts,layout_order={},{}
function M.catalogue_assets(assets,manifest,records)
  assert(type(manifest)=='table' and manifest.schema==1 and manifest.layout_profile=='bedrock-classified-pages-v1'
    and manifest.columns==5 and manifest.rows==4,'unsupported-catalogue-asset-layout')
  local outputs={}
  for _,entry in ipairs(manifest.outputs)do
    assert(entry.path:match('^bedrock_catalogue/') and entry.operation=='byte-copy','invalid-catalogue-resource')
    outputs[entry.path]=entry
    if records then assert(not records[entry.path],'catalogue-texture-path-conflict');records[entry.path]=entry end
  end
  for _,key in ipairs({'panel','tab_active','tab_inactive','tab_active_hover','tab_hover','slot','slot_hover',
      'previous','previous_hover','next','next_hover','construction','equipment','nature','items','tooltip'})do
    local skin=assert(manifest.skin and manifest.skin[key],'missing-original-catalogue-skin:'..key)
    local entry=assert(outputs[skin.path],'unlisted-original-catalogue-texture:'..key)
    assert(skin.width==entry.width and skin.height==entry.height and skin.width>0 and skin.height>0,
      'catalogue-resource-size-mismatch:'..key)
    if skin.nineslice_size then
      assert(type(skin.nineslice_size)=='number' and skin.nineslice_size>0
        and skin.nineslice_size*2<math.min(skin.width,skin.height),'invalid-original-nine-slice:'..key)
    end
  end
  assets.catalogue_ui=manifest;return assets
end
function M.layout(width,height,requested_scale,catalogue,effects,catalogue_state)
  assert(width>0 and height>0,'invalid-viewport')
  if catalogue then assert(width>=(effects and 457 or 335) and height>=190,'catalogue-viewport-too-small')end
  local view=catalogue and require('rules.item_catalogue').page(catalogue_state and catalogue_state.category,catalogue_state and catalogue_state.page)
  local key=table.concat({width,height,requested_scale or 4,tostring(catalogue),tostring(effects),view and view.category or '',view and view.page or 0,view and view.total or 0},'/')
  if layouts[key]then return layouts[key]end
  local scale=math.max(1,math.min(math.floor(requested_scale or 4),math.floor(width/(catalogue and (effects and 465 or 355) or 220)),math.floor(height/190)))
  local left=math.floor((width-(catalogue and (effects and 449 or 327) or 176)*scale)/2)+(catalogue and 151*scale or 0)
  local top=math.floor((height-166*scale)/2)
  local layout={scale=scale,inventory={x=left,y=top,w=176*scale,h=166*scale},slots={}}
  -- Exact black area in the retained original inventory.png: x26..74/y8..77.
  layout.preview={x=left+26*scale,y=top+8*scale,w=49*scale,h=70*scale}
  local function slot(address,x,y)
    layout.slots[address]={x=left+x*scale,y=top+y*scale,w=16*scale,h=16*scale}
  end
  for i=1,27 do slot('player/main/'..i,8+((i-1)%9)*18,84+math.floor((i-1)/9)*18) end
  for i=1,9 do slot('player/hotbar/'..i,8+(i-1)*18,142) end
  for i,name in ipairs({'head','chest','legs','feet'}) do slot('player/armor/'..name,8,8+(i-1)*18) end
  slot('player/offhand',77,62)
  slot('trash',154,62)
  for i=1,4 do slot('craft/'..i,98+((i-1)%2)*18,18+math.floor((i-1)/2)*18) end
  layout.output={x=left+154*scale,y=top+28*scale,w=16*scale,h=16*scale}
  if catalogue then
    layout.catalogue={x=left-151*scale,y=top,w=147*scale,h=166*scale,slots={},entries=view.entries,
      category=view.category,page=view.page,pages=view.pages,label=view.label,total=view.total,tabs={}}
    local groups=require('rules.item_catalogue').categories();local step=math.min(23,137/#groups)
    for i,group in ipairs(groups)do
      layout.catalogue.tabs[group.id]={x=layout.catalogue.x+(5+(i-1)*step)*scale,y=top+6*scale,w=(step-1)*scale,h=25*scale}
    end
    layout.catalogue.previous={x=layout.catalogue.x+9*scale,y=top+142*scale,w=18*scale,h=18*scale}
    layout.catalogue.next={x=layout.catalogue.x+120*scale,y=top+142*scale,w=18*scale,h=18*scale}
    for i,id in ipairs(layout.catalogue.entries) do
      layout.catalogue.slots[id]={x=layout.catalogue.x+(11+(i-1)%5*25)*scale,
        y=top+(50+math.floor((i-1)/5)*22)*scale,w=16*scale,h=16*scale}
    end
  end
  layouts[key]=layout;layout_order[#layout_order+1]=key
  if #layout_order>16 then layouts[table.remove(layout_order,1)]=nil end
  return layout
end
function M.draw(data,assets,width,height,options)
  options=options or {}
  local feedback=options.feedback or {}
  local visible=feedback.preview or data
  local layout=M.layout(width,height,options.scale,options.inventory,options.has_effects,options.catalogue_state)
  local scale=layout.scale
  local draw={}
  local function image(path,x,y,w,h,tint,region)
    draw[#draw+1]={texture=path,x=x,y=y,w=w,h=h,tint=tint,region=region}
  end
  local function skin(key,rect,tint)
    local source=assert(assets.catalogue_ui and assets.catalogue_ui.skin[key],'missing-original-catalogue-resource:'..key)
    local border=source.nineslice_size
    if not border then image(source.path,rect.x,rect.y,rect.w,rect.h,tint);return end
    -- The source sidecar defines the exact nine-slice borders used by Bedrock.
    -- Draw original pixels; no repainted panel or assembled replacement asset.
    local xs={0,border,source.width-border,source.width};local ys={0,border,source.height-border,source.height}
    local dx={0,border*scale,rect.w-border*scale,rect.w};local dy={0,border*scale,rect.h-border*scale,rect.h}
    assert(dx[2]<=dx[3] and dy[2]<=dy[3],'catalogue-nine-slice-target-too-small')
    for y=1,3 do for x=1,3 do
      image(source.path,rect.x+dx[x],rect.y+dy[y],dx[x+1]-dx[x],dy[y+1]-dy[y],tint,
        {x=xs[x],y=ys[y],w=xs[x+1]-xs[x],h=ys[y+1]-ys[y],tw=source.width,th=source.height})
    end end
  end
  local function text(value,x,y,right,color)
    local glyphs,total={},0
    for _,code in utf8.codes(value) do
      local glyph=assets.glyphs[utf8.char(code)]
      assert(glyph,'missing-original-mc-glyph:'..code)
      glyphs[#glyphs+1]=glyph;total=total+glyph.advance*scale
    end
    if right then x=x-total+scale end
    for _,glyph in ipairs(glyphs) do
      if glyph.path then
        image(glyph.path,x+scale,y+scale,glyph.width*scale,glyph.height*scale,{R=0,G=0,B=0,A=1},glyph.region)
        image(glyph.path,x,y,glyph.width*scale,glyph.height*scale,color,glyph.region)
      end
      x=x+glyph.advance*scale
    end
  end
  local function native_label(value,y)
    if not native.is(value) then return end
    local description=native_icons.describe(value,options.native_equipment,options.native_equipment_epoch)
    -- Names supplied by PBZ can contain glyphs outside the private UI subset.
    -- Do not turn an untranslated ID or a partial row of '?' into a weapon
    -- name. Until its original MC glyphs are available, show the stable slot.
    local title=description.label
    local missing_font=false
    if description.equipment_name then
      for _,code in utf8.codes(description.equipment_name) do
        if not assets.glyphs[utf8.char(code)] then title=description.slot_name;missing_font=true;break end
      end
    end
    local chars,total={},0
    local limit=width-8*scale
    for _,code in utf8.codes(title) do
      local c=utf8.char(code);local g=assets.glyphs[c]
      assert(g,'missing-original-slot-label-glyph:'..code)
      if total+g.advance*scale>limit-18*scale then chars[#chars+1]='...';total=total+18*scale;break end
      chars[#chars+1]=c;total=total+g.advance*scale
    end
    local label=table.concat(chars)
    text(label,math.floor((width-total)/2),math.max(2*scale,y),false)
    layout.native_label={text=title,drawn=label,state=description.state,native_name=description.equipment_name,missing_font=missing_font,
      category=value.metadata.category,number=description.number,equipment_id=description.equipment_id}
  end
  local function item(value,rect,count_color)
    if not value then return end
    local path=assets.item_icons[value.content_id]
    if native.is(value) then
      local description=native_icons.describe(value,options.native_equipment,options.native_equipment_epoch)
      path=description.icon and assets.item_icons[description.icon]
      if path then image(path,rect.x,rect.y,rect.w,rect.h)
      else text(description.state=='empty' and '-' or '?',rect.x+5*scale,rect.y,false) end
      -- Use the original MC font, keeping a native reference distinguishable
      -- from an otherwise identical MC wooden sword without invented artwork.
      text(description.badge,rect.x,rect.y+9*scale,false)
      return
    end
    if path then
      image(path,rect.x,rect.y,rect.w,rect.h)
      local animation=assets.item_glint_animations and assets.item_glint_animations[value.content_id]
      if value.content_id=='pbzmc:mace'and value.metadata and value.metadata.command_enchantments and next(value.metadata.command_enchantments)then
        animation=assert(assets.item_glint_animations and assets.item_glint_animations['pbzmc:mace_density'],'original-enchanted-mace-icon-required')
      end
      if value.content_id=='pbzmc:enchanted_golden_apple' or animation then
        local icon=draw[#draw];icon.enchanted=true;icon.glint_texture=animation;icon.count=value.count
      end
    end
    -- Missing model icons remain explicit gaps, never substitute invented art.
    if value.count>1 and not require('rules.block_catalogue').infinite(value) then
      text(tostring(value.count),rect.x+17*scale,rect.y+9*scale,true,count_color)
    end
  end
  if options.inventory then
    local rect=layout.inventory
    image('inventory_panel.png',rect.x,rect.y,rect.w,rect.h)
    text('合成',rect.x+97*scale,rect.y+6*scale,false,{R=.25,G=.25,B=.25,A=1})
    image(gui..'sprites/recipe_book/button.png',rect.x+104*scale,rect.y+61*scale,20*scale,18*scale)
    local trash=layout.slots.trash
    text('垃圾槽',rect.x+143*scale,rect.y+51*scale,false,{R=.25,G=.25,B=.25,A=1})
    local skin_trash=assert(assets.trash_slot,'missing-original-trash-slot')
    image(skin_trash.texture,trash.x-scale,trash.y-scale,18*scale,18*scale,nil,skin_trash.region)
    if visible.trash then
      -- Cover the original X with an unmodified occupied-slot frame so the
      -- recoverable item stays legible. Both regions are original MC pixels.
      image('inventory_panel.png',trash.x-scale,trash.y-scale,18*scale,18*scale,nil,
        {x=7,y=83,w=18,h=18,tw=176,th=166})
    end
    local catalogue=layout.catalogue
    skin('panel',catalogue)
    text(catalogue.label,catalogue.x+11*scale,catalogue.y+35*scale,false,{R=.25,G=.25,B=.25,A=1})
    for _,group in ipairs(require('rules.item_catalogue').categories())do
      local tab=catalogue.tabs[group.id]
      local active=group.id==catalogue.category
      local hover=feedback.hovered=='catalogue_category:'..group.id
      skin(active and (hover and 'tab_active_hover' or 'tab_active') or (hover and 'tab_hover' or 'tab_inactive'),tab)
      local icon={x=tab.x+3*scale,y=tab.y+4*scale,w=16*scale,h=16*scale}
      if group.skin then skin(group.skin,icon)
      else image(assert(assets.item_icons[group.icon],'missing-original-category-icon:'..group.id),icon.x,icon.y,icon.w,icon.h)end
    end
    local page_text=catalogue.page..' / '..catalogue.pages
    text(page_text,catalogue.x+58*scale,catalogue.y+148*scale,false,{R=.25,G=.25,B=.25,A=1})
    for _,name in ipairs({'previous','next'})do
      local enabled=name=='previous' and catalogue.page>1 or name=='next' and catalogue.page<catalogue.pages
      skin(feedback.hovered=='catalogue_page:'..name and enabled and name..'_hover' or name,catalogue[name],
        enabled and nil or {R=.5,G=.5,B=.5,A=.6})
    end
    for _,id in ipairs(catalogue.entries) do
      local r=catalogue.slots[id]
      assert(assets.item_icons[id],'missing-original-catalogue-item-icon:'..id)
      skin('slot',{x=r.x-2*scale,y=r.y-2*scale,w=20*scale,h=20*scale})
      item({content_id=id,count=1},r)
    end
    if catalogue.total==0 then text('暂无物品',catalogue.x+48*scale,catalogue.y+85*scale,false,{R=.4,G=.4,B=.4,A=1})end
    local hover_id=feedback.hovered and feedback.hovered:match('^catalogue:(.+)$')
    local hovered=feedback.hovered=='craft/output' and layout.output or (feedback.hovered and layout.slots[feedback.hovered])
    local catalogue_hover=hover_id and catalogue.slots[hover_id]
    if catalogue_hover then skin('slot_hover',{x=catalogue_hover.x-4*scale,y=catalogue_hover.y-4*scale,w=24*scale,h=24*scale})end
    local function hover_layer(name)
      if hovered then
        image(assert(assets.feedback[name]),hovered.x-4*scale,hovered.y-4*scale,24*scale,24*scale)
      end
    end
    hover_layer('hover_back')
    for _,address in ipairs(feedback.dragged or {}) do
      local rect=layout.slots[address]
      if rect then image(assert(assets.feedback.drag_fill),rect.x,rect.y,rect.w,rect.h,{R=1,G=1,B=1,A=128/255}) end
    end
    for address,rect in pairs(layout.slots) do
      item(slots.get(visible,address),rect,feedback.count_colors and feedback.count_colors[address])
    end
    hover_layer('hover_front')
    if not visible.cursor and feedback.hovered and layout.slots[feedback.hovered] then
      native_label(slots.get(visible,feedback.hovered),rect.y-12*scale)
    elseif native.is(visible.cursor) then
      native_label(visible.cursor,rect.y-12*scale)
    end
  else
    local left=math.floor((width-182*scale)/2)
    local top=height-30*scale
    image(gui..'sprites/hud/hotbar.png',left,top,182*scale,22*scale)
    image(gui..'sprites/hud/hotbar_selection.png',left+(data.player.selected-1)*20*scale-scale,top-scale,24*scale,23*scale)
    if data.player.offhand then
      image(gui..'sprites/hud/hotbar_offhand_left.png',left-29*scale,top-scale,29*scale,24*scale)
      item(data.player.offhand,{x=left-26*scale,y=top+3*scale,w=16*scale,h=16*scale})
    end
    for i=1,9 do item(data.player.hotbar[tostring(i)],{x=left+(3+(i-1)*20)*scale,y=top+3*scale,w=16*scale,h=16*scale}) end
    -- Selected item names are timed by the small independent HUD loop; the
    -- entire inventory/hotbar is never rebuilt to fade a line of text.
    if options.player_status then
      local commands,status=require('presentation.player_status').draw(options.player_status,assets.player_status,
        {left=left,top=top},scale,{expected_epoch=options.player_status_epoch,
          visible=options.player_status_visible,
          diagnostic_red_only=options.player_status_diagnostic_red_only==true})
      for _,command in ipairs(commands) do draw[#draw+1]=command end
      layout.player_status=status
    end
    local first=#draw+1
    for line,value in ipairs(require('presentation.quick_help').lines)do
      text(value,8*scale,(22+(line-1)*12)*scale,false)
    end
    for i=first,#draw do draw[i].quick_help=true end
  end
  if options.inventory and (not visible.cursor or feedback.hovered=='trash') then
    local id=feedback.hovered and feedback.hovered:match('^catalogue:(.+)$')
    local rect=id and layout.catalogue.slots[id]
    local tab_id=feedback.hovered and feedback.hovered:match('^catalogue_category:(.+)$')
    local label
    local lines
    if feedback.hovered=='trash' then
      rect=layout.slots.trash
      lines={'垃圾槽','Ctrl + 左键：整组移入','再次放入替换；关包清空','点击取回最后一组','PBZ 武器槽不可丢弃'}
    elseif tab_id then
      rect=layout.catalogue.tabs[tab_id]
      if rect then label=require('rules.item_catalogue').page(tab_id,1).label end
    elseif rect then label=assert(assets.labels and assets.labels[id],'missing-original-catalogue-item-label:'..id)end
    if rect then
      lines=lines or {label}
      local pixels=0
      for _,line in ipairs(lines)do
        local length=0
        for _,cp in utf8.codes(line)do length=length+assert(assets.glyphs[utf8.char(cp)],'missing-original-catalogue-label-glyph').advance*scale end
        pixels=math.max(pixels,length)
      end
      local w,h=pixels+10*scale,(8+#lines*10)*scale
      assert(w<=width-4*scale,'catalogue-tooltip-too-wide')
      local x=math.min(width-w-2*scale,math.max(2*scale,(options.pointer and options.pointer.x or rect.x)+12*scale))
      local y=math.max(2*scale,math.min(height-h-2*scale,(options.pointer and options.pointer.y or rect.y)-h-3*scale))
      local first=#draw+1
      skin('tooltip',{x=x,y=y,w=w,h=h})
      for i,line in ipairs(lines)do text(line,x+5*scale,y+(5+(i-1)*10)*scale,false)end
      for i=first,#draw do draw[i].z=1800+i end
    end
  end
  if options.inventory and options.pointer and options.pointer.focused and options.pointer.inside and visible.cursor then
    local first=#draw+1
    item(visible.cursor,{x=options.pointer.x-8*scale,y=options.pointer.y-8*scale,w=16*scale,h=16*scale})
    for i=first,#draw do draw[i].z=2000+i end
  end
  if options.crosshair and not options.inventory then
    local size=15*scale
    image(assert(assets.crosshair,'original-crosshair-required'),math.floor((width-size)/2),math.floor((height-size)/2),size,size)
  end
  return draw,layout
end
local function contains(layout,rect,x,y)
  -- MC includes the one GUI-pixel slot border in the pointer target (18x18).
  local border=layout.scale
  return x>=rect.x-border and y>=rect.y-border and x<rect.x+rect.w+border and y<rect.y+rect.h+border
end
function M.hit(layout,x,y)
  for address,rect in pairs(layout.slots) do
    if contains(layout,rect,x,y) then return address end
  end
end
function M.hover(layout,x,y)
  local control=M.catalogue_control(layout,x,y)
  if control then return control.kind..':'..(control.category or (control.steps<0 and 'previous' or 'next'))end
  local id=M.catalogue_hit(layout,x,y)
  if id then return 'catalogue:'..id end
  if contains(layout,layout.output,x,y) then return 'craft/output' end
  return M.hit(layout,x,y)
end
function M.catalogue_contains(layout,x,y)
  local r=layout.catalogue
  return r and x>=r.x and y>=r.y and x<r.x+r.w and y<r.y+r.h or false
end
function M.catalogue_control(layout,x,y)
  local c=layout.catalogue;if not c then return end
  local function inside(r)return x>=r.x and y>=r.y and x<r.x+r.w and y<r.y+r.h end
  for id,rect in pairs(c.tabs)do if inside(rect)then return {kind='catalogue_category',category=id}end end
  if c.page>1 and inside(c.previous)then return {kind='catalogue_page',steps=-1}end
  if c.page<c.pages and inside(c.next)then return {kind='catalogue_page',steps=1}end
end
function M.catalogue_hit(layout,x,y)
  if layout.catalogue then
    for id,rect in pairs(layout.catalogue.slots) do if contains(layout,rect,x,y) then return id end end
  end
end
return M
