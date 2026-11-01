-- UE4SS returns distinct Lua wrappers for the same UObject. Snapshot both the
-- native address and object name; never serialize either as a gameplay identity.
local M={}
function M.capture(object)
  assert(object and object:IsValid(),'invalid-object-identity')
  return {address=object:GetAddress(),name=object:GetFullName()}
end
function M.matches(object,identity)
  return object and identity and object:IsValid() and object:GetAddress()==identity.address
    and object:GetFullName()==identity.name or false
end
return M
