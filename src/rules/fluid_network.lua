-- Deterministic, event-driven MC fluid cells. Coordinates use PBZ Z-up.
-- Adapter owns world transactions and native state; this module owns no actors.
-- Reference: docs/FLUID_REFERENCE_20261101.md (local MC 26.3 classes).
local M={ticks_per_second=20,water='pbzmc:water',lava='pbzmc:lava'}
local Network={};Network.__index=Network
local horizontal={{0,-1,0},{0,1,0},{-1,0,0},{1,0,0}}
local neighbors={{0,-1,0},{0,1,0},{-1,0,0},{1,0,0},{0,0,-1},{0,0,1}}
local EMPTY={}
local function key(x,y,z)return x..','..y..','..z end
local function pos(x,y,z)return {x=x,y=y,z=z}end
local function shift(p,d)return pos(p.x+d[1],p.y+d[2],p.z+d[3])end
local function integer(v)return type(v)=='number' and v==math.floor(v)end
function M.kind(cell)
  local id=cell and cell.content_id
  return (id==M.water or id==M.lava) and id or nil
end
function M.level(cell)
  return math.max(0,math.min(7,math.floor(tonumber(cell and cell.properties and cell.properties.level)or 0)))
end
function M.falling(cell)return cell and cell.properties and cell.properties.falling==true or false end
function M.source(cell)return M.kind(cell)~=nil and M.level(cell)==0 and not M.falling(cell)end
function M.height(cell,above)
  if not M.kind(cell)then return 0 end
  if M.kind(above)==M.kind(cell)then return 1 end
  return (8-M.level(cell))/9
end
function M.cell(id,level,falling)
  assert(id==M.water or id==M.lava,'fluid-id-invalid')
  assert(integer(level or 0)and (level or 0)>=0 and (level or 0)<=7,'fluid-level-invalid')
  return {content_id=id,properties={level=level or 0,falling=falling==true}}
end
local function same(a,b)
  if a==b then return true end
  if not a or not b or a.content_id~=b.content_id then return false end
  return M.kind(a)~=nil and M.level(a)==M.level(b)and M.falling(a)==M.falling(b)
end
local function earlier(a,b)
  if a.due~=b.due then return a.due<b.due end
  return a.order<b.order
end
local function swap(self,a,b)
  local h=self.heap;h[a],h[b]=h[b],h[a];h[a].index=a;h[b].index=b
end
local function up(self,i)
  while i>1 do local p=math.floor(i/2);if not earlier(self.heap[i],self.heap[p])then break end;swap(self,i,p);i=p end
end
local function down(self,i)
  local h=self.heap
  while i*2<=#h do
    local c=i*2;if c<#h and earlier(h[c+1],h[c])then c=c+1 end
    if not earlier(h[c],h[i])then break end;swap(self,i,c);i=c
  end
