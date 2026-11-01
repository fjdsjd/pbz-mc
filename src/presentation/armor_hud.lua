-- Original MC status-bar sprites. Armor sits above every active heart row,
-- including absorption; this renders defense points, never durability.
local M={}
function M.row_top(gold,top,scale)
  local rows=math.ceil((10+math.ceil(math.max(0,gold or 0)/2))/10)
  return top-((rows-1)*math.max(10-(rows-2),3)+10)*scale
end
function M.draw(points,gold,sprites,left,top,scale)
  local result={};points=math.max(0,math.min(20,math.ceil(points or 0)))
  if points==0 then return result end
  local y=M.row_top(gold,top,scale)
  for i=0,9 do
    local key=i*2+1<points and 'armor_full' or i*2+1==points and 'armor_half' or 'armor_empty'
    result[#result+1]={texture=assert(sprites[key],'missing-original-armor:'..key),x=left+i*8*scale,y=y,w=9*scale,h=9*scale}
  end
  return result
end
return M
