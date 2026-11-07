-- Per-capsule movement exclusions, owned only for the duration of a glide.
-- Physical geometry on the same actor is still collidable.
local ids=require('host.pbz.object_identity')
local valid=require('host.pbz.appearance').valid
local M={};M.__index=M
function M.new(binding)
  local cap=binding.actor.CapsuleComponent
  return setmetatable({cap=cap,id=ids.capture(cap),policy=require('host.pbz.pearl_collision').new(binding),added={},count=0},M)
end
function M:ignore(hit)
  local ok,c=pcall(function()return hit.Component:Get()end)
  if not ok or not valid(c) or not self.policy:air_wall(c,c:GetOwner()) then return false end
  local key=c:GetAddress()
  if self.added[key] or self.count>=64 or not ids.matches(self.cap,self.id) then return false end
  local prior=false
  for _,entry in ipairs(self.cap:CopyArrayOfMoveIgnoreComponents()) do
    local other=entry.GetFullName and entry or entry:get()
    if valid(other) and other:GetAddress()==key then prior=true;break end
  end
  if prior then return false end
  self.cap:IgnoreComponentWhenMoving(c,true)
  self.added[key]={component=c,id=ids.capture(c)};self.count=self.count+1
  return true
end
function M:close()
  if ids.matches(self.cap,self.id) then
    for _,row in pairs(self.added) do
      if ids.matches(row.component,row.id) then self.cap:IgnoreComponentWhenMoving(row.component,false) end
    end
  end
  self.added={};self.count=0
end
return M
