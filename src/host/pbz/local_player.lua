-- Resolve player zero in the current game instance. The bundled UEHelpers
-- GetPlayerController enumerates every loaded controller on each call.
local UE=require('UEHelpers')
local M={}
local gameplay
function M.controller()
  local instance=UE.GetGameInstance()
  if not instance or not instance:IsValid() then return instance end
  if not gameplay or not gameplay:IsValid() then
    gameplay=StaticFindObject('/Script/Engine.Default__GameplayStatics')
  end
  return gameplay:GetPlayerController(instance,0)
end
function M.pawn()
  local pc=M.controller()
  return pc and pc:IsValid() and pc.Pawn or nil
end
return M
