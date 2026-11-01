-- Bounded, reversible world mutations. One in-memory campaign commit; the
-- native savepoint remains the only disk persistence boundary.
local properties=require('rules.block_properties')
local M={}
local function copy(t)local r={};for k,v in pairs(t or {})do r[k]=v end;return r end
function M.apply(session,changes,options)
  options=options or {}
  if session.closed or session.quarantined or session.busy then return false,'session-unavailable' end
  if #changes==0 then return true end
  if #changes>128 then return false,'batch-too-large' end
  local host,store=session.host,session.store
  if not host:is_current() then return false,'stale-scene' end
  local candidate=copy(session.data);candidate.buildings=copy(session.data.buildings)
  local ids,ignored,prepared={},{},{}
  for _,change in ipairs(changes)do
    local before,after=change.before,change.after
    local id=after and after.id or before and before.id
    if not id or ids[id] or before~=session.data.buildings[id] then return false,'stale-or-duplicate-batch-record' end
    ids[id]=true;ignored[id]=true
    if before and (before.world~=session.world or not session.handles[id])then return false,'unrestored-batch-record' end
    if after then
      if after.world~=session.world or not session.registry.get(after.content_id)then return false,'invalid-batch-content' end
      for _,key in ipairs({'x','y','z','yaw'})do
        local n=after[key];if type(n)~='number' or n~=n or math.abs(n)==math.huge then return false,'invalid-batch-transform' end
      end
      if not pcall(properties.validate,after.properties)then return false,'invalid-batch-properties' end
      after=copy(after);after.properties=properties.copy(after.properties)
    end
    candidate.buildings[id]=after
    prepared[#prepared+1]={before=before,after=after,id=id,handle=session.handles[id]}
  end
  if options.grid then
    candidate.building_grids=copy(candidate.building_grids);candidate.building_grids[session.world]=copy(options.grid)
  end
  local prior_counts,counts,limits,total={},{},{},0
  for _,r in pairs(session.data.buildings)do if r.world==session.world then
    local d=session.registry.get(r.content_id);if d then local g=d.group or 'block';prior_counts[g]=(prior_counts[g]or 0)+1 end
  end end
  local occupied={}
  for _,r in pairs(candidate.buildings)do
    total=total+1
    if r.world==session.world then
      local d=session.registry.get(r.content_id)
      if d then local g=d.group or 'block';counts[g]=(counts[g]or 0)+1;limits[g]=math.min(limits[g]or math.huge,d.limit or 1024)end
      local key=r.x..':'..r.y..':'..r.z
      if occupied[key]and (ids[r.id]or ids[occupied[key]])then return false,'batch-grid-occupied'end
      occupied[key]=r.id
    end
  end
  for g,n in pairs(counts)do if n>(limits[g]or 1024)and n>(prior_counts[g]or 0)then return false,'building-capacity'end end
  if total>8192 then return false,'world-building-capacity'end
  local generation=session.generation;session.busy=true
  local attempted,created={},{ }
  local ok,why=pcall(function()
    for _,row in ipairs(prepared)do
      if row.after and (not row.before or row.before.content_id~=row.after.content_id or row.before.x~=row.after.x or row.before.y~=row.after.y or row.before.z~=row.after.z)then
        local yes,reason=host:can_place(row.after,ignored,options)
        assert(yes,reason or 'batch-space-occupied')
      end
    end
    for _,row in ipairs(prepared)do
      attempted[#attempted+1]=row
      if row.handle then
        if row.after then assert(host:revise(row.handle,row.after,options),'batch-native-update-failed')
        else assert(host:set_active(row.handle,false),'batch-deactivate-failed')end
      elseif row.after then
        row.created=host:create(row.after);created[#created+1]=row.created
        assert(row.created.rendered and row.created.colliding,'batch-incomplete-native-object')
      end
    end
    assert(generation==session.generation and host:is_current(),'scene-changed')
    local saved,reason=store:commit(candidate,prepared);assert(saved,reason or 'batch-commit-failed')
  end)
  if not ok then
    local pending={}
    if type(why)=='table' and why.cleanup_handle then pending[#pending+1]=why.cleanup_handle;why=why.reason end
    for _,h in ipairs(created)do local clean,done=pcall(host.destroy,host,h);if not clean or not done then pending[#pending+1]=h end end
    for i=#attempted,1,-1 do
      local row=attempted[i]
      if row.handle then
        local clean,done=pcall(function()
          if row.after then return host:revise(row.handle,row.before,{rollback=true})end
          return host:set_active(row.handle,true)
        end)
        if not clean or not done then
          -- Do not run another action across a failed native rollback.
          session.batch_recovery=session.batch_recovery or {};session.batch_recovery[#session.batch_recovery+1]=row
        end
      end
    end
    if #pending>0 then session.pending_group=pending;session.group_action='destroy' end
    session.quarantined=#pending>0 or session.batch_recovery~=nil
    session.busy=false;return false,tostring(why)
  end
  session.data=candidate;session.grid=candidate.building_grids and candidate.building_grids[session.world] or session.grid
  local retired={}
  for _,row in ipairs(prepared)do
    session.handles[row.id]=row.after and (row.handle or row.created) or nil
    if not row.after and row.handle then retired[#retired+1]=row.handle end
  end
  session.busy=false
  if session.notify then session:notify(prepared)end
  for _,h in ipairs(retired)do
    local clean,done=pcall(host.destroy,host,h)
    if not clean or not done then session.pending_group=session.pending_group or {};session.pending_group[#session.pending_group+1]=h end
  end
  if session.pending_group then session.group_action='destroy';session.quarantined=true end
  return true,prepared
end
return M
