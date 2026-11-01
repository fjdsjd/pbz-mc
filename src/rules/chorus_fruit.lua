-- Deterministic chorus-fruit escape search. Host callbacks only return numeric
-- surfaces and capsule-clear results; this module never moves an actor.
local M={id='pbzmc:chorus_fruit',cooldown_ticks=20,cooldown_seconds=1,use_seconds=1.6,
  consume=false,normal_z=.97,flat_tolerance=6,clear_queries=2,max_random_attempts=16,max_random_draws=64}
local EPS=1e-7
-- Geometry is relative to the origin and immutable after construction. Keep
-- the sorted samples across meals; jobs only advance their own point_index.
local point_cache={}
local function finite(n)return type(n)=='number' and n==n and math.abs(n)<math.huge end
local function number(n,min,max,label)
  assert(finite(n) and n>=min and n<=max,'invalid-chorus-'..label);return n
end
local function integer(n,min,max,label)
  number(n,min,max,label);assert(n%1==0,'invalid-chorus-'..label);return n
end
local function position(p)
  assert(type(p)=='table','invalid-chorus-origin')
  for _,axis in ipairs({'x','y','z'})do number(p[axis],-1e9,1e9,'origin-'..axis)end
  return {x=p.x,y=p.y,z=p.z}
end
local function report(job)
  local next_point=job.points[job.point_index]
  local result={mode=job.mode,attempts=job.attempts,random_draws=job.random_draws,
    reason=job.reason,queries=job.queries,steps=job.steps,columns=job.columns,
    candidates=job.candidates,rejected_support=job.rejected_support,rejected_occupied=job.rejected_occupied,
    sample_count=#job.points,queries_this_step=job.last_queries or 0,candidates_this_step=job.last_candidates or 0,
    nearest_verified=job.mode=='nearest' and job.status=='found',horizontal_limit=job.horizontal_limit,vertical_limit=job.vertical_limit,
    grid_step=job.mode=='nearest' and 100 or nil,near_step=job.mode=='nearest' and 50 or nil,near_limit=job.near_limit,
    next_horizontal_lower_bound=job.mode=='nearest' and next_point and math.sqrt(next_point.d2)or nil}
  if job.best then
    result.best_distance=math.sqrt(job.best.score);result.ground_z=job.best.ground_z
    result.support=job.best.support;result.radius=job.radius;result.half_height=job.half_height
  end
  return result
end
local function result(job)return {status=job.status,position=job.status=='found' and job.best.position or nil,report=report(job)}end
local function finish(job,status,reason)
  job.status=status;job.reason=reason;job.column=nil;job.candidate=nil;job.surfaces=nil
