-- MC (x,y,z) -> PBZ (x,-z,y). All rule positions are integer PBZ cells.
local M={}
M.order={'down','up','north','south','west','east'}
M.horizontal={'north','east','south','west'}
M.vectors={east={x=1,y=0,z=0},west={x=-1,y=0,z=0},
 north={x=0,y=1,z=0},south={x=0,y=-1,z=0},up={x=0,y=0,z=1},down={x=0,y=0,z=-1}}
local opposite={east='west',west='east',north='south',south='north',up='down',down='up'}
local clockwise={north='east',east='south',south='west',west='north'}
local yaw={east=0,north=90,west=180,south=-90}
function M.valid(d) return M.vectors[d]~=nil end
function M.opposite(d) assert(opposite[d],'invalid block direction');return opposite[d] end
function M.clockwise(d) assert(clockwise[d],'horizontal direction required');return clockwise[d] end
function M.counterclockwise(d) return M.opposite(M.clockwise(d)) end
function M.rotate(d,turns)
 assert(type(turns)=='number' and turns%1==0,'integer quarter turns required')
 assert(M.valid(d),'invalid block direction')
 if d=='up' or d=='down' then return d end
 for _=1,turns%4 do d=M.clockwise(d) end
 return d
end
function M.integer(v) return type(v)=='number' and v==v and math.abs(v)<=2147483647 and v%1==0 end
function M.key(x,y,z)
 assert(M.integer(x) and M.integer(y) and M.integer(z),'integer block coordinates required')
 return tostring(math.floor(x))..':'..tostring(math.floor(y))..':'..tostring(math.floor(z))
end
function M.step(p,d,n)
 local v=assert(M.vectors[d],'invalid block direction');n=n or 1
 return {x=p.x+v.x*n,y=p.y+v.y*n,z=p.z+v.z*n}
end
function M.yaw(d) assert(yaw[d],'horizontal direction required');return yaw[d] end
function M.from_yaw(degrees)
 assert(type(degrees)=='number' and degrees==degrees and math.abs(degrees)<math.huge,'finite yaw required')
 return ({'east','north','west','south'})[(math.floor((degrees+45)/90)%4)+1]
end
function M.from_mc(x,y,z) return {x=x,y=-z,z=y} end
function M.to_mc(x,y,z) return {x=x,y=z,z=-y} end
return M