end
local function remove_event(self,event)
  if not event then return end
  local h=self.heap;local i=event.index;self.pending[event.key]=nil
  local last=h[#h];h[#h]=nil
  if i<=#h then h[i]=last;last.index=i;up(self,i);down(self,last.index)end
end
function Network:_schedule(p,kind,due)
  local k=kind..':'..key(p.x,p.y,p.z);local old=self.pending[k]
  if old then if due<old.due then old.due=due;up(self,old.index)end;return true end
  if #self.heap>=self.max_pending then self.queue_overflow=true;return false end
  self.sequence=self.sequence+1
  local event={key=k,x=p.x,y=p.y,z=p.z,kind=kind,due=due,order=self.sequence,index=#self.heap+1}
  self.heap[event.index]=event;self.pending[k]=event;up(self,event.index);return true
end
function Network:_remember(p,cell)
  local k=key(p.x,p.y,p.z);local id=M.kind(cell);local old=self.known[k]
  if id and not old then self.cell_count=self.cell_count+1
  elseif old and not id then
    self.cell_count=self.cell_count-1;self.capacity_changed=true
    remove_event(self,self.pending['flow:'..k]);remove_event(self,self.pending['mix:'..k])
    self.paused[k]=nil
  end
  self.known[k]=id
end
function Network:_pause(p)
  local k=key(p.x,p.y,p.z)
  if not self.paused[k]then
    self.paused[k]=true;self.pause_tail=self.pause_tail+1;self.pause_queue[self.pause_tail]=pos(p.x,p.y,p.z)
  end
end
function Network:_delay(id)
  return id==M.water and 5 or (self.fast_lava and 10 or 30)
end
function Network:_notify(points,at,overrides)
  local seen={};local ok=true
  local function visit(p)
    local k=key(p.x,p.y,p.z);if seen[k]then return end;seen[k]=true
    local cell=self.adapter.read(p.x,p.y,p.z);self.reads=self.reads+1;self:_remember(p,cell)
    local id=M.kind(cell)
    if id then
      ok=self:_schedule(p,'flow',at+(overrides and overrides[k]or self:_delay(id)))and ok
      if id==M.lava then ok=self:_schedule(p,'mix',at)and ok end
    end
  end
  for _,p in ipairs(points)do visit(p);for _,d in ipairs(neighbors)do visit(shift(p,d))end end
  return ok
end
function Network:changed(x,y,z)
  assert(integer(x)and integer(y)and integer(z),'fluid-grid-coordinate-invalid')
  return self:_notify({pos(x,y,z)},self.tick)
end
function Network:seed(cells)
  -- Restore only schedules retained cells; never clears/rebuilds the host world.
  local ok=true
  for _,p in ipairs(cells or {})do
    assert(integer(p.x)and integer(p.y)and integer(p.z),'fluid-grid-coordinate-invalid')
    local cell=self.adapter.read(p.x,p.y,p.z);self.reads=self.reads+1;self:_remember(p,cell)
    local id=M.kind(cell)
    if id then
      ok=self:_schedule(p,'flow',self.tick+self:_delay(id))and ok
      if id==M.lava then ok=self:_schedule(p,'mix',self.tick)and ok end
    end
  end
  return ok
end

local function context(self)
  local ctx={network=self,cache={},writes={},order={},face={},count=self.cell_count,limited=false}
  function ctx:read(p)
    local k=key(p.x,p.y,p.z);local write=self.writes[k]
    if write then return write.after end
    local cached=self.cache[k]
    if cached~=nil then return cached~=EMPTY and cached or nil end
    local cell=self.network.adapter.read(p.x,p.y,p.z);self.network.reads=self.network.reads+1
    self.cache[k]=cell or EMPTY;return cell
  end
  function ctx:wall(a,b,id)
    if not self.network.adapter.can_flow then return true end
    local k=key(a.x,a.y,a.z)..'>'..key(b.x,b.y,b.z)..':'..id
    local cached=self.face[k];if cached~=nil then return cached end
    local allowed=self.network.adapter.can_flow(a,b,id)==true;self.face[k]=allowed;return allowed
  end
  function ctx:hold(p,id)
    local cell=self:read(p)
    if cell==nil or M.kind(cell)then return true end
    local fn=self.network.adapter.replaceable
    return fn~=nil and fn(cell,p.x,p.y,p.z,id)==true
  end
  function ctx:pass(a,b,id)
    local cell=self:read(b)
    return not (M.kind(cell)==id and M.source(cell))and self:hold(b,id)and self:wall(a,b,id)
  end
  function ctx:hole(p,id)
    local below=pos(p.x,p.y,p.z-1)
    return self:wall(p,below,id)and (M.kind(self:read(below))==id or self:hold(below,id))
  end
  function ctx:set(p,after)
    local k=key(p.x,p.y,p.z);local before=self:read(p)
    if same(before,after)then return false end
    local was,now=M.kind(before)~=nil,M.kind(after)~=nil
    if not was and now and self.count>=self.network.max_cells then self.limited=true;return false end
    if was~=now then self.count=self.count+(now and 1 or -1)end
    local write=self.writes[k]
    if write then write.after=after
    else
      write={x=p.x,y=p.y,z=p.z,before=before,after=after};self.writes[k]=write;self.order[#self.order+1]=write
    end
    return true
  end
  return ctx
end
local function source_count(ctx,p,id,check_wall)
  local count=0
  for _,d in ipairs(horizontal)do local q=shift(p,d)
    if M.kind(ctx:read(q))==id and M.source(ctx:read(q))and (not check_wall or ctx:wall(p,q,id))then count=count+1 end
  end
  return count
end
local function new_liquid(ctx,p,id)
  local maximum,sources=0,0
  for _,d in ipairs(horizontal)do
    local q=shift(p,d);local cell=ctx:read(q)
    if M.kind(cell)==id and ctx:wall(p,q,id)then
      maximum=math.max(maximum,8-M.level(cell));if M.source(cell)then sources=sources+1 end
    end
  end
  local net=ctx.network
  if sources>=2 and ((id==M.water and net.water_sources)or (id==M.lava and net.lava_sources))then
    local below=pos(p.x,p.y,p.z-1);local cell=ctx:read(below)
    if (M.kind(cell)==id and M.source(cell))or net.adapter.is_solid(cell,below.x,below.y,below.z)==true then
      return M.cell(id,0,false)
    end
  end
  local above=pos(p.x,p.y,p.z+1)
  if M.kind(ctx:read(above))==id and ctx:wall(p,above,id)then return M.cell(id,0,true)end
  local drop=(id==M.water or net.fast_lava)and 1 or 2
  local amount=maximum-drop
  return amount>0 and M.cell(id,8-amount,false)or nil
end
local function solidify(ctx,p,cell)
  if M.kind(cell)~=M.lava then return false end
  -- LiquidBlock checks above and four sides, deliberately excluding below.
  for i=1,5 do
    local q=i<=4 and shift(p,horizontal[i])or pos(p.x,p.y,p.z+1)
    if M.kind(ctx:read(q))==M.water then
      ctx:set(p,{content_id=M.source(cell)and 'pbzmc:obsidian'or 'pbzmc:cobblestone'})
      return true
    end
  end
  return false
end
local function slope(ctx,start,origin,id,limit)
  if ctx:hole(start,id)then return 0 end
  -- Breadth-first local search is equivalent to the bounded MC minimum route.
  -- A visited map and per-event reads avoid repeatedly tracing identical cells.
  local queue={{p=start,distance=0}};local head=1;local seen={[key(origin.x,origin.y,origin.z)]=true,[key(start.x,start.y,start.z)]=true}
  while head<=#queue do
    local entry=queue[head];head=head+1
    if entry.distance<limit then
      for _,d in ipairs(horizontal)do
        local q=shift(entry.p,d);local k=key(q.x,q.y,q.z)
        if not seen[k]and ctx:pass(entry.p,q,id)then
          seen[k]=true;local distance=entry.distance+1
          if ctx:hole(q,id)then return distance end
          queue[#queue+1]={p=q,distance=distance}
        end
      end
    end
  end
  return 1000
end
local function spread_sides(ctx,p,cell)
  local id=M.kind(cell);local net=ctx.network
  local drop=(id==M.water or net.fast_lava)and 1 or 2
  if not M.falling(cell)and 8-M.level(cell)-drop<=0 then return end
  local limit=(id==M.water or net.fast_lava)and 4 or 2
  local best=1000;local choices={}
  for _,d in ipairs(horizontal)do
    local q=shift(p,d)
    if ctx:pass(p,q,id)then
      local value=new_liquid(ctx,q,id)
      if value then
        local distance=slope(ctx,q,p,id,limit)
        if distance<best then choices={};best=distance end
        if distance<=best then choices[#choices+1]={p=q,cell=value}end
      end
    end
  end
  for _,choice in ipairs(choices)do
    local old=ctx:read(choice.p);local other=M.kind(old)
    -- Existing same-fluid cells recalculate on their own scheduled tick.
    if not other then ctx:set(choice.p,choice.cell)
    elseif other==M.lava and id==M.water then solidify(ctx,choice.p,old)end
  end
end
local function flow(ctx,p,cell)
  if solidify(ctx,p,cell)then return end
  local id=M.kind(cell)
  if not M.source(cell)then
    local value=new_liquid(ctx,p,id)
    ctx:set(p,value);cell=value
    if not cell then return end
  end
  local below=pos(p.x,p.y,p.z-1);local down=false
  if ctx:pass(p,below,id)then
    local old=ctx:read(below);local other=M.kind(old)
    if id==M.lava and other==M.water then
      down=ctx:set(below,{content_id='pbzmc:stone'})
    elseif id==M.water and other==M.lava then
      down=solidify(ctx,below,old)
    elseif not other then
      local value=new_liquid(ctx,below,id)
      if value then down=ctx:set(below,value)end
    end
  end
  if down then
    if source_count(ctx,p,id,false)>=3 then spread_sides(ctx,p,cell)end
  elseif M.source(cell)or not ctx:hole(p,id)then spread_sides(ctx,p,cell)end
end
function Network:_process(event)
  local p=pos(event.x,event.y,event.z);local ctx=context(self);local before=ctx:read(p)
  self:_remember(p,before)
  ctx.count=self.cell_count
  if not M.kind(before)then return 0,false end
  if event.kind=='mix'then solidify(ctx,p,before)else flow(ctx,p,before)end
  local batch={}
  for _,row in ipairs(ctx.order)do if not same(row.before,row.after)then batch[#batch+1]=row end end
  if #batch>0 then
    local ok,accepted=pcall(self.adapter.commit,batch)
    if not ok or accepted~=true then
      self:_schedule(p,event.kind,event.due+1)
      self.last_error=ok and 'fluid-transaction-rejected'or tostring(accepted)
      return 0,true
    end
    local overrides={};local k=key(p.x,p.y,p.z);local after=ctx:read(p)
    local above=ctx:read(pos(p.x,p.y,p.z+1))
    if M.kind(before)==M.lava and M.kind(after)==M.lava and not M.falling(before)and not M.falling(after)
      and M.height(after,above)>M.height(before,above)and self.lava_thickening_delay then
      -- Stable per-cell/tick seed, rather than a global or frame-order RNG.
      local sample=(p.x*734287+p.y*912931+p.z*438289+event.due*193+17)%4
      overrides[k]=self:_delay(M.lava)*(sample~=0 and 4 or 1)
    end
    for _,row in ipairs(batch)do self:_remember(row,row.after)end
    self:_notify(batch,event.due,overrides)
  end
  if ctx.limited then self:_pause(p)end
  return #batch,false
end
function Network:_wake_paused(at,budget)
  if not self.capacity_changed or self.cell_count>=self.max_cells then return 0 end
  local work=0
  while self.pause_head<=self.pause_tail and work<budget do
    local p=self.pause_queue[self.pause_head];self.pause_queue[self.pause_head]=nil;self.pause_head=self.pause_head+1;work=work+1
    local k=key(p.x,p.y,p.z)
    if self.paused[k]then
      self.paused[k]=nil
      local id=self.known[k];if id then self:_schedule(p,'flow',at+self:_delay(id))end
    end
  end
  if self.pause_head>self.pause_tail then
    self.pause_queue={};self.pause_head=1;self.pause_tail=0;self.capacity_changed=false
  end
  return work
end
function Network:advance(tick,budget)
  assert(integer(tick)and tick>=self.tick,'fluid-tick-must-be-absolute-monotonic')
  budget=budget or self.budget;assert(integer(budget)and budget>=0,'fluid-budget-invalid')
  self.tick=tick;local reads_before=self.reads
  local processed,changes,failed=0,0,false
  -- Capacity wake-up is bounded too, and does not inspect native/world objects.
  local woken=self:_wake_paused(tick,budget)
  while processed<budget and self.heap[1]and self.heap[1].due<=tick do
    local event=self.heap[1];remove_event(self,event)
    local n,bad=self:_process(event);processed=processed+1;changes=changes+n
    if bad then failed=true;break end
  end
  return {processed=processed,changed=changes,reads=self.reads-reads_before,woken=woken,
    queued=#self.heap,next_tick=self.heap[1]and self.heap[1].due or nil,cells=self.cell_count,
    limited=next(self.paused)~=nil,commit_failed=failed,queue_overflow=self.queue_overflow}
end
function Network:status()
  return {tick=self.tick,cells=self.cell_count,queued=#self.heap,next_tick=self.heap[1]and self.heap[1].due or nil,
    limited=next(self.paused)~=nil,reads=self.reads,queue_overflow=self.queue_overflow,last_error=self.last_error}
end
function M.new(adapter,options)
  options=options or {}
  assert(type(adapter)=='table'and type(adapter.read)=='function'and type(adapter.is_solid)=='function'
    and type(adapter.commit)=='function','fluid-adapter-incomplete')
  local max_cells=options.max_cells or 512
  local max_pending=options.max_pending or math.max(2048,max_cells*2+32)
  assert(integer(max_cells)and max_cells>=1 and integer(max_pending)and max_pending>=2,'fluid-limits-invalid')
  local tick=options.tick or 0;assert(integer(tick)and tick>=0,'fluid-tick-invalid')
  return setmetatable({adapter=adapter,tick=tick,budget=options.budget or 16,max_cells=max_cells,max_pending=max_pending,
    water_sources=options.water_sources~=false,lava_sources=options.lava_sources==true,fast_lava=options.fast_lava==true,
    lava_thickening_delay=options.lava_thickening_delay~=false,heap={},pending={},known={},cell_count=0,sequence=0,reads=0,
    paused={},pause_queue={},pause_head=1,pause_tail=0,capacity_changed=false,queue_overflow=false},Network)
end
M.contact={water={extinguish=true,horizontal_drag=0.8,sprint_drag=0.9,vertical_drag=0.8,input_acceleration=0.02,jump_impulse=0.04},
  lava={extinguish=false,horizontal_drag=0.5,shallow_vertical_drag=0.8,deep_vertical_drag=0.5,input_acceleration=0.02,
    jump_impulse=0.04,ignite_ticks=300,damage_health_units=4,health_unit_fraction=1/20}}
return M
