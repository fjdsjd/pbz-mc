-- One current combat owner's immediate directional shield lease.
local identity=require('host.pbz.object_identity')
local json=require('dkjson')
local M={};M.__index=M
local prepare_error
local function bridge(value)
  assert(type(PBZMC_ShieldState)=='function','shield-native-bridge-0.11-required')
  local raw,why=PBZMC_ShieldState(json.encode(value));assert(raw,why)
  local report,pos,err=json.decode(raw);assert(report and not err and raw:sub(pos):match('^%s*$'),'shield-native-report')
  return report
end
function M.new(binding,pc)
  local self=setmetatable({binding=binding,pc=pc,lease=tostring({}),active=false},M)
  if not prepare_error then
    local ok,value=pcall(bridge,{active=false,prepare=true,lease=self.lease})
    if ok then self.report=value else prepare_error=tostring(value) end
  end
  if prepare_error then self.disabled=true;self.report={active=false,error=prepare_error} end
  local components=binding.actor:K2_GetComponentsByClass(StaticFindObject('/Script/SGameAttributes.AttributeComponent'))
  assert(#components==1,'shield-one-player-attribute-component-required')
  self.component=components[1]:get();self.component_id=identity.capture(self.component)
  self.path=assert(self.component_id.name:match('^AttributeComponent (.+)$'),'shield-component-class')
  return self
end
function M:update(state)
  if self.disabled then
    if state then state.shield_active=false;state.blocking=false end
    return
  end
  local hand=state and state.use_hand;local stack=hand and state[hand]
  local active=state and state.group=='mc' and state.shield_active and stack and stack.content_id=='pbzmc:shield'
  if not active then self:cancel();return end
  assert(self.binding:is_current() and identity.matches(self.component,self.component_id),'shield-owner-expired')
  local yaw=math.rad(self.pc.ControlRotation.Yaw)
  self.report=bridge({active=true,lease=self.lease,component=self.path,x=math.cos(yaw),y=math.sin(yaw)})
  self.active=true
end
function M:cancel()
  if self.active then self.report=bridge({active=false,lease=self.lease});self.active=false end
end
function M:close() self:cancel() end
return M
