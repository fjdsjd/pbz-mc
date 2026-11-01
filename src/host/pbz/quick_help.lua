-- Reuse the original-font widgets from the item UI. Expiry and H only change
-- their visibility; they never rebuild the inventory or touch gameplay input.
local identity=require('host.pbz.object_identity')
local session=require('presentation.quick_help').new()
local M={};M.__index=M
function M.new(ui)
  return setmetatable({ui=ui,clips={},edges=require('presentation.camera_input').new(23)},M)
end
function M:input(batch,allowed,epoch)
  if self.closed or not batch.quick_help_controls then return end
  local function sample(pointer)
    if self.edges:update(pointer,allowed and not batch.overflow,epoch)then
      local ok,why=pcall(self.toggle,self)
      if not ok then self.ui.log('quick help toggle unavailable: '..tostring(why))end
    end
  end
  for _,pointer in ipairs(batch.samples or {})do sample(pointer)end
  sample(batch.latest)
end
function M:bind(draw,inventory)
  self.clips={};self.inventory=inventory==true;self.visible=nil
  for index,entry in ipairs(draw)do
    if entry.quick_help then self.clips[#self.clips+1]={object=self.ui.clips[index],id=self.ui.clip_ids[index],index=index}end
  end
end
function M:update(binding,now,visible)
  local camera=require('host.pbz.first_person_camera').get()
  local eligible=visible and binding~=nil and not self.inventory and self.ui.viewport~=nil
    and not (camera and (camera.inventory or camera:native_takeover()))
    and not StaticFindObject('/Script/Engine.Default__GameplayStatics'):IsGamePaused(binding.actor)
  local show=session:update(now,eligible,binding and binding.world_id.name)
  if self.visible==show then return end
  self.visible=show
  for _,row in ipairs(self.clips)do
    if identity.matches(row.object,row.id)then
      row.object:SetVisibility(show and 3 or 1)
      -- The renderer recycles these indices for inventory icons. Keep its
      -- visibility cache accurate so a hidden hint cannot hide a reused slot.
      if self.ui.draw_cache[row.index]then self.ui.draw_cache[row.index].shown=show end
    end
  end
end
function M:toggle()
  if not self.ui:valid()or not require('host.pbz.inventory_input').pointer().focused then return end
  self.ui:sync_visibility()
  if not session.eligible then return end
  session:toggle();self.ui:sync_visibility()
  self.ui.log('quick help '..(self.visible and 'shown; expires after 12 gameplay seconds' or 'dismissed'))
end
function M:close()
  self.closed=true;self.clips={}
  session.eligible=false;session.epoch=nil
end
return M
