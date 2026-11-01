-- One in-flight native weapon request for one local-player binding.
-- The caller still owns MC input/pose handoff and inventory commit. A ready
-- result here observes native equipment only; it never commits a UI selection.
local identity=require('host.pbz.object_identity')
local references=require('rules.native_slot_reference')
local Equipment=require('host.pbz.native_equipment')
local Vitals=require('host.pbz.player_vitals')
local Dispatch=require('host.pbz.native_input_dispatch')
local M={};M.__index=M
local MAIN='Weapon.Slot.Main'
local SHACHI='Weapon.Slot.Shachi'
local categories={main={tag=MAIN,declared='main_weapons',action='next_main'},
  shaqi={tag=SHACHI,declared='shaqi_weapons',action='next_shaqi'}}
local function finite(value) return type(value)=='number' and value==value and math.abs(value)<math.huge end
local function integer(value) return finite(value) and value>=0 and value%1==0 and value<2^53 end
local function copy(value)
  if type(value)~='table' then return value end
  local result={};for key,child in pairs(value) do result[key]=copy(child) end;return result
end

function M.new(binding,controller,epoch,context)
  local ok,self=pcall(function()
    assert(integer(epoch) and type(context)=='function','native-request-context-required')
    local equipment,why=Equipment.new(binding,controller,epoch);assert(equipment,why)
    local vitals;vitals,why=Vitals.new(binding,controller,epoch);assert(vitals,why)
    return setmetatable({binding=binding,controller=controller,controller_id=identity.capture(controller),
      epoch=epoch,context=context,equipment=equipment,vitals=vitals,serial=0},M)
  end)
  if ok then return self end
  return nil,tostring(self)
end

function M:check(input_epoch,allow_native_busy)
  assert(type(IsInGameThread)=='function' and IsInGameThread(),'native-request-game-thread-required')
  assert(not self.closed and self.binding and not self.binding.closed and not self.binding.closing
    and not self.binding.creation_failure and self.binding:is_current(),'native-request-binding-unavailable')
  assert(identity.matches(self.controller,self.controller_id)
    and identity.matches(self.controller.Pawn,self.binding.actor_id)
    and identity.matches(self.controller:GetWorld(),self.binding.world_id),'native-request-player-changed')
  local context=self.context()
  assert(type(context)=='table' and context.kind=='game' and integer(input_epoch)
    and context.epoch==input_epoch and (context.weapon_group=='pbz' or context.weapon_group=='mc'),
    'native-request-input-context-changed')
  local gameplay=StaticFindObject('/Script/Engine.Default__GameplayStatics')
  assert(gameplay and gameplay:IsValid() and not gameplay:IsGamePaused(self.controller)
    and self.controller.bShowMouseCursor==false,'native-request-gameplay-unavailable')
  if not allow_native_busy then
    assert(not self.controller:IsLookInputIgnored() and not self.controller:IsMoveInputIgnored(),
      'native-request-native-control-ignored')
  end
  -- context.kind must also be invalidated by the caller on a cinematic that
  -- leaves normal controller flags enabled; these flags alone cannot prove it.
  return context
end

