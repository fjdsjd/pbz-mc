-- Interprets one already-drained native message batch. Never reads the native
-- queue a second time and never emits gameplay directly. The coordinator must
-- merge by seq with hotbar intents and recheck the equipment revision per intent.
local M={};M.__index=M
local function integer(value,maximum)
  return type(value)=='number' and value%1==0 and value>=0 and value<=maximum
end
local function down(value,index) return (value&(1<<index))~=0 end
function M.new() return setmetatable({armed=false,buttons=0,last_seq=-1},M) end
function M:cancel(reason,output)
  output=output or {}
  -- A released button can still have a running swing/use action. Retire the
  -- source once even when no physical button remains down.
  if self.stamp then
    output[#output+1]={kind='cancel_actions',reason=reason,source=self.stamp}
  end
  self.armed=false;self.buttons=0;self.last_seq=-1;self.stamp=nil
  self.guard=nil;self.owner_epoch=nil;self.input_epoch=nil
  return output
end
function M:update(batch,context)
  local output={}
  if type(batch)~='table' or type(context)~='table' then return self:cancel('invalid-batch',output) end
  local valid=batch.protocol==2 and batch.combat_message_capture==true
    and (batch.context=='game-mc-combat' or batch.context=='game-first-person')
    and not batch.overflow and not batch.timed_out_since_read and not batch.heartbeat_expired and not batch.identity_lost
    and context.kind=='game' and context.weapon_group=='mc' and context.allow_actions==true
  if not valid then return self:cancel('context-unavailable',output) end
  if not (integer(batch.epoch,2^53-1) and integer(context.epoch,2^53-1)
    and integer(context.equipment_revision,2^53-1) and type(batch.samples)=='table' and type(batch.latest)=='table') then
    return self:cancel('invalid-batch',output)
  end
  local function valid_sample(pointer)
    return type(pointer)=='table' and pointer.epoch==batch.epoch and integer(pointer.seq,2^53-1)
      and type(pointer.focused)=='boolean' and integer(pointer.buttons or 0,7)
      and integer(pointer.keys or 0,4194303) and integer(pointer.time_ms,2^53-1)
  end
  local previous_seq=-1
  for _,pointer in ipairs(batch.samples) do
    if not valid_sample(pointer) or pointer.seq<=previous_seq then return self:cancel('invalid-samples',output) end
    if not pointer.focused then return self:cancel('focus-lost',output) end
    previous_seq=pointer.seq
  end
  if not valid_sample(batch.latest) or batch.latest.seq<previous_seq then return self:cancel('invalid-latest',output) end
  if not batch.latest.focused then return self:cancel('focus-lost',output) end
  local stamp=tostring(context.epoch)..'/'..tostring(context.equipment_revision)..'/'..tostring(batch.epoch)
  if self.stamp~=stamp then
    local guard=require('rules.shield_combat').weapon(context.main,context.offhand)~=nil
    local carry_guard=self.guard and guard and self.armed and self.buttons==2 and (batch.latest.buttons or 0)==2
      and self.owner_epoch==context.epoch and self.input_epoch==batch.epoch and not batch.draining_owned_releases
    self:cancel('owner-or-equipment-changed',output);self.stamp=stamp
    self.guard=guard;self.owner_epoch=context.epoch;self.input_epoch=batch.epoch
    -- An equipment change may occur without a native context/epoch change.
    -- Baseline at the batch end so old queued clicks cannot arm the new item.
    self.last_seq=batch.latest.seq
    self.armed=batch.latest.focused and (batch.latest.buttons or 0)==0 and ((batch.latest.keys or 0)&8191)==0
      and not batch.draining_owned_releases
    if carry_guard then
      -- Sword <-> bow selection can carry only held defence. It never carries
      -- a left-button attack/charge, nor an inventory/native/focus transition.
      self.armed=true;self.buttons=2
      output[#output+1]={kind='use_press',seq=batch.latest.seq,time_ms=batch.latest.time_ms,input_epoch=batch.epoch,
        owner_epoch=context.epoch,equipment_revision=context.equipment_revision,source=stamp,inherited_guard=true}
    end
    return output
  end
  local function sample(pointer)
    if pointer.seq<=self.last_seq then return end
    self.last_seq=pointer.seq
    local buttons=pointer.buttons or 0
    if not self.armed then
      if buttons==0 and ((pointer.keys or 0)&8191)==0 and not batch.draining_owned_releases then self.armed=true end
      return
    end
    for index,action in ipairs({'attack','use'}) do
      local was,is=down(self.buttons,index-1),down(buttons,index-1)
      if was~=is then output[#output+1]={kind=action..(is and '_press' or '_release'),
        seq=pointer.seq,time_ms=pointer.time_ms,input_epoch=batch.epoch,owner_epoch=context.epoch,
        equipment_revision=context.equipment_revision,source=stamp} end
    end
    self.buttons=buttons&3
  end
  for _,pointer in ipairs(batch.samples) do sample(pointer) end
  sample(batch.latest)
  return output
end
function M:state()
  return {armed=self.armed,attack_down=down(self.buttons,0),use_down=down(self.buttons,1),source=self.stamp,last_seq=self.last_seq}
end
return M
