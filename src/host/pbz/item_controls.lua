-- One owner of the process-local item message queue. Combat ownership is an
-- explicit caller-supplied context; this adapter does not switch weapons.
local json=require('dkjson')
local bindings=require('input.item_bindings')
local M={};M.__index=M
local contexts={inactive=true,['game-pbz']=true,['game-mc']=true,inventory=true,
  ['game-pbz-hotbar']=true,['game-mc-combat']=true,['game-first-person']=true,command=true,['game-creative-pbz']=true}
function M.load_bindings(path)
  local file,why,code=io.open(path,'rb')
  if not file then assert(code==2,why);return bindings.compile() end
  local raw=file:read(65537);file:close();assert(#raw<=65536,'item-bindings-file-too-large')
  local value,next_pos,why=json.decode(raw)
  assert(value and not why and raw:sub(next_pos):match('^%s*$'),'invalid-item-bindings-json')
  return bindings.compile(value)
end
function M.new(compiled)
  assert(type(PBZMC_BeginItemInput)=='function','native-item-input-bridge-required')
  compiled=compiled or bindings.compile()
  local done,why=PBZMC_BeginItemInput(compiled.csv);assert(done,why)
  local self=setmetatable({bindings=compiled,context='inactive'},M)
  -- Begin starts inactive. Read its capability/held-key baseline before the
  -- first requested context, which may already require full MC controls.
  local ready,err=pcall(self.read,self)
  if not ready then pcall(self.close,self);error(err) end
  return self
end
function M:set_context(context)
  assert(not self.closed and contexts[context],'invalid-item-input-context')
  if self.context==context then return end
  if context=='game-pbz-hotbar' or context=='game-mc-combat' then
    assert(self.last and self.last.protocol==2 and self.last.combat_message_capture==true,
      'item-input-protocol-2-required')
  end
  if context=='game-first-person' then
    assert(self.last and self.last.first_person_controls==true,'native-first-person-input-update-required')
  end
  local done,why=PBZMC_SetItemInputContext(context);assert(done,why)
  self.context=context
end
function M:read()
  assert(not self.closed,'item-input-closed')
  local raw,why=PBZMC_ReadItemInputEvents();assert(raw,why)
  local batch=assert(json.decode(raw))
  assert(type(batch.samples)=='table' and type(batch.latest)=='table','invalid-item-input-events')
  assert(type(batch.epoch)=='number' and batch.epoch%1==0,'invalid-item-input-epoch')
  for _,pointer in ipairs(batch.samples) do assert(pointer.epoch==batch.epoch,'mixed-item-input-epochs') end
  assert(batch.latest.epoch==batch.epoch and (batch.latest.wheel_delta or 0)==0,'invalid-item-input-latest')
  self.last=batch;return batch
end
function M:close()
  if self.closed then return true end
  local done,why=PBZMC_EndItemInput();assert(done,why)
  self.closed=true;self.context='inactive';return true
end
return M
