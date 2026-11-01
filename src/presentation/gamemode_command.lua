-- A deliberately closed command grammar; never forwarded to PBZ ExecuteConsoleCommand.
local modes=require('rules.game_mode')
local M={};M.__index=M
function M.parse(text)
 if type(text)~='string' or #text>96 then return nil,'命令过长'end
 local verb,mode=text:match('^%s*/?([a-z]+)%s+([a-z]+)%s*$')
 if verb~='gamemode' then return nil,'仅支持 /gamemode creative 或 /gamemode survival'end
 if not modes.valid(mode)then return nil,'可用模式：creative、survival'end
 return mode
end
function M.new()return setmetatable({text='/',cursor=1,revision=0},M)end
function M:suggestions()
 local head=self.text:sub(1,self.cursor)
 if head:match('^/?[a-z]*$')then
  local prefix=head:gsub('^/','')
  return ('gamemode'):sub(1,#prefix)==prefix and {'/gamemode '}or {},0
 end
 local prefix=head:match('^/?gamemode +([a-z]*)$')
 if not prefix then return {},0 end
 local result={};for _,name in ipairs(modes.names)do
  if name:sub(1,#prefix)==prefix then result[#result+1]='/gamemode '..name end
 end
 return result,#head-#prefix
end
function M:edit(text,cursor)
 self.text=text:sub(1,96);self.cursor=math.max(0,math.min(#self.text,cursor or #self.text))
 self.revision=self.revision+1;self.error=nil;self.completion=nil;self.selected_all=nil
end
function M:key(key,shift,ctrl)
 if key==27 then return 'close'end
 if key==13 then local mode,why=M.parse(self.text);if mode then return 'submit',mode end
  self.error=why;self.revision=self.revision+1;return end
 if key==9 then
  if not self.completion then local values=self:suggestions();self.completion={values=values,index=shift and #values+1 or 0}end
  local c=self.completion
  if #c.values>0 then
   if c.selection then c.selection=nil else c.index=((c.index-1+(shift and -1 or 1))%#c.values)+1 end
   self.text=c.values[c.index];self.cursor=#self.text;self.error=nil;self.revision=self.revision+1
   if self.text:sub(-1)==' 'then self.completion=nil end
  end
  return
 end
 if key==38 or key==40 then
  if not self.completion then local values=self:suggestions();self.completion={values=values,index=key==38 and 1 or 0}end
  local c=self.completion
  if #c.values>0 then c.index=((c.index-1+(key==38 and -1 or 1))%#c.values)+1;c.selection=true;self.revision=self.revision+1 end
  return
 end
 if ctrl then
  if key==65 then self.selected_all=true;self.revision=self.revision+1 end
  return -- No paste or external command/clipboard execution path.
 end
 if key==37 or key==39 or key==36 or key==35 then
  self.cursor=key==36 and 0 or key==35 and #self.text or math.max(0,math.min(#self.text,self.cursor+(key==37 and -1 or 1)))
  self.completion=nil;self.selected_all=nil;self.revision=self.revision+1;return
 end
 if key==8 or key==46 then
  if self.selected_all then self:edit('',0)
  elseif key==8 and self.cursor>0 then self:edit(self.text:sub(1,self.cursor-1)..self.text:sub(self.cursor+1),self.cursor-1)
  elseif key==46 then self:edit(self.text:sub(1,self.cursor)..self.text:sub(self.cursor+2),self.cursor)end
  return
 end
 local char=key>=65 and key<=90 and string.char(key+32)or key==32 and ' 'or (key==191 or key==111)and '/'or nil
 if not char then return end
 if self.selected_all then self:edit(char,#char)
 else self:edit(self.text:sub(1,self.cursor)..char..self.text:sub(self.cursor+1),self.cursor+#char)end
end
return M
