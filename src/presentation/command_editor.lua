-- Pure text editing. Native key capture and command execution stay with the host.
-- Cursor/replacement offsets are zero-based UTF-8 byte boundaries.
local M={};M.__index=M
local function boundary(text,position)
 position=math.max(0,math.min(#text,math.floor(tonumber(position) or #text)))
 while position>0 and position<#text and text:byte(position+1)>=128 and text:byte(position+1)<192 do position=position-1 end
 return position
end
local function clean(value,limit)
 value=tostring(value or ''):gsub('[%z\1-\31\127]','')
 if not utf8.len(value)then value=value:gsub('[\128-\255]','?')end
 local units=0
 for start,cp in utf8.codes(value)do
  units=units+(cp>65535 and 2 or 1);if units>limit then return value:sub(1,start-1)end
 end
 return value
end
local function prev(text,cursor)return cursor==0 and 0 or (utf8.offset(text,-1,cursor+1) or 1)-1 end
local function nextpos(text,cursor)return cursor>=#text and #text or (utf8.offset(text,2,cursor+1) or #text+1)-1 end
local shifts={')','!','@','#','$','%','^','&','*','('}
local punctuation={
 [186]={';',':'},[187]={'=','+'},[188]={',','<'},[189]={'-','_'},[190]={'.','>'},
 [191]={'/','?'},[192]={'`','~'},[219]={'[','{'},[220]={'\\','|'},[221]={']','}'},[222]={"'",'"'},[226]={'\\','|'},
 [106]={'*','*'},[107]={'+','+'},[109]={'-','-'},[110]={'.','.'},[111]={'/','/'},
}
function M.character(key,shift)
 if key>=65 and key<=90 then return string.char(key+(shift and 0 or 32))end
 if key>=48 and key<=57 then return shift and shifts[key-47] or string.char(key)end
 if key>=96 and key<=105 then return string.char(key-48)end
 if key==32 then return ' 'end
 local pair=punctuation[key];return pair and pair[shift and 2 or 1] or nil
end
local modes={'impulse','repeat','chain'}
local function block_settings(block)
 local p=type(block)=='table' and (block.properties or block) or {}
 local mode=p.mode
 if mode=='repeating' or mode=='AUTO'then mode='repeat'elseif mode=='REDSTONE'then mode='impulse'elseif mode=='SEQUENCE'then mode='chain'end
 if mode~='impulse' and mode~='repeat' and mode~='chain'then
  local id=tostring(type(block)=='table' and (block.content_id or block.block_id or block.id) or '')
  mode=id:find('chain_command_block',1,true) and 'chain' or id:find('repeating_command_block',1,true) and 'repeat' or 'impulse'
 end
 return {mode=mode,auto=p.auto==true or (p.auto==nil and mode=='chain'),conditional=p.conditional==true,
  track_output=p.track_output~=false and p.TrackOutput~=false},p
end
function M.new(engine,options)
 options=options or {}
 local settings,p=block_settings(options.block)
 local self=setmetatable({engine=engine,context=options.context,block=options.block and true or false,
  block_settings=settings,previous_output=p.last_output or p.LastOutput or '',
  max_length=options.block and 32500 or 32767,history=options.history or {},revision=0,scroll=0},M)
 self:edit(options.initial~=nil and options.initial or options.block and (p.command or p.Command or '') or '/')
 return self
end
function M:changed(text_changed)
 self.revision=self.revision+1;self.suggestion_cache=nil
 if text_changed then self.error=nil;self.message=nil;self.metrics=nil;self.history_index=nil;self.history_draft=nil end
end
function M:edit(text,cursor)
 self.text=clean(text,self.max_length);self.cursor=boundary(self.text,cursor or #self.text)
 self.anchor=nil;self.selected_all=nil;self.completion=nil;self:changed(true)
end
function M:selection()
 if self.anchor and self.anchor~=self.cursor then return math.min(self.anchor,self.cursor),math.max(self.anchor,self.cursor)end
 return self.cursor,self.cursor
end
function M:set_cursor(position,shift)
 if shift then self.anchor=self.anchor or self.cursor else self.anchor=nil end
 self.cursor=boundary(self.text,position);self.selected_all=self.anchor==0 and self.cursor==#self.text or nil
 self.completion=nil;self:changed(false)
end
function M:insert(value)
 local first,last=self:selection()
 local before,after=self.text:sub(1,first),self.text:sub(last+1)
 local inserted=clean(value,self.max_length)
 -- Preserve the suffix when the field is full; reject only overflowing input.
 local function units(s)local total=0;for _,cp in utf8.codes(s)do total=total+(cp>65535 and 2 or 1)end;return total end
 inserted=clean(inserted,math.max(0,self.max_length-units(before)-units(after)))
 self:edit(before..inserted..after,#before+#inserted)
end
function M:remember()
 local value=self.text
 if value=='' or value=='/'then return end
 if self.history[#self.history]~=value then self.history[#self.history+1]=value end
 while #self.history>100 do table.remove(self.history,1)end
 self.history_index=nil;self.history_draft=nil
end
function M:history_move(step)
 if #self.history==0 then return false end
 local draft=self.history_draft or self.text
 local index=math.max(1,math.min(#self.history+1,(self.history_index or #self.history+1)+step))
 self:edit(index==#self.history+1 and draft or self.history[index])
 self.history_index=index;self.history_draft=draft;return true
end
function M:suggestions()
 local cache=self.suggestion_cache
 if cache and cache.text==self.text and cache.cursor==self.cursor then return cache.values,0,cache.entries end
 local values,entries={},{}
 if self.engine and type(self.engine.suggestions)=='function' and not self.pending then
  local ok,result,start=pcall(function()
   local context=type(self.context)=='function' and self.context() or self.context
   return self.engine:suggestions(self.text,self.cursor,context)
  end)
  if ok and type(result)=='table'then
   local list=result.suggestions or result
   for _,value in ipairs(list)do
    if #values>=2048 then break end
    local entry
    if type(value)=='string'then entry={text=clean(value,self.max_length),label=value,full=true}
    elseif type(value)=='table' and type(value.text)=='string'then
     entry={text=clean(value.text,self.max_length),label=value.label or value.text,full=value.full==true,
      start=boundary(self.text,value.start or result.start or start or 0),
      finish=boundary(self.text,value.finish or value['end'] or result.finish or self.cursor),tooltip=value.tooltip}
    end
    if entry then entries[#entries+1]=entry;values[#values+1]=tostring(entry.label)end
   end
  end
 end
 self.suggestion_cache={text=self.text,cursor=self.cursor,values=values,entries=entries}
 return values,0,entries
end
function M:begin_completion(reverse)
 local values,_,entries=self:suggestions()
 self.completion={values=values,entries=entries,index=reverse and #values+1 or 0,text=self.text,cursor=self.cursor}
 return self.completion
end
function M:choose(index)
 local c=self.completion or self:begin_completion(false)
 local entry=c.entries[index];if not entry then return false end
 local text,cursor
 if entry.full then text=entry.text;cursor=#text
 else
  text=c.text:sub(1,entry.start)..entry.text..c.text:sub(math.max(entry.start,entry.finish)+1)
  cursor=entry.start+#entry.text
 end
 self:edit(text,cursor);c.index=index;c.selection=nil;c.applied=true
 if self.text:sub(self.cursor,self.cursor)~=' ' then self.completion=c end
 return true
end
function M:visible_suggestions()
 local c=self.completion
 local values=c and c.values or self:suggestions()
 local selected=c and math.max(1,c.index) or 1
 local start=math.max(1,math.min(selected-9,#values-9))
 local out={};for index=start,math.min(#values,start+9)do out[#out+1]={text=values[index],index=index,selected=index==selected}end
 return out,start,#values
end
function M:configure(name)
 if not self.block or self.pending then return false end
 local p=self.block_settings
 if name=='mode'then for index,value in ipairs(modes)do if p.mode==value then p.mode=modes[index%#modes+1];break end end
 elseif name=='conditional' or name=='auto' or name=='track_output'then p[name]=not p[name]
 else return false end
 self.error=nil;self:changed(false);return true
end
function M:patch()
 local p=self.block_settings
 return {command=self.text,mode=p.mode,auto=p.auto,conditional=p.conditional,track_output=p.track_output}
end
function M:status(message,is_error,pending)
 self.pending=pending==true;self.message=not is_error and message or nil;self.error=is_error and message or nil
 self.completion=nil;self:changed(false)
end
function M:key(key,shift,ctrl)
 key=tonumber(key);if not key then return end
 if key==27 then return 'close'end
 if self.pending then return end
 if key==13 then
  if self.completion and self.completion.selection then self:choose(self.completion.index);return end
  return 'submit',self.text
 end
 if key==9 then
  local c=self.completion or self:begin_completion(shift)
  if #c.values>0 then
   local index=c.selection and c.index or ((c.index-1+(shift and -1 or 1))%#c.values)+1
   self:choose(index)
  end
  return
 end
 if key==38 or key==40 or key==33 or key==34 then
  local step=(key==38 or key==33)and -1 or 1
  if not self.completion and (key==38 or key==40) and self:history_move(step)then return end
  local c=self.completion or self:begin_completion(false)
  if #c.values>0 then
   local amount=(key==33 or key==34)and 10 or 1
   c.index=c.index==0 and (step<0 and #c.values or 1) or ((c.index-1+step*amount)%#c.values)+1
   c.selection=true;self:changed(false)
  end
  return
 end
 if ctrl and key==65 then self.anchor=0;self.cursor=#self.text;self.selected_all=true;self.completion=nil;self:changed(false);return end
 if key==37 or key==39 or key==36 or key==35 then
  local position=self.cursor
  if key==36 then position=0 elseif key==35 then position=#self.text
  elseif ctrl then
   if key==37 then
    while position>0 and self.text:sub(position,position):match('%s')do position=prev(self.text,position)end
    while position>0 and not self.text:sub(position,position):match('%s')do position=prev(self.text,position)end
   else
    while position<#self.text and not self.text:sub(position+1,position+1):match('%s')do position=nextpos(self.text,position)end
    while position<#self.text and self.text:sub(position+1,position+1):match('%s')do position=nextpos(self.text,position)end
   end
  else
   local first,last=self:selection()
   position=not shift and first~=last and (key==37 and first or last) or key==37 and prev(self.text,position) or nextpos(self.text,position)
  end
  self:set_cursor(position,shift);return
 end
 if ctrl then return end -- Clipboard and OS shortcuts have no native execution path here.
 if key==8 or key==46 then
  local first,last=self:selection()
  if first==last then if key==8 then first=prev(self.text,first)else last=nextpos(self.text,last)end end
  self:edit(self.text:sub(1,first)..self.text:sub(last+1),first);return
 end
 local char=M.character(key,shift);if char then self:insert(char)end
end
return M
