-- User-selected hybrid controls: sword/bow attacks interrupt held offhand defence.
local actions=require('content.item_actions')
local M={}
function M.weapon(main,offhand)
  if not offhand or offhand.content_id~='pbzmc:shield' then return end
  local category=actions.get(main and main.content_id)
  if category.combat.kind=='sword' then return 'sword' end
  if category.use=='bow' then return 'bow' end
end
return M
