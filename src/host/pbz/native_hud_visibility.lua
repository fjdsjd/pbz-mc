-- Read-only display gate. Full-screen FlowVideo movies do not necessarily
-- change the player's view target; the appended MC canvas must still hide.
local identity=require('host.pbz.object_identity')
local valid=require('host.pbz.appearance').valid
local M={};M.__index=M
local movie_path='/Game/PBZContent/Blueprint/FlowGraph/UI/WBP_FlowVideo.WBP_FlowVideo_C:BP_OnActivated'
local function entry(object)return {object=object,id=identity.capture(object)}end
local function current(row,binding)
 return identity.matches(row.object,row.id)and identity.matches(row.object:GetWorld(),binding.world_id)
end
local function painted(widget)
 if not valid(widget)then return false end
 local visibility=widget:GetVisibility()
 return visibility~=1 and visibility~=2 and widget:GetRenderOpacity()>0
end
function M.new(log)
 return setmetatable({log=log or function()end,huds={},movies={},scans=0},M)
end
function M:watch_movie()
 if self.hook or self.hook_failed or type(RegisterHook)~='function'then return end
 local fn=StaticFindObject(movie_path)
 if not valid(fn)then return end -- The class may load only in a later chapter.
 local ok,pre,post=pcall(RegisterHook,movie_path,function(context)
  if self.closed then return end
  local success,why=pcall(function()
   local movie=context:get()
   if valid(movie)then self.movies[movie:GetAddress()]=entry(movie);self.next_scan=nil end
   if self.on_change then self.on_change()end
  end)
  if not success then self.log('movie HUD visibility callback: '..tostring(why))end
 end)
 if ok then self.hook={pre,post}
 else self.hook_failed=true;self.log('movie HUD visibility uses cached polling: '..tostring(pre))end
end
function M:reason(binding,now)
 if not binding or binding.closing or not binding:is_current()then self.binding=nil;return 'no-current-player'end
 if self.binding~=binding then
  self.binding=binding;self.huds={};self.movies={};self.had_hud=false;self.next_scan=nil
 end
 if not self.next_scan or now>=self.next_scan then
  self.next_scan=now+.25;self.scans=self.scans+1
  self:watch_movie()
  for _,pair in ipairs({{'W_FrontEndHUDLayout_C',self.huds},{'WBP_FlowVideo_C',self.movies}})do
   for _,object in ipairs(FindAllOf(pair[1])or{})do
    if valid(object)and object:GetFullName():find('/Engine/Transient.',1,true)
      and identity.matches(object:GetWorld(),binding.world_id)then pair[2][object:GetAddress()]=entry(object)end
   end
  end
 end
 for key,row in pairs(self.movies)do
  if not current(row,binding)then self.movies[key]=nil
  elseif row.object:IsActivated()then return 'native-flow-video'end
 end
 local found=false
 for key,row in pairs(self.huds)do
  if not current(row,binding)then self.huds[key]=nil
  else
   found=true
   local widget=row.object
   -- Read only the overall native layout, never the individual HP widgets:
   -- our health HUD intentionally hides those, and PBZ also fades them idle.
   local tree=widget.WidgetTree
   if widget:IsActivated()and painted(widget)and valid(tree)and painted(tree.RootWidget)then
    self.had_hud=true;return nil
   end
  end
 end
 if found or self.had_hud then return 'native-hud-hidden'end
 -- No matching native layout yet: leave camera/loading ownership to its
 -- existing gate. Templates and HUDs from other worlds are not evidence.
 return nil
end
function M:close()
 if self.closed then return end
 self.closed=true
 if self.hook then
  UnregisterHook(movie_path,self.hook[1],self.hook[2]);self.hook=nil
 end
 self.huds={};self.movies={};self.on_change=nil
end
return M
