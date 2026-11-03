local rules=require('rules.auto_defense')
local M={}
local live,key,check_key,last_binding,last_frame
local enabled=false
local frame=0
local press={X=1,Y=0,Z=0}
local pressed_value={Value=press,ValueType=0}
local empty={}
local function valid(o)return o and o:IsValid()end
local function asset(name)
  local action=StaticFindObject('/PBZDeflectSystem/Input/'..name..'.'..name)
  assert(valid(action),'missing PBZ input '..name)
  return action
end

function M.begin_frame()
  frame=frame+1
end

local function connect(binding,pc,log)
  local component=binding.actor['Deflect Component']
  local library=StaticFindObject('/Script/Engine.Default__SubsystemBlueprintLibrary')
  local class=StaticFindObject('/Script/EnhancedInput.EnhancedInputLocalPlayerSubsystem')
  assert(valid(component) and valid(library) and valid(class),'PBZ defense component unavailable')
  local input=library:GetLocalPlayerSubSystemFromPlayerController(pc,class)
  local inject=StaticFindObject('/Script/EnhancedInput.EnhancedInputSubsystemInterface:InjectInputVectorForAction')
  assert(valid(input) and valid(inject),'PBZ defense input unavailable')
  local s={binding=binding,pc=pc,component=component,input=input,inject=inject,
    frames=component.ReceiveFrames,stance=asset('IA_Stance'),guard=asset('IA_Deflect'),dodge=asset('IA_Dodge'),queue=rules.new(),
    observed={},log=log,senders=require('host.pbz.defense_senders').new(binding.actor),
    projectiles=require('host.pbz.defense_projectiles').new(binding.actor)}
  -- The header is an inline reflected property of this component. The engine
  -- may resize its contents; no key, entry or iterator escapes this callback.
  s.visit=function(k,v)
    local row=v:get()
    local h=k:get()
    local seen=s.observed[h]
    if not seen or seen.stamp~=row.HitGameTime then
      seen={stamp=row.HitGameTime};s.observed[h]=seen
      if s.senders then s.senders:incoming(row.SourceAction:Get(),s.now)end
      if s.projectiles then s.projectiles:add(row.Bullet,s.now,true) end
    end
    seen.frame=frame
    rules.consider(s.queue,h,row.HitGameTime,row.IsDodge,row.IsHit)
  end
  return s
end

-- Same discrete action callback that Enhanced Input normally delivers on
-- the following tick. Use it only for real contact frames on the local pawn.
local function contact_press(s)
  if not s.contact_checked then
    s.contact_checked=true
    local path='/PBZDeflectSystem/Abilities/BP_PlayerDeflectPassive.BP_PlayerDeflectPassive_C:InpActEvt_IA_Deflect_K2Node_EnhancedInputActionEvent_0'
    s.contact_input=StaticFindObject(path)
    if valid(s.contact_input) and type(FindAllOf)=='function'then
      for _,a in ipairs(FindAllOf('BP_PlayerDeflectPassive_C')or{})do
        if valid(a)and valid(a:GetOuter())and a:GetOuter():GetAddress()==s.binding.actor:GetAddress()then s.passive=a;break end
      end
    end
  end
  if valid(s.passive) then
    local ok=pcall(s.contact_input,s.passive,pressed_value,0,0,s.guard)
    if ok then return true end
    s.passive=nil
  end
end

local function step(binding,pc,now,log)
  if not live or live.binding~=binding or not valid(live.pc) or live.pc:GetAddress()~=pc:GetAddress()
    or not valid(live.component) or not valid(live.input) then live=connect(binding,pc,log)end
  local s=live
  local delta=s.now and now-s.now or 1/60
  s.frame=frame;s.now=now
  local frames=s.frames
  rules.begin(s.queue,now,delta)
  if #frames>0 then frames:ForEach(s.visit) end
  for h,v in pairs(s.observed)do if v.frame~=frame then s.observed[h]=nil end end
  if s.senders then s.senders:consider(s.queue,now) end
  local hit=rules.choose(s.queue)
  local eta=s.projectiles and s.projectiles:incoming(now,s.queue.lead)
  if eta then s.brace=math.max(s.brace or now,now+eta+.055) end
  local previous=s.last_action
  s.last_action=nil
  if hit and hit.action=='dodge' then s.brace=nil end
  if (hit and hit.action=='guard')or (s.brace and now<=s.brace) then s.inject(s.input,s.stance,press,empty,empty) end
  if not hit then return end
  if hit.contact and hit.action=='guard' and contact_press(s) then
    rules.dispatched(s.queue,hit);return
  end
  if hit.action==previous then return end
  rules.dispatched(s.queue,hit)
  s.last_action=hit.action
  s.inject(s.input,s[hit.action],press,empty,empty)
end

function M.spawned(actor)
  if live and live.frame==frame and live.projectiles then live.projectiles:add(actor,live.now,false) end
end

function M.update(binding,pc,accept,combat,now,notify,log,key_ok)
  if not accept then M.suspend();return end
  if not key then
    key={KeyName=FName('F6')}
    check_key=StaticFindObject('/Script/Engine.PlayerController:WasInputKeyJustPressed')
  end
  -- Read the engine's physical edge on the game thread. Menus, changes of
  -- controller and focus gaps must not replay a previous press.
  local continuous=last_binding==binding and last_frame==frame-1
  last_binding=binding;last_frame=frame
  if key_ok==false then last_binding=nil;last_frame=nil end
  if key_ok~=false and continuous and valid(check_key) and check_key(pc,key) then
    enabled=not enabled
    pcall(notify,enabled and 'PBZ 自动防御已开启' or 'PBZ 自动防御已关闭')
    log('PBZ auto defense '..(enabled and 'on' or 'off'))
  end
  if not enabled or not combat or (live and (live.binding~=binding or live.frame~=frame-1))then live=nil end
  if not enabled or not combat then return end
  local ok,err=pcall(step,binding,pc,now,log)
  if not ok then
    live=nil;enabled=false
    log('PBZ auto defense unavailable: '..tostring(err))
    pcall(notify,'PBZ 自动防御不可用')
  end
end

function M.suspend()live=nil;last_binding=nil;last_frame=nil end
return M
