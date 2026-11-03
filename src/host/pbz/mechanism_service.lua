-- Local grid ownership and bounded scheduling. Rule engines never call UE.
local Blocks=require('content.blocks')
local D=require('rules.block_directions')
local geometry=require('rules.placement_geometry')
local Props=require('rules.block_properties')
local Fluid=require('rules.fluid_network')
local M={};M.__index=M
local function copy(t)local r={};for k,v in pairs(t or {})do r[k]=v end;return r end
local function merge(a,b)local r=copy(a);for k,v in pairs(b or {})do r[k]=v end;return r end
local function kind(def,id)
  if id=='pbzmc:tnt'then return 'tnt'end
  if def.mechanism=='source'then return 'redstone_block'end
  return def.mechanism or 'solid'
end
local function solid(record)
  local def=record and Blocks.get(record.content_id)
  return def and not def.fluid and def.collision~=false and not def.utility
end
local function same_position(a,b)
  return a.world==b.world and math.abs(a.x-b.x)<.001 and math.abs(a.y-b.y)<.001 and math.abs(a.z-b.z)<.001
end
function M.new(build)
  local self=setmetatable({build=build,world=build.world,binding=build.binding,log=build.log,
    index={},nodes={},terrain={},terrain_order={},probes={},probe_head=1,probe_set={},
    updates={},requests={},request_entries={},request_queue={},request_head=1,piston_retry={},
    motions={},motion_serial=0,sim_tick=0,sim_phase='events',timing_revision=2,
    supports={},overlap_cleanup={},overlap_removed=0,
    visual_queue={},visual_head=1,visual_queued={},tick_id=0,terrain_reads=0,batches=0,rejected=0},M)
  self.session=build.session;self.origin=copy(self.session.grid or {x=0,y=0,z=0})
  self.network=require('rules.redstone_network').new({read=function(x,y,z)return self:node_at(x,y,z)end,budget=96})
  self.fluid=Fluid.new({
    read=function(x,y,z)return self:read(x,y,z)end,
    is_solid=function(cell)return cell and not cell.pending and not Fluid.kind(cell)and not self:replaceable(cell)end,
    replaceable=function(cell)return self:replaceable(cell)end,
    commit=function(batch)return self:fluid_commit(batch)end,
  },{max_cells=512,budget=4,max_pending=4096})
  self.world.readNeighbor=function(record,dx,dy,dz)
    local p=self:cell(record);local key=D.key(p.x+dx,p.y+dy,p.z+dz)
    return self.index[key]or self.terrain[key]or nil
  end
  self.world.isSolid=function(record)
    if not record then return false end
    if record.native_terrain then return not record.pending end
    local def=Blocks.get(record.content_id);return def and def.full_cube==true or false
  end
  local initial={};for id in pairs(self.session.data.buildings)do initial[#initial+1]=id end;table.sort(initial)
  for _,id in ipairs(initial)do
    local record=self.session.data.buildings[id]
    if record.world==self.session.world and Blocks.get(record.content_id)then
      self:insert(record,{restored=true})
    end
  end
  local seeds={}
  for _,record in pairs(self.index)do if Fluid.kind(record)then seeds[#seeds+1]=self:cell(record)end end
  self.fluid:seed(seeds)
  self.session.on_change=function(changes,options)self:changed(changes,options)end
  self.session.expand_removals=function(ids)return self:expand_removals(ids)end
  self.contact=require('host.pbz.fluid_contact').new({binding=self.binding,world=self.world,
    read_world=function(x,y,z)return self:read_world(x,y,z)end,
    read_flow_world=function(x,y,z)local p=self:cell({x=x,y=y,z=z});return self:read(p.x,p.y,p.z)end,log=self.log})
  self.audio=require('host.pbz.mechanism_sounds').new(self.world.assets,self.log)
  return self
end
function M:cell(record)
  local o=self.origin
  return {x=math.floor((record.x-o.x)/100+.5),y=math.floor((record.y-o.y)/100+.5),z=math.floor((record.z-o.z)/100+.5)}
end
function M:position(x,y,z)return {x=self.origin.x+x*100,y=self.origin.y+y*100,z=self.origin.z+z*100,yaw=0}end
function M:read_world(x,y,z)
  local p=self:cell({x=x,y=y,z=z});return self.index[D.key(p.x,p.y,p.z)]
end
function M:node(record)
  local def=Blocks.get(record.content_id);local p=self:cell(record);local props=Props.copy(record.properties)or {}
  if def.mechanism=='torch'and props.face=='wall'then props.wall=true end
  local n={id=record.id,content_id=record.content_id,x=p.x,y=p.y,z=p.z,kind=kind(def,record.content_id),
    properties=props,conductor=def.conductor,hardness=def.hardness,push_reaction=def.push_reaction}
  local motion=(self.install_motion and self.install_motion[record.id])or(self.motions and self.motions[record.id])
  if motion and motion.x==p.x and motion.y==p.y and motion.z==p.z then n.moving=true;n.conductor=false end
  if n.kind=='piston_head'then
    local base=D.step(n,D.opposite(props.facing or 'north'));local r=self.index[D.key(base.x,base.y,base.z)]
    n.owner=r and r.id
  end
  return n
end
function M:insert(record,options)
  local p=self:cell(record);local key=D.key(p.x,p.y,p.z);local old=self.index[key]
  if old and old.id~=record.id then
    local old_fluid,new_fluid=Fluid.kind(old)~=nil,Fluid.kind(record)~=nil
    local fluid,cover=old_fluid and old or new_fluid and record,nil
    if old_fluid~=new_fluid then cover=old_fluid and record or old end
    if fluid and solid(cover)and same_position(fluid,cover)then
      self.overlap_cleanup=self.overlap_cleanup or {}
      self.overlap_cleanup[fluid.id]={solid_id=cover.id,x=p.x,y=p.y,z=p.z}
    end
    -- Never let restore order resurrect an obsolete fluid over a real block.
    -- Other corrupt overlaps are only diagnosed, not destructively repaired.
    local incoming=(old_fluid and not new_fluid)or old_fluid==new_fluid and tostring(record.id)>tostring(old.id)
    if not incoming then return false,'overlapped-record-suppressed'end
    if not old_fluid then self.network:remove(old.id)end
    self.nodes[old.id]=nil
  end
  self.index[key]=record
  local node=self:node(record);self.nodes[record.id]=node
  if not Fluid.kind(record)then
    local ok,why=self.network:put(node,options);assert(ok,why)
  end
  return true
end
-- One bounded-by-save-size reconciliation on binding/hot-update, never a
-- per-frame world scan. It only schedules proven fluid-under-solid duplicates.
function M:reconcile_overlaps()
  self.overlap_cleanup=self.overlap_cleanup or {};self.overlap_removed=self.overlap_removed or 0
  for _,record in pairs(self.session.data.buildings)do
    if record.world==self.session.world and Blocks.get(record.content_id)then
      local p=self:cell(record);local key=D.key(p.x,p.y,p.z);local current=self.index[key]
      if current and current.id==record.id then self.index[key]=record
      else self:insert(record)end
    end
  end
  local count=0
  for _,entry in pairs(self.overlap_cleanup)do
    self.network:notify(entry.x,entry.y,entry.z);self.fluid:changed(entry.x,entry.y,entry.z);count=count+1
  end
  return count
end
function M:cleanup_overlaps()
  if not self.overlap_cleanup or not next(self.overlap_cleanup) or self.session.busy or self.session.quarantined then return false end
  local ids={}
  for id,entry in pairs(self.overlap_cleanup or {})do
    local fluid=self.session.data.buildings[id];local cover=self.session.data.buildings[entry.solid_id]
    if fluid and Fluid.kind(fluid)and solid(cover)and same_position(fluid,cover)then
      ids[#ids+1]=id;if #ids>=16 then break end
    else self.overlap_cleanup[id]=nil end
  end
  if #ids==0 then return false end
  table.sort(ids)
  local ok,why=self.build.store:environmental(function()
    return require('rules.remove_buildings')(self.session,ids,self.world,self.build.store,true)
  end)
  if ok then
    for _,id in ipairs(ids)do self.overlap_cleanup[id]=nil end
    self.overlap_removed=(self.overlap_removed or 0)+#ids
  else self.overlap_error=tostring(why)end
  return ok
end
function M:queue_probe(x,y,z)
  local key=D.key(x,y,z)
  if not self.probe_set[key]and #self.probes-self.probe_head<8192 then
    self.probe_set[key]=true;self.probes[#self.probes+1]={x=x,y=y,z=z,key=key}
  end
end
function M:read(x,y,z)
  local key=D.key(x,y,z);local record=self.index[key]
  if record then
    -- A normal inventory/build transaction may clone every persistent record.
    -- Cell membership stays valid, but cached references must not become the
    -- 'before' ticket for a later atomic piston/fluid transaction.
    local current=self.session.data.buildings[record.id]
    if current then self.index[key]=current;return current end
    self.index[key]=nil
  end
  local terrain=self.terrain[key]
  if terrain~=nil then return terrain or nil end
  if not self.suppress_probes then self:queue_probe(x,y,z)end
  -- Unprobed cells are closed, never assumed to be air through a native wall.
  return {content_id='pbzmc:native_terrain',native_terrain=true,pending=true,x=x,y=y,z=z,kind='solid',conductor=true}
end
function M:node_at(x,y,z)
  local r=self:read(x,y,z)
  if r and r.native_terrain then return r end
  local n=r and self.nodes[r.id]or nil
  if n and n.kind=='piston_head'then
    local base=D.step(n,D.opposite(n.properties.facing or 'north'));local b=self.index[D.key(base.x,base.y,base.z)]
    n.owner=b and b.id
  end
  return n
end
function M:replaceable(cell)
  if not cell or Fluid.kind(cell)then return true end
  local def=Blocks.get(cell.content_id)
  return def and (def.collision==false and not def.fluid)or false
end
function M:probe_terrain(budget)
  if self.probe_head>#self.probes then return end
  local done=0
  while self.probe_head<=#self.probes and done<budget do
    local cell=self.probes[self.probe_head];self.probe_head=self.probe_head+1;self.probe_set[cell.key]=nil
    if self.terrain[cell.key]==nil then
      local p=self:position(cell.x,cell.y,cell.z);local solid=false
      for _,component in ipairs(self.world:overlap_components({X=p.x,Y=p.y,Z=p.z},{x=49,y=49,z=49}))do
        local obstacle=self.world:placement_obstacle(component)
        if obstacle=='terrain'or obstacle=='dynamic-collider'then solid=true;break end
      end
      self.terrain[cell.key]=solid and {content_id='pbzmc:native_terrain',native_terrain=true,
        kind='solid',conductor=true,x=cell.x,y=cell.y,z=cell.z}or false
      self.terrain_order[#self.terrain_order+1]=cell.key;self.terrain_reads=self.terrain_reads+1
      if #self.terrain_order>8192 then self.terrain[table.remove(self.terrain_order,1)]=nil end
      -- Resolving one queried cell may wake existing local consumers, but
      -- cannot recursively enqueue an unbounded survey of empty terrain.
      self.suppress_probes=true
      -- Resolving our cached knowledge is not a physical block/shape change.
      -- It may retry a waiting actuator, but cannot pulse an observer at air.
      self.network:notify(cell.x,cell.y,cell.z,{shape_changed=false});self.fluid:changed(cell.x,cell.y,cell.z)
      self.suppress_probes=false
      self:near_support(cell)
      self:queue_visuals(cell)
    end
    done=done+1
  end
  if self.probe_head>#self.probes then self.probes={};self.probe_head=1 end
end
function M:near_support(p)
  for _,direction in ipairs(D.order)do local q=D.step(p,direction);local r=self.index[D.key(q.x,q.y,q.z)];if r then self.supports[r.id]=true end end
end
function M:queue_visuals(p)
  if not self.world.fluid_visual then return end
  for dx=-1,1 do for dy=-1,1 do for dz=-1,1 do
    local n=self.index[D.key(p.x+dx,p.y+dy,p.z+dz)]
    if n and Fluid.kind(n)and not self.visual_queued[n.id]then
      self.visual_queued[n.id]=true;self.visual_queue[#self.visual_queue+1]=n.id
    end
  end end end
end
function M:changed(changes,options)
  if self.session.grid then self.origin=copy(self.session.grid)end
  local echo={}
  for _,row in ipairs(changes)do
    local r=row.before
    if options and options.signal_output and r and row.after and r.content_id==row.after.content_id and same_position(r,row.after)then
      local n=self:node(row.after)
      if self.network:already_applied(n)then
        -- Rules have already notified the observers and neighbours of this
        -- edge. Publishing its visual/save state must not restart the pulse.
        echo[row]=true;self.nodes[n.id]=n;self.index[D.key(n.x,n.y,n.z)]=row.after
      end
    end
    if r and not echo[row] then
      local p=self:cell(r);local key=D.key(p.x,p.y,p.z)
      if self.index[key]and self.index[key].id==r.id then self.index[key]=nil end
      if not row.after or row.after.content_id~=r.content_id or row.after.x~=r.x or row.after.y~=r.y or row.after.z~=r.z then
        self.network:remove(r.id);self.nodes[r.id]=nil;self.updates[r.id]=nil;self.requests[r.id]=nil
        if self.request_entries then self.request_entries[r.id]=nil end
        if self.motions then self.motions[r.id]=nil end
      end
    end
  end
  for _,row in ipairs(changes)do if row.after and not echo[row] then self:insert(row.after,{restored=row.restored==true})end end
  local notified,physical={},{}
  local function notify(record,shape_change,restored)
    local p=self:cell(record);local key=D.key(p.x,p.y,p.z)
    if not notified[key]then
      notified[key]=true;self.network:notify(p.x,p.y,p.z,restored and {shape_changed=false} or nil)
    end
    if shape_change and not physical[key]then
      physical[key]=true;self.fluid:changed(p.x,p.y,p.z);self:near_support(p);self:queue_visuals(p)
    end
  end
  for _,row in ipairs(changes)do
    local a,b=row.before,row.after
    local moved=a and b and not same_position(a,b)
    -- These components have the same fluid permeability and support at every
    -- signal strength. Observers still receive their property changes.
    local k=b and Blocks.get(b.content_id).mechanism
    local electrical=k=='wire' or k=='repeater' or k=='comparator' or k=='observer' or k=='lever' or k=='torch'
    local shape_change=not a or not b or moved or a.content_id~=b.content_id or not electrical
    if not echo[row]then
      if a then notify(a,shape_change,row.restored)end
      if b and (not a or moved)then notify(b,shape_change,row.restored)end
      if shape_change and b then self.supports[b.id]=true end
    end
    if row.before and row.after and (row.before.properties or {}).open~=(row.after.properties or {}).open then
      local def=Blocks.get(row.after.content_id)
      if def.mechanism=='door'and row.after.properties.half~='upper'and self.audio then
        self:sound(row.after.content_id:match(':(.+)')..(row.after.properties.open and '_open'or '_close'),row.after)
      end
    end
    if row.after and row.after.content_id==Fluid.water then
      local tnt=require('host.pbz.tnt_service').get(self.binding)
      if tnt then
        local r=row.after;local height=r.z-50+Fluid.height(r)*100
        for id,fire in pairs(tnt.fires or {})do
          local p=fire.state
          if math.abs(p.x-r.x)<55 and math.abs(p.y-r.y)<55 and p.z>=r.z-55 and p.z<=height+5 then
            local ok,removed=pcall(tnt.world.destroy,tnt.world,fire.handle)
            if ok and removed~=false then tnt.fires[id]=nil;tnt.extinguished=(tnt.extinguished or 0)+1;self:sound('extinguish',r)end
          end
        end
      end
    end
  end
end
function M:flush_visuals(limit)
  if self.visual_head>#self.visual_queue then return end
  local done=0
  while self.visual_head<=#self.visual_queue and done<limit do
    local id=self.visual_queue[self.visual_head];self.visual_head=self.visual_head+1;self.visual_queued[id]=nil
    local h=self.session.handles[id]
    if h and h.fluid and h.active then
      local ok,why=self.world.fluid_visual:update(h,h.record)
      self.visual_failures=self.visual_failures or {}
      if not ok then
        self.last_visual_error=tostring(why);self.visual_failures[id]=(self.visual_failures[id]or 0)+1
        if self.visual_failures[id]<=3 then self.visual_queued[id]=true;self.visual_queue[#self.visual_queue+1]=id end
      else self.visual_failures[id]=nil end
    end
    done=done+1
  end
  if self.visual_head>#self.visual_queue then self.visual_queue={};self.visual_head=1 end
end
function M:record(id,x,y,z,properties,previous)
  local r=self:position(x,y,z);r.id=previous and previous.id or self.session:next_id();r.world=self.session.world
  r.content_id=id;r.properties=Props.copy(properties);return r
end
function M:commit(changes,options,environment)
  local canonical={}
  for _,row in ipairs(changes)do
    local before=row.before
    if before then
      local current=self.session.data.buildings[before.id]
      if current~=before then
        -- Only repair identity lost in a full snapshot clone. A genuine state
        -- or position change is still a stale transaction, never overwritten.
        if not current then return false,'stale-mechanism-record'end
        for _,key in ipairs({'id','content_id','world','x','y','z','yaw'})do
          if before[key]~=current[key]then return false,'stale-mechanism-record'end
        end
        if not Props.equal(before.properties,current.properties)then return false,'stale-mechanism-properties'end
        before=current
      end
    end
    canonical[#canonical+1]={before=before,after=row.after}
  end
  changes=canonical
  local call=function()return self.session:batch(changes,options)end
  local ok,why
  if environment then ok,why=self.build.store:environmental(call)else ok,why=call()end
  if ok then self.batches=self.batches+1 else self.rejected=self.rejected+1;self.last_error=tostring(why)end
  return ok,why
end
function M:fluid_commit(batch)
  local changes={}
  for _,row in ipairs(batch)do
    local before=self.index[D.key(row.x,row.y,row.z)]
    if before~=row.before then return false end
    changes[#changes+1]={before=before,after=row.after and self:record(row.after.content_id,row.x,row.y,row.z,row.after.properties,before)}
  end
  return self:commit(changes,nil,true)
end
function M:sound(event,record)if self.audio then self.audio:play(event,record)end end
function M:pair(record)
  local p=self:cell(record);local props=record.properties or {}
  local z=p.z+(props.half=='upper'and -1 or 1)
  local other=self.index[D.key(p.x,p.y,z)]
  if other and other.content_id==record.content_id and (other.properties or {}).half~=props.half then return other end
end
function M:expand_removals(ids)
  local result,seen={},{}
  local function add(id)if id and not seen[id]then seen[id]=true;result[#result+1]=id end end
  for _,id in ipairs(ids)do add(id)end
  local i=1
  while i<=#result do
    local record=self.session.data.buildings[result[i]];i=i+1
    if record then
      local def=Blocks.get(record.content_id);local p=self:cell(record);local props=record.properties or {}
      if def.mechanism=='door'then local other=self:pair(record);add(other and other.id)
      elseif def.mechanism=='piston'or def.mechanism=='sticky_piston'then
        local q=D.step(p,props.facing or 'north');local head=self.index[D.key(q.x,q.y,q.z)]
        if head and head.content_id=='pbzmc:piston_head'then add(head.id)end
      elseif def.mechanism=='piston_head'then
        local q=D.step(p,D.opposite(props.facing or 'north'));local base=self.index[D.key(q.x,q.y,q.z)]
        if base and (base.content_id=='pbzmc:piston'or base.content_id=='pbzmc:sticky_piston')then add(base.id)end
      end
    end
  end
  return result
end
function M:interact(aim)
  local _,handle=self.build:target(aim);local r=handle and self.session.data.buildings[handle.id]
  if not r then return false,'pass'end
  local def=Blocks.get(r.content_id);local props=copy(r.properties);local k=def.mechanism;local event
  if k=='door'and def.manual then props.open=not props.open
  elseif k=='lever'then props.powered=not props.powered;event='lever_click'
  elseif k=='repeater'then props.delay=(props.delay or 1)%4+1
  elseif k=='comparator'then props.mode=props.mode=='subtract'and 'compare'or 'subtract';event='comparator_click'
  elseif k=='wire'then props.dot=not props.dot
  else return false,'pass'end
  local next=copy(r);next.properties=props;local changes={{before=r,after=next}}
  if k=='door'then local other=self:pair(r);if not other then return false,'fail'end
    local n=copy(other);n.properties=merge(other.properties,{open=props.open});changes[#changes+1]={before=other,after=n}
  end
  local ok=self:commit(changes)
  if ok and event then self:sound(event,next)end
  return ok,ok and 'consume'or 'fail'
end
function M:scoop(aim)
  local start,direction=aim();local hit=self.build:target(aim,true)
  local reach=500
  if hit then local p=hit.ImpactPoint;reach=math.min(reach,math.sqrt((p.X-start.X)^2+(p.Y-start.Y)^2+(p.Z-start.Z)^2))end
  local last
  for distance=0,reach,10 do
    local r=self:read_world(start.X+direction.X*distance,start.Y+direction.Y*distance,start.Z+direction.Z*distance)
    if r and r~=last and Fluid.kind(r)then
      if Fluid.source(r)then
        local ok=self:commit({{before=r}})
        if ok then self:sound(r.content_id==Fluid.water and 'bucket_fill'or 'bucket_fill_lava',r)end
        return ok,ok and 'success'or 'fail'
      end
      last=r
    end
  end
  return false,'pass'
end
function M:place(def,position,hit,aim)
  if not self.session.grid then self.origin=copy(position)end
  local p=self:cell(position);local props=copy(def.defaults)
  local _,direction=aim();local facing=D.from_yaw(math.deg(math.atan(direction.Y,direction.X)))
  local normal=hit.ImpactNormal
  if props.facing then
    props.facing=facing
    if def.mechanism=='repeater'or def.mechanism=='comparator'or def.mechanism=='piston'or def.mechanism=='sticky_piston'then props.facing=D.opposite(facing)end
    if def.mechanism=='piston'or def.mechanism=='sticky_piston'or def.mechanism=='observer'then
      if math.abs(direction.Z)>.7 then props.facing=direction.Z>0 and 'down'or 'up';if def.mechanism=='observer'then props.facing=D.opposite(props.facing)end end
    end
    if def.mechanism=='end_rod'then
      props.facing=math.abs(normal.Z)>.5 and (normal.Z>0 and 'up'or 'down')or D.from_yaw(math.deg(math.atan(normal.Y,normal.X)))
    elseif def.mechanism=='lever'or def.mechanism=='torch'then
      if geometry.face_axis(normal.X,normal.Y,normal.Z)~=2 then
        props.face='wall';props.facing=D.from_yaw(math.deg(math.atan(normal.Y,normal.X)))
        if def.mechanism=='torch' then props.wall_inset=position.wall_inset end
      else props.face=normal.Z<0 and 'ceiling'or 'floor';if def.mechanism=='torch'then if normal.Z<0 then return false,'torch-ceiling' end;props.facing='north'end end
    end
  end
  if def.mechanism=='door'then
    local right=D.vectors[D.clockwise(facing)]
    props.hinge=(hit.ImpactPoint.X-position.x)*right.x+(hit.ImpactPoint.Y-position.y)*right.y>0 and 'right'or 'left'
  end
  local before=self.index[D.key(p.x,p.y,p.z)]
  if before and not Fluid.kind(before)then return false,'grid-occupied'end
  if def.fluid and before and before.content_id==def.id and Fluid.source(before)then return false,'fluid-source-exists'end
  local r=self:record(def.id,p.x,p.y,p.z,props,before);local changes={{before=before,after=r}}
  if def.mechanism=='door'then
    local upper=self:read(p.x,p.y,p.z+1)
    if upper and (not upper.pending)and not Fluid.kind(upper)then return false,'door-upper-occupied'end
    local top=self:record(def.id,p.x,p.y,p.z+1,merge(props,{half='upper'}),upper and not upper.native_terrain and upper or nil)
    changes[#changes+1]={before=upper and not upper.native_terrain and upper or nil,after=top}
  end
  local ok,why=self:commit(changes,{grid=self.session.grid or self.origin,native_solid=def.mechanism=='door'})
  if ok then
    if def.fluid then self:sound(def.fluid=='water'and 'bucket_empty'or 'bucket_empty_lava',r)end
    return true,r.id
  end
  return false,why
end
function M:apply_updates()
  if not next(self.updates)then return true,false,0 end
  local changes,done,used={},{},{}
  local ids={};for id in pairs(self.updates)do ids[#ids+1]=id end;table.sort(ids)
  for _,id in ipairs(ids)do
    local delta=self.updates[id]
    if #changes>=4 then break end
    local r=self.session.data.buildings[id]
    if not r then done[#done+1]=id
    elseif self.session.handles[id]and not used[id]then
      local n=copy(r);n.properties=merge(r.properties,delta)
      if not Props.equal(n.properties,r.properties)then changes[#changes+1]={before=r,after=n};used[id]=true end
      done[#done+1]=id
      if Blocks.get(r.content_id).mechanism=='door'then
        local other=self:pair(r)
        if other and not used[other.id]then
          local q=copy(other);q.properties=merge(other.properties,{open=n.properties.open,powered=n.properties.powered})
          if not Props.equal(q.properties,other.properties)then changes[#changes+1]={before=other,after=q};used[other.id]=true end
          done[#done+1]=other.id
        end
      end
    end
  end
  local ok=#changes==0 or self:commit(changes,{signal_output=true},true)
  if ok then for _,id in ipairs(done)do self.updates[id]=nil end end
  local remaining=false
  for id in pairs(self.updates)do if self.session.handles[id]then remaining=true;break end end
  return ok,remaining,#changes>0 and 1 or 0
end
function M:piston(id,extend,drop_pull)
  local record=self.session.data.buildings[id];if not record then return true end
  if not self.session.handles[id]then return false,'unrestored-piston-base'end
  local node=self:node(record);local current=self.network:state(id)
  if not current or current.properties.powered~=extend then return true end
  if node.moving then return true end -- Old block event at a now-moving base.
  local finish_after
  if not extend then
    local front=D.step(node,node.properties.facing or 'north',2);local pushed=self:read(front.x,front.y,front.z)
    local motion=pushed and self.motions and self.motions[pushed.id]
    if motion and motion.extend and motion.direction==node.properties.facing and not motion.source then
      -- Scheduled block ticks and block events run while isHandlingTick=true:
      -- MC TRIGGER_DROP=2 finalizes this pushed cell and skips sticky pulling.
      drop_pull=true;finish_after=pushed.id
    end
  end
  local plan,why=require('rules.piston_motion').plan(node,extend,function(x,y,z)return self:node_at(x,y,z)end,{drop_pull=drop_pull})
  if not plan then return false,why end
  if plan.unchanged then return true end
  local changes,used={},{ }
  local function set(before,after)changes[#changes+1]={before=before,after=after};used[before and before.id or after.id]=true end
  for _,entry in ipairs(plan.destroy)do
    for _,rid in ipairs(self:expand_removals({entry.id}))do local r=self.session.data.buildings[rid];if r and not used[rid]then set(r,nil)end end
  end
  local hp=plan.head;local oldhead=self.index[D.key(hp.x,hp.y,hp.z)]
  if not extend and oldhead and oldhead.content_id=='pbzmc:piston_head'then set(oldhead,nil)end
  for _,move in ipairs(plan.moves)do
    local r=self.session.data.buildings[move.id];if not r then return false,'piston-record-changed'end
    local props=r.properties
    if Blocks.get(r.content_id).mechanism=='observer'then props=merge(props,{powered=false})end
    set(r,self:record(r.content_id,move.to.x,move.to.y,move.to.z,props,r))
  end
  if extend then set(nil,self:record('pbzmc:piston_head',hp.x,hp.y,hp.z,{facing=hp.facing,type=hp.sticky and 'sticky'or 'normal',short=false}))end
  local base=copy(record);base.properties=merge(record.properties,{extended=extend,powered=extend});set(record,base)
  for _,change in ipairs(changes)do
    if change.before and not self.session.handles[change.before.id]then return false,'unrestored-piston-member'end
  end
  local function release(ticket)
    local restored=ticket:rollback()
    if not restored then self.entity_recovery=ticket;self.session.quarantined=true end
    return restored
  end
  local made,ticket,err=pcall(require('host.pbz.piston_entities').prepare,self,plan,changes,self.now or 0,self.entity_adapter)
  if not made then return false,tostring(ticket)end
  if not ticket then
    if not extend and not drop_pull and #plan.moves>0 then return self:piston(id,false,true)end
    return false,err
  end
  local moved; moved,err=ticket:apply()
  if not moved then
    local restored=release(ticket)
    if restored and not extend and not drop_pull and #plan.moves>0 then return self:piston(id,false,true)end
    return false,err or 'piston-entity-move-failed'
  end
  local installing={};local tick=self.sim_tick or self.network.tick
  for _,change in ipairs(changes)do
    local a,b=change.before,change.after
    if b and ((a and(a.x~=b.x or a.y~=b.y or a.z~=b.z))or b.content_id=='pbzmc:piston_head'or b.id==id and not extend)then
      local p=self:cell(b);self.motion_serial=(self.motion_serial or 0)+1
      installing[b.id]={id=b.id,x=p.x,y=p.y,z=p.z,started=tick,due=tick+2,
        direction=plan.direction,extend=extend,source=b.id==id or b.content_id=='pbzmc:piston_head',serial=self.motion_serial}
    end
  end
  self.install_motion=installing
  local call,ok;call,ok,err=pcall(self.commit,self,changes,{native_solid=true,animate=true,piston_rider=ticket.is_rider},true)
  self.install_motion=nil
  if not call then err=tostring(ok);ok=false end
  if not ok then
    local restored=release(ticket)
    if restored and not self.session.quarantined and not extend and not drop_pull and #plan.moves>0 then return self:piston(id,false,true)end
  else
    for rid,motion in pairs(installing)do self.motions[rid]=motion end
    if finish_after then self:finish_motion(finish_after)end
    local finished,errors=ticket:finish()
    self.last_piston_entities={id=id,count=#ticket.rows,extended=extend,finished=finished,errors=errors}
    self.network:acknowledge(id,{extended=extend});self:sound(extend and 'piston_extend'or 'piston_contract',base)
  end
  return ok,err
end
function M:finish_motion(id)
  local motion=self.motions[id];if not motion then return end
  self.motions[id]=nil
  local record=self.session.data.buildings[id]
  if record then
    local p=self:cell(record)
    if p.x==motion.x and p.y==motion.y and p.z==motion.z then
      self:insert(record,{shapes_updated=true})
      self.network:notify(p.x,p.y,p.z)
    end
  end
end
function M:queue_request(id,request)
  self.requests[id]=request
  local entry=self.request_entries[id]
  if entry then entry.request=request;return end
  entry={id=id,request=request};self.request_entries[id]=entry;self.request_queue[#self.request_queue+1]=entry
end
function M:drain_redstone()
  if #self.network.change_order==0 then return end
  for _,change in ipairs(self.network:drain_changes())do
    if change.properties then self.updates[change.id]=merge(self.updates[change.id],change.properties)end
    if change.request then self:queue_request(change.id,change.request);self.piston_retry[change.id]=nil end
  end
end
function M:rebind_timing(now)
  self.network=require('rules.redstone_network').rebind(self.network)
  self.motions=self.motions or {};self.motion_serial=self.motion_serial or 0
  if self.timing_revision~=2 then
    self.sim_tick=self.network.tick;self.sim_phase='events';self.tick_id=self.sim_tick
    self.request_entries={};self.request_queue={};self.request_head=1;self.piston_retry={}
    local ids={};for id in pairs(self.requests or {})do ids[#ids+1]=id end;table.sort(ids)
    for _,id in ipairs(ids)do
      local request=self.requests[id];local n=self.network:state(id)
      if n then
        request.x=request.x or n.x;request.y=request.y or n.y;request.z=request.z or n.z
        request.block_kind=request.block_kind or n.kind;request.facing=request.facing or n.properties.facing
        self:queue_request(id,request)
      end
    end
    self.timing_revision=2
  end
  self.started=self.started or now or 0
  return {tick=self.sim_tick,scheduled=#self.network.heap,motions=(function()local n=0;for _ in pairs(self.motions)do n=n+1 end;return n end)()}
end
function M:run_block_events(limit)
  local attempted,hold=0,false;local stop=#self.request_queue
  if stop==0 then return 0,false end
  while self.request_head<=stop and attempted<limit do
    local entry=self.request_queue[self.request_head];self.request_queue[self.request_head]=false;self.request_head=self.request_head+1
    local id,request=entry.id,entry.request
    if self.request_entries[id]==entry and self.requests[id]==request then
      local keep=false
      if (self.piston_retry[id]or 0)>self.sim_tick then keep=true
      else
        local r=request.x~=nil and self:read(request.x,request.y,request.z)or self.session.data.buildings[id]
        local n=r and not r.native_terrain and self:node(r)
        local ok,why=true,nil
        if n and not n.moving and (not request.block_kind or n.kind==request.block_kind)then
          attempted=attempted+1
          if request.kind=='piston'then ok,why=self:piston(r.id,request.extend)
          elseif request.kind=='ignite'then
            local tnt=require('host.pbz.tnt_service').get(self.binding)
            if tnt then ok,why=tnt:prime(r.id,4)else ok=false;why='tnt-unavailable'end
          end
        end
        if not ok then
          if request.kind=='ignite'then self.last_ignite_block=why else self.last_piston_block=why end
          if why=='terrain-pending' or tostring(why):find('fixture-frame-create-budget',1,true)then
            -- Unknown native geometry is an asynchronous query, not an MC
            -- power edge. Complete it before crossing this tick boundary.
            keep=true;hold=true;self.piston_retry[id]=self.sim_tick
          elseif why~='immovable'and why~='push-limit'and why~='moving-block'and why~='native-terrain'then
            local delay=2
            if tostring(why):find(':%d+:')then
              delay=math.min(20,(entry.error_delay or 1)*2);entry.error_delay=delay
            end
            keep=true;self.piston_retry[id]=self.sim_tick+delay
          end
        end
      end
      if self.request_entries[id]==entry and self.requests[id]==request then
        if keep then self.request_queue[#self.request_queue+1]=entry
        else self.requests[id]=nil;self.request_entries[id]=nil;self.piston_retry[id]=nil end
      end
      if self.session.quarantined then hold=true;break end
    end
  end
  if self.request_head>stop then
    -- Deferred entries are already at the tail. Compact consumed slots once,
    -- so long-running flying machines do not grow a historical queue.
    local queue={};for i=self.request_head,#self.request_queue do queue[#queue+1]=self.request_queue[i]end
    self.request_queue=queue;self.request_head=1
  end
  local ready=false
  for i=self.request_head,#self.request_queue do
    local entry=self.request_queue[i]
    if self.request_entries[entry.id]==entry and (self.piston_retry[entry.id]or 0)<=self.sim_tick then ready=true;break end
  end
  return attempted,hold or ready
end
function M:complete_motion_tick()
  if not next(self.motions)then return end
  local due={}
  for _,motion in pairs(self.motions)do if motion.due<=self.sim_tick then due[#due+1]=motion end end
  table.sort(due,function(a,b)return a.serial<b.serial end)
  for _,motion in ipairs(due)do self:finish_motion(motion.id)end
end
function M:check_supports()
  local count=0
  for id in pairs(self.supports)do
    self.supports[id]=nil;count=count+1
    local r=self.session.data.buildings[id]
    if r and self.session.handles[id]then
      local def=Blocks.get(r.content_id);local k=def.mechanism;local props=r.properties or {};local p=self:cell(r);local support
      if k=='door'then
        if not self:pair(r)then self:commit({{before=r}},nil,true)
        elseif props.half=='lower'then support='down'end
      elseif k=='wire'or k=='repeater'or k=='comparator'then support='down'
      elseif k=='torch'or k=='lever'then support=props.face=='wall'and D.opposite(props.facing)or props.face=='ceiling'and 'up'or 'down'end
      if support then
        local q=D.step(p,support);local below=self:read(q.x,q.y,q.z)
        if not below or Fluid.kind(below)then
          local changes={};for _,rid in ipairs(self:expand_removals({id}))do local row=self.session.data.buildings[rid];if row then changes[#changes+1]={before=row}end end
          local ok=self:commit(changes,nil,true);if not ok then self.supports[id]=true end
        end
      end
    end
    if count>=4 or self.session.quarantined then break end
  end
end
function M:tick(now)
  if self.closed then return end
  self.now=now
  if self.entity_recovery then
    if not self.session.batch_recovery and not self.session.pending_group and not self.session.pending_cleanup
     and self.entity_recovery:rollback()then
      self.entity_recovery=nil;self.session.quarantined=false
    else self.session.quarantined=true;return end
  end
  self:probe_terrain(4)
  self:flush_visuals(4)
  self.world:tick_mechanisms(now)
  if self.fluid.cell_count>0 then self.contact_until=now+16 end
  if self.contact and now<(self.contact_until or 0)then self.contact:tick(now)end
  -- One old saved block under a pawn may wait indefinitely for restoration.
  -- Only transactions touching an unrestored member must wait; other circuits
  -- and fluids continue on their own already-restored collision objects.
  if self.session.quarantined or self.session.busy then return end
  if self:cleanup_overlaps()then return end
  if self.timing_revision~=2 then self:rebind_timing(now)end
  self.started=self.started or now
  local target=math.floor(math.max(0,now-self.started)*20+1e-7);self.frame_target=target
  local work,actions,batches,completed=0,0,0,0
  local work_limit=self.redstone_budget or 96
  local deadline=os.clock()+.003
  -- A render frame may stop inside a game tick, but may never merge the next
  -- scheduled pulse across an unfinished block-event/moving-entity phase.
  while self.sim_tick<=target and work<work_limit and batches<8 and completed<8 do
    if self.sim_phase=='events'then
      if work+actions>0 and os.clock()>=deadline then break end
      local result=self.network:advance_to_tick(self.sim_tick,work_limit-work)
      self.redstone_work=result;work=work+result.processed;self:drain_redstone()
      local ok,remaining,used=self:apply_updates();batches=batches+used
      if not ok or remaining or result.pending or self.session.quarantined then break end
      local attempted,held=self:run_block_events(math.max(0,2-actions));actions=actions+attempted
      if held or self.session.quarantined then break end
      -- A successful block event can synchronously change another actuator.
      -- Resolve those neighbours before ending this same block-event phase.
      if self.network:stats().dirty==0 then self.sim_phase='motion'end
    else
      self:complete_motion_tick()
      self.tick_id=self.sim_tick;self.sim_tick=self.sim_tick+1;self.sim_phase='events';completed=completed+1
    end
  end
  self.redstone_frame={processed=work,actions=actions,batches=batches,completed=completed,
    tick=self.sim_tick,phase=self.sim_phase,target=target,backlog=math.max(0,target-self.sim_tick)}
  if not self.session.quarantined then
    self.fluid_work=self.fluid:advance(math.max(self.fluid.tick,self.tick_id),4);self:check_supports()
  end
end
function M:state()
  local overlaps=0;for _ in pairs(self.overlap_cleanup or {})do overlaps=overlaps+1 end
  local motions=0;for _ in pairs(self.motions or {})do motions=motions+1 end
  return {redstone=self.network:stats(),redstone_frame=self.redstone_frame,moving_blocks=motions,
    fluid=self.fluid:status(),terrain_reads=self.terrain_reads,
    probes=#self.probes-self.probe_head+1,batches=self.batches,rejected=self.rejected,last_error=self.last_error,
    last_piston_block=self.last_piston_block,last_ignite_block=self.last_ignite_block,last_piston_entities=self.last_piston_entities,
    entity_recovery=self.entity_recovery~=nil,notification_error=self.session.notification_error,
    legacy_fluid_overlaps=overlaps,legacy_fluid_removed=self.overlap_removed or 0,legacy_fluid_error=self.overlap_error,
    resources=self.world.mechanisms and self.world.mechanisms.report,audio=self.audio and self.audio:state()}
end
function M:close()
  self.closed=true;self.session.on_change=nil;self.session.expand_removals=nil
  if self.contact then self.contact:close()end
  if self.world.fluid_visual then self.world.fluid_visual:close()end
  if self.world.close_effects then self.world:close_effects()end
end
return M