function M:observe(input_epoch,category)
  category=category or 'main'
  local specification=assert(categories[category],'native-request-category-not-supported')
  self:check(input_epoch,true)
  local declared,why=self.equipment:read(self.epoch);assert(declared,why)
  local runtime;runtime,why=self.equipment:read_runtime(self.epoch,{selection=true});assert(runtime,why)
  assert(runtime.source=='pbz-character-weapons-v2' and runtime.epoch==self.epoch,
    'native-request-selection-state-unavailable')
  local main=runtime.slots[MAIN]
  assert(main and type(main.armed)=='boolean' and type(runtime.in_weapon_transition)=='boolean'
    and runtime.transition_scope=='synchronous-weapon-mutation','native-request-selection-state-unavailable')
  local slot=runtime.slots[specification.tag];local values=declared[specification.declared]
  assert(type(values)=='table','native-request-declared-category-unavailable')
  -- Shachi need not exist before it is unlocked. Do not manufacture a runtime
  -- slot, or let its unrelated transient count block selection of Main.
  assert(slot and integer(slot.count) and slot.count==#values
    and (slot.current_in_range or (slot.count==0 and (category~='main' or not main.armed)))
    or category=='shaqi' and not slot and #values==0,'native-request-inconsistent-'..category..'-state')
  local vitals;vitals,why=self.vitals:read(self.epoch);assert(vitals,why)
  assert(vitals.health_authoritative and vitals.hp>0,'native-request-player-not-alive')
  self:check(input_epoch,true)
  return {declared=declared,runtime=runtime,main=main,shaqi=runtime.slots[SHACHI],slot=slot,category=category}
end

local function result(request,phase,reason,observed)
  return {request_id=request.id,phase=phase,reason=reason,action=request.action,
    any_action_attempted=request.attempted==true,any_dispatch_returned=request.dispatch_returned==true,
    current_action_attempted=request.current_attempted==true,current_action_dispatch_returned=request.current_returned==true,
    requested_index=request.index,requested_armed=request.armed,requested_category=request.category or 'main',
    native_state_observed=phase=='ready',changed=request.changed==true,
    ui_committed=false,combat_commit_verified=false,observed=observed and copy(observed.runtime) or nil}
end

function M:send(request,action)
  assert(self.pending==request and not self.dispatching,'native-request-not-current')
  local function check_dispatch()
    local context=self:check(request.input_epoch,true)
    -- Original combat can lock move/look during a combo while still accepting
    -- its own weapon input buffer. Cross-group MC requests keep the idle gate.
    self:check(request.input_epoch,context.weapon_group=='pbz')
  end
  check_dispatch()
  request.action=action;request.stage=action;request.current_attempted=false;request.current_returned=false
  request.rejected=nil;self.dispatching=true
  local ok,dispatch=pcall(Dispatch.request,self.controller,action,function()
    assert(self.pending==request and self.dispatching,'native-request-superseded')
    check_dispatch()
  end)
  self.dispatching=false
  -- Dispatch normally catches its own failures. If its boundary unexpectedly
  -- throws, treat the outcome as attempted: it may have executed native code.
  if not ok then
    request.attempted=true;request.current_attempted=true;request.uncertain=tostring(dispatch)
  else
    request.current_attempted=dispatch.attempted==true
    request.current_returned=dispatch.dispatch_returned==true
    request.attempted=request.attempted or dispatch.attempted
    request.dispatch_returned=request.dispatch_returned or dispatch.dispatch_returned
    request.uncertain=dispatch.status=='dispatch_uncertain' and dispatch.error or nil
    if not dispatch.attempted then request.rejected=dispatch.error or 'native-request-preflight-rejected' end
  end
end

-- Exactly one user intent is accepted until its result is observed or the
-- binding is retired. No timer expiration can authorize replaying a request.
function M:start(reference,armed,input_epoch,now)
  if self.pending or self.dispatching then return nil,'native-request-already-pending' end
  local request
  local ok,value=pcall(function()
    assert(finite(now) and (type(armed)=='boolean' or reference and armed==nil),'native-request-invalid-intent')
    -- Observing an already-current slot does not dispatch an action. Actual
    -- draw/stow/switch still checks native control gates in send().
    self:check(input_epoch,true)
    if reference then references.validate(reference) end
    local category=reference and reference.metadata.category or 'main'
    local specification=assert(categories[category],'native-request-category-not-supported')
    local observed=self:observe(input_epoch,category)
    local slot=observed.slot;local values=observed.declared[specification.declared]
    -- Shaqi selection owns its index only, never the Main draw/stow stage.
    if category=='shaqi' then armed=nil end
    if not reference and not armed and observed.main.count==0 then
      assert(not observed.runtime.in_weapon_transition and not observed.main.with_pending_differs,
        'native-request-transition-in-progress')
      self.serial=self.serial+1
      return result({id=self.serial,index=observed.main.current_index,armed=false},
        'ready','no-native-main-weapon',observed)
    end
    local target
    if reference then
      local why;target,why=references.resolve(reference,observed.declared,self.epoch);assert(target,why)
    else
      local index=observed.main.current_index
      target={native_slot_index=index,equipment_id=observed.declared.main_weapons[index+1]}
      assert(type(target.equipment_id)=='string' and target.equipment_id~='' and target.equipment_id:lower()~='none',
        'native-request-current-equipment-unavailable')
    end
    assert(slot and target.native_slot_index<slot.count,'native-request-target-outside-runtime')
    self.serial=self.serial+1
    request={id=self.serial,index=target.native_slot_index,equipment_id=target.equipment_id,armed=armed,
      category=category,input_epoch=input_epoch,started=now,before_index=slot.current_index,
      before_armed=observed.main.armed,attempted=false}
    self.pending=request
    assert(not observed.runtime.in_weapon_transition and not slot.with_pending_differs,
      'native-request-transition-in-progress')
    if slot.current_index~=request.index then
      local alternatives,only=0,nil
      for i,id in ipairs(values) do
        if i-1~=slot.current_index and id~='' and id:lower()~='none' then
          alternatives=alternatives+1;only=i-1
        end
      end
      -- Native change actions have no requested-index argument. Their ability
      -- chooses a matching candidate, not a cycle order; ambiguity must fail.
      assert(alternatives==1 and only==request.index,'native-request-direct-target-unavailable')
      self:send(request,specification.action)
    elseif armed~=nil and observed.main.armed~=armed then self:send(request,'change_armed')
    else
      self.pending=nil
      return result(request,'ready','already-current-no-action',observed)
    end
    if request.rejected then
      self.pending=nil;return result(request,'rejected',request.rejected,observed)
    end
    return result(request,request.uncertain and 'uncertain' or 'pending',request.uncertain,observed)
  end)
  if ok then return value end
  if request and request.attempted then
    request.uncertain=tostring(value);return result(request,'uncertain',request.uncertain)
  end
  self.pending=nil
  return nil,tostring(value)
end

function M:select(reference,input_epoch,now)
  assert(reference,'native-request-slot-reference-required')
  return self:start(reference,true,input_epoch,now)
end
function M:stow(input_epoch,now) return self:start(nil,false,input_epoch,now) end

function M:poll(now,allow_actions)
  local request=self.pending
  if not request then return nil,'native-request-none' end
  if self.dispatching then return result(request,'pending','native-request-dispatch-in-progress') end
  local ok,value=pcall(function()
    assert(finite(now) and now>=request.started,'native-request-clock-regressed')
    local category=request.category or 'main';local specification=categories[category]
    local observed=self:observe(request.input_epoch,category)
    assert(observed.declared[specification.declared][request.index+1]==request.equipment_id,'native-request-equipment-replaced')
    local main=assert(observed.slot,'native-request-runtime-slot-unavailable')
    request.changed=main.current_index~=request.before_index or category=='main' and main.armed~=request.before_armed
    -- This counter observes synchronous mutation/reentry only. It cannot prove
    -- animation, ability or queued-input completion; the handoff caller must
    -- independently establish those before activating MC combat or a UI commit.
    local indices_agree=not observed.runtime.in_weapon_transition and not main.with_pending_differs
    if indices_agree and main.current_index==request.index then
      -- Mixed-hotbar selection accepts the native ability's armed/combo stage.
      if request.armed==nil or main.armed==request.armed then
        self.pending=nil;return result(request,'ready','native-state-observed',observed)
      end
      if request.stage=='next_main' and not request.uncertain and allow_actions~=false then
        -- A successful index switch may still need one distinct draw/stow
        -- action. This is a second stage, never a retry of the first action.
        self:send(request,'change_armed')
        if request.rejected then request.uncertain=request.rejected end
      end
    end
    if request.stage=='change_armed' and not request.uncertain and indices_agree
        and main.current_index==request.index and now-request.started>=.5 then
      local idle=Dispatch.nonbuffered_idle(self.controller,'change_armed',function()
        self:check(request.input_epoch,false);return true
      end)
      if idle then
        request.idle_since=request.idle_since or now
        if now-request.idle_since>=.25 then
          self.pending=nil
          return result(request,'rejected','native-nonbuffered-action-ended-without-target-state',observed)
        end
      else request.idle_since=nil end
    else request.idle_since=nil end
    -- Five seconds is a diagnostic deadline, not proof that PBZ's input buffer
    -- expired or a license to retry. Keep observing this same request afterward.
    return result(request,(request.uncertain or now-request.started>=5) and 'uncertain' or 'pending',
      request.uncertain or (now-request.started>=5 and 'native-request-outcome-unconfirmed' or nil),observed)
  end)
  if ok then return value end
  request.uncertain=tostring(value)
  return result(request,'uncertain',request.uncertain)
end

function M:close()
  local unresolved=self.pending and result(self.pending,'uncertain','native-request-binding-retired') or nil
  self.closed=true;self.pending=nil
  if self.equipment then self.equipment:close() end
  self.equipment=nil;self.vitals=nil;self.binding=nil;self.controller=nil;self.context=nil
  return unresolved -- Retirement never attempts to undo/replay an old-world action.
end
return M