end
local function points(limit,near_limit)
  local by_near=point_cache[limit]
  if by_near and by_near[near_limit]then return by_near[near_limit]end
  local output,seen={},{}
  local function add_grid(step,range)
    local n=math.floor(range/step)
    for y=-n,n do for x=-n,n do
      local dx,dy=x*step,y*step;local d2=dx*dx+dy*dy
      if d2<=range*range+EPS then
        local key=dx..'/'..dy
        if not seen[key]then seen[key]=true;output[#output+1]={x=dx,y=dy,d2=d2}end
      end
    end end
  end
  add_grid(100,limit);add_grid(50,near_limit)
  table.sort(output,function(a,b)
    if a.d2~=b.d2 then return a.d2<b.d2 end
    if a.y~=b.y then return a.y<b.y end
    return a.x<b.x
  end)
  if not by_near then by_near={};point_cache[limit]=by_near end
  by_near[near_limit]=output
  return output
end
local function random_points(limit,vertical,random)
  local output={};local draws=0;local span=math.min(800,limit)
  local function unit()
    local value=random();assert(finite(value) and value>=0 and value<1,'invalid-chorus-random');return value
  end
  while #output<M.max_random_attempts and draws<M.max_random_draws do
    draws=draws+1
    local x,y=(unit()*2-1)*span,(unit()*2-1)*span
    local z=math.max(-vertical,math.min(vertical,(math.floor(unit()*16)-8)*100))
    local d2=x*x+y*y
    if d2>=100^2 and d2<=limit*limit then output[#output+1]={x=x,y=y,z=z,d2=d2}end
  end
  return output,draws
end
function M.new(options)
  assert(type(options)=='table','invalid-chorus-options')
  local origin=position(options.origin)
  local radius=number(options.radius,1,500,'radius')
  local half=number(options.half_height,radius,1000,'half-height')
  local horizontal=number(options.horizontal_limit or 1600,0,1600,'horizontal-limit')
  local vertical=number(options.vertical_limit or 800,1,800,'vertical-limit')
  local mode=options.mode or 'nearest'
  assert(mode=='nearest' or mode=='random','invalid-chorus-mode')
  local near=math.min(horizontal,200)
  local samples,draws
  if mode=='random'then
    local random=options.random or math.random;assert(type(random)=='function','invalid-chorus-random-source')
    samples,draws=random_points(horizontal,vertical,random)
  else samples=points(horizontal,near)end
  return {status='searching',mode=mode,attempts=0,random_draws=draws,origin=origin,radius=radius,half_height=half,
    clearance=number(options.clearance or 3,0,20,'clearance'),horizontal_limit=horizontal,vertical_limit=vertical,
    queries_per_step=integer(options.queries_per_step or 24,2,128,'frame-query-budget'),
    candidates_per_step=integer(options.candidates_per_step or 4,1,16,'frame-candidate-budget'),
    max_queries=integer(options.max_queries or 4096,2,4096,'total-query-budget'),
    near_limit=mode=='nearest' and near or nil,points=samples,point_index=1,phase='column',queries=0,steps=0,
    columns=0,candidates=0,rejected_support=0,rejected_occupied=0}
end
local function new_column(x,y,top,bottom)return {x=x,y=y,top=top,bottom=bottom,surfaces={}}end
local function valid_surface(surface,top,bottom)
  return type(surface)=='table' and finite(surface.z) and surface.z<=top+EPS and surface.z>=bottom-EPS
    and surface.kind=='static' and finite(surface.normal_z) and surface.normal_z>=M.normal_z
    and surface.normal_z<=1+EPS
end
local function scan(job,host,column,budget)
  local ok,value=pcall(host.column,column.x,column.y,column.top,column.bottom,budget,column.cursor)
  if not ok then finish(job,'none','column-error:'..tostring(value));return false end
  if type(value)~='table' or not finite(value.cost) or value.cost%1~=0 or value.cost<1 or value.cost>budget
      or type(value.complete)~='boolean' or type(value.surfaces)~='table' or #value.surfaces>value.cost then
    finish(job,'none','invalid-column-result');return false
  end
  job.queries=job.queries+value.cost;job.last_queries=job.last_queries+value.cost
  for _,surface in ipairs(value.surfaces)do
    if valid_surface(surface,column.top,column.bottom)then
      local duplicate=false
      for _,old in ipairs(column.surfaces)do if math.abs(old.z-surface.z)<EPS then duplicate=true;break end end
      if not duplicate then column.surfaces[#column.surfaces+1]={z=surface.z,normal_z=surface.normal_z,kind='static'}end
    end
  end
  if value.complete then column.complete=true;return true end
  local previous=column.cursor or column.top
  if not finite(value.cursor) or value.cursor>=previous-EPS or value.cursor<column.bottom-EPS then
    finish(job,'none','nonprogressing-column');return false
  end
  column.cursor=value.cursor
  return true
end
local function flat_support(candidate)
  local ground=candidate.ground_z;local lows={ground-M.flat_tolerance,ground}
  for _,column in ipairs(candidate.support_columns)do
    for _,surface in ipairs(column.surfaces)do
      local low=surface.z-M.flat_tolerance
      if low>=ground-M.flat_tolerance-EPS and low<=ground+EPS then lows[#lows+1]=low end
    end
  end
  table.sort(lows)
  -- An interval's lower bound is one of these surface-minus-tolerance values.
  -- Trying all of them avoids rejecting valid layers through greedy choices.
  for _,low in ipairs(lows)do
    local chosen={{x=candidate.position.x,y=candidate.position.y,z=ground,normal_z=candidate.normal_z}}
    for _,column in ipairs(candidate.support_columns)do
      local best
      for _,surface in ipairs(column.surfaces)do
        if surface.z>=low-EPS and surface.z<=low+M.flat_tolerance+EPS
          and (not best or math.abs(surface.z-ground)<math.abs(best.z-ground))then best=surface end
      end
      if not best then chosen=nil;break end
      chosen[#chosen+1]={x=column.x,y=column.y,z=best.z,normal_z=best.normal_z}
    end
    if chosen then return chosen end
  end
end
local function budget(job)
  return math.min(job.queries_per_step-job.last_queries,job.max_queries-job.queries)
end
local function need_query(job,min)
  if job.max_queries-job.queries<min then finish(job,'none','budget');return false end
  return job.queries_per_step-job.last_queries>=min
end
function M.advance(job,host)
  if job.status~='searching'then return result(job)end
  assert(type(host)=='table' and type(host.column)=='function' and type(host.clear)=='function'
    and (host.should_yield==nil or type(host.should_yield)=='function'),'invalid-chorus-host')
  job.steps=job.steps+1;job.last_queries=0;job.last_candidates=job.candidate and 1 or 0
  while job.status=='searching'do
    -- A busy frame may yield between host operations, but never before making
    -- at least one query. The host's clock check itself consumes no trace.
    if job.last_queries>0 and host.should_yield and host.should_yield()==true then break end
    if job.phase=='column'then
      local point=job.points[job.point_index]
      if not point then finish(job,job.best and 'found'or 'none',job.best and 'nearest-sampled'or 'no-safe-ground');break end
      if job.mode=='nearest' and job.best and point.d2>job.best.score+EPS then finish(job,'found','nearest-sampled');break end
      if not job.column then
        local top=job.origin.z+job.vertical_limit
        local bottom=job.origin.z-job.vertical_limit-job.half_height-job.clearance
        if job.mode=='random'then top=math.min(top,job.origin.z+point.z)
        elseif job.best then
          -- The horizontal distance already consumes part of the best total
          -- distance. Only this remaining vertical band can improve it.
          -- Set bounds once: an in-progress column keeps its original cursor.
          local span=math.min(job.vertical_limit,math.sqrt(math.max(0,job.best.score-point.d2)))
          local feet=job.origin.z-job.half_height-job.clearance
          top=math.min(top,feet+span+2);bottom=math.max(bottom,feet-span)
        end
        job.column=new_column(job.origin.x+point.x,job.origin.y+point.y,top,bottom)
        job.attempts=job.attempts+1
      end
      if not need_query(job,1)then break end
      if not scan(job,host,job.column,budget(job))then break end
      if job.column.complete then
        local surfaces={}
        for _,surface in ipairs(job.column.surfaces)do
          local z=surface.z+job.half_height+job.clearance;local dz=z-job.origin.z
          if math.abs(dz)<=job.vertical_limit+EPS then
            surfaces[#surfaces+1]={z=z,ground_z=surface.z,normal_z=surface.normal_z,score=point.d2+dz*dz}
          end
        end
        table.sort(surfaces,function(a,b)
          if job.mode=='nearest' and a.score~=b.score then return a.score<b.score end
          return a.z>b.z
        end)
        job.surfaces=surfaces;job.surface_index=1;job.columns=job.columns+1;job.phase='candidate'
      end
    elseif not job.candidate then
      local surface=job.surfaces[job.surface_index]
      if not surface then job.column=nil;job.surfaces=nil;job.point_index=job.point_index+1;job.phase='column'
      else
        if job.last_candidates>=job.candidates_per_step then break end
        job.surface_index=job.surface_index+1;job.last_candidates=job.last_candidates+1;job.candidates=job.candidates+1
        if not job.best or surface.score<job.best.score-EPS then
          local p={x=job.column.x,y=job.column.y,z=surface.z};local r=job.radius;local ground=surface.ground_z
          local support={}
          for _,offset in ipairs({{r,0},{-r,0},{0,r},{0,-r}})do
            support[#support+1]=new_column(p.x+offset[1],p.y+offset[2],ground+M.flat_tolerance+2,ground-M.flat_tolerance-2)
          end
          job.candidate={position=p,ground_z=ground,normal_z=surface.normal_z,score=surface.score,
            support_columns=support,support_index=1}
        end
      end
    else
      local candidate=job.candidate;local column=candidate.support_columns[candidate.support_index]
      if column then
        if not need_query(job,1)then break end
        if not scan(job,host,column,budget(job))then break end
        if column.complete then
          if #column.surfaces==0 then job.rejected_support=job.rejected_support+1;job.candidate=nil
          else candidate.support_index=candidate.support_index+1 end
        end
      else
        candidate.support=candidate.support or flat_support(candidate)
        if not candidate.support then job.rejected_support=job.rejected_support+1;job.candidate=nil
        else
          if not need_query(job,M.clear_queries)then break end
          local ok,clear,cost=pcall(host.clear,candidate.position,job.radius,job.half_height)
          if not ok or type(clear)~='boolean' or cost~=M.clear_queries then
            finish(job,'none',ok and 'invalid-clear-result'or 'clear-error:'..tostring(clear));break
          end
          job.queries=job.queries+cost;job.last_queries=job.last_queries+cost
          if clear then job.best=candidate else job.rejected_occupied=job.rejected_occupied+1 end
          job.candidate=nil
          if clear and job.mode=='random'then finish(job,'found','safe-random')end
        end
      end
    end
  end
  return result(job)
end
function M.cancel(job,reason)
  if job.status=='searching'then finish(job,'none',reason or 'cancelled')end
  return result(job)
end
return M
