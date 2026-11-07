-- Bedrock wolf follow_owner: start at ten blocks, stop at two; teleport is
-- recovery, never a substitute for walking. Distances use host centimetres.
local M={start=1000,stop=200,teleport=1200,combat_leash=2400,retry=1,attempts=10}
function M.goal(m,distance,target)
  if m.command_home then return distance>120,false end
  local following=m.following and distance>M.stop or distance>=M.start
  if target and distance<=M.combat_leash then return false,false end
  return following,distance>=(target and M.combat_leash or M.teleport)
end
function M.candidate(owner,serial,attempt,radius)
  local ring=math.max(300,(radius or 30)+90)+(attempt%2)*100
  local a=serial*2.3999632297287+attempt*2.3999632297287
  return {X=owner.X+math.cos(a)*ring,Y=owner.Y+math.sin(a)*ring,Z=owner.Z}
end
return M
