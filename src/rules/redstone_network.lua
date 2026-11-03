-- Deterministic, host-independent 20 TPS redstone. This is an event/dirty-cell
-- simulation: idle networks do not traverse their nodes. See reference doc.
local D=require('rules.block_directions')
local M={TICKS_PER_SECOND=20}
local Network={};Network.__index=Network
local aliases={redstone='wire',redstone_wire='wire',redstone_torch='torch',redstone_wall_torch='torch',
 oak_door='door',iron_door='door'}
local function clone(v)
 if type(v)~='table' then return v end
 local t={};for k,x in pairs(v) do t[k]=clone(x) end;return t
end
local function equal(a,b)
 if type(a)~=type(b) then return false end
 if type(a)~='table' then return a==b end
 for k,v in pairs(a) do if not equal(v,b[k]) then return false end end
 for k in pairs(b) do if a[k]==nil then return false end end
 return true
end
local function level(n)
 if type(n)~='number' or n~=n then return 0 end
 return math.max(0,math.min(15,math.floor(n)))
end
local function kind(n)
 local k=n.kind or (n.content_id or ''):match(':(.+)$') or 'solid';return aliases[k] or k
end
local function conductor(n)
 if not n then return false end
 if n.moving then return false end
 if n.conductor~=nil then return n.conductor==true end
 local k=kind(n)
 if k=='piston' or k=='sticky_piston' then return not (n.properties or {}).extended end
 return k=='solid' or k=='tnt' or k=='redstone_block' or k=='observer'
end
local function face(n) return (n.properties or {}).facing or n.facing or 'north' end
local function is_piston(n)return n and (n.kind=='piston' or n.kind=='sticky_piston')end
local function attachment(n)
 local p=n.properties
 return p.support or ((p.face=='wall' or p.wall) and D.opposite(face(n)) or p.face=='ceiling' and 'up' or 'down')
end
-- A block change notifies its six neighbours. Some components additionally
-- notify around their attached/output block. A redstone block has no such relay.
local function relay_face(n)
 if n.kind=='lever' then return attachment(n) end
 if n.kind=='repeater' or n.kind=='comparator' or n.kind=='observer' then return D.opposite(face(n)) end
 if n.kind=='wire' or n.kind=='torch' then return 'all' end
end
local function before(a,b)
 if a.due~=b.due then return a.due<b.due end
 if a.priority~=b.priority then return a.priority<b.priority end
 return a.serial<b.serial
end
function M.new(options)
 options=options or {}
 return setmetatable({nodes={},cells={},watchers={},count=0,max_nodes=options.max_nodes or 8192,
  read=options.read,budget=options.budget or 256,tick=0,target_tick=0,
  dirty={},dirty_head=1,dirty_tail=0,queued={},heap={},events={},serial=0,
  changes={},change_order={},generation=0,total_work=0},Network)
end
function Network:_at(x,y,z)
 local key=D.key(x,y,z);local id=self.cells[key];if id then return self.nodes[id] end
 if self.read then
  local cache=self.read_cache
  if not cache then return self.read(x,y,z)end
  local value=cache[key]
  if value==nil then value=self.read(x,y,z) or false;cache[key]=value end
  return value or nil
 end
end
function Network:_relative(n,d,amount)
 local v=D.vectors[d];amount=amount or 1
 return self:_at(n.x+v.x*amount,n.y+v.y*amount,n.z+v.z*amount)
end
function Network:_enqueue(n)
 if not n or not self.nodes[n.id] or self.queued[n.id] then return end
 self.dirty_tail=self.dirty_tail+1;self.dirty[self.dirty_tail]=n.id;self.queued[n.id]=true
end
-- Only registered nodes can consume a notification. Terrain reads are for
-- signal, support and movement decisions, never for discovering listeners.
function Network:_registered(x,y,z)
 return self.nodes[self.cells[D.key(x,y,z)]]
end
function Network:_near(n,passive,output_only)
 local own=self:_registered(n.x,n.y,n.z)
 if not passive or not is_piston(own)then self:_enqueue(own)end
 local function neighbor(a,notifies_piston)
  if not a then return end
  if is_piston(a)then
   if passive or not notifies_piston then return end
   a._restored_retracted=nil
  end
  if a.id~=n.id then
   a._torch_blocked=nil;a._last_request=nil
  end
  self:_enqueue(a)
 end
 local relay=not passive and relay_face(n)
 for _,d in ipairs(D.order) do
  local v=D.vectors[d];neighbor(self:_registered(n.x+v.x,n.y+v.y,n.z+v.z),not output_only or relay==d)
 end
 -- Sloped dust and analog inputs have two-cell dependencies. Being in this
 -- dependency set does not send a vanilla neighbour update to a distant piston.
 local all=relay=='all'
 for _,d in ipairs(D.horizontal) do
  local v=D.vectors[d];local x,y=n.x+v.x,n.y+v.y
  local along=all or relay==d
  neighbor(self:_registered(x,y,n.z+1),along or relay=='up')
  neighbor(self:_registered(x,y,n.z-1),along or relay=='down')
  neighbor(self:_registered(x+v.x,y+v.y,n.z),along)
  if relay and (d=='east' or d=='west')then
   if along or relay=='north'then neighbor(self:_registered(x,y+1,n.z),true)end
   if along or relay=='south'then neighbor(self:_registered(x,y-1,n.z),true)end
  end
 end
 neighbor(self:_registered(n.x,n.y,n.z-2),all or relay=='down')
 neighbor(self:_registered(n.x,n.y,n.z+2),all or relay=='up')
end
function Network:_change(n,properties,signal,request)
 local c=self.changes[n.id]
 if not c then c={id=n.id,properties={}};self.changes[n.id]=c;self.change_order[#self.change_order+1]=n.id end
 if properties then for k,v in pairs(properties) do c.properties[k]=clone(v) end end
 if signal~=nil then c.signal=signal end
 if request then
  c.request=clone(request);c.request.x=n.x;c.request.y=n.y;c.request.z=n.z
  c.request.block_kind=n.kind;c.request.facing=face(n);c.request.tick=self.tick
 end
end
function Network:_props(n,delta,input_only)
 local changed={};local any=false
 for k,v in pairs(delta) do
  if not equal(n.properties[k],v) then n.properties[k]=clone(v);changed[k]=v;any=true end
 end
 if any then
  self:_change(n,changed)
  if not input_only then
   local directional=n.kind=='observer' or n.kind=='repeater' or n.kind=='comparator'
   self:_near(n,directional and changed.locked~=nil,directional);self:_observers(n)
  end
 end
 return any
end
function Network:_signal(n,value,already_notified)
 value=level(value)
 if n.signal~=value then n.signal=value;self:_change(n,nil,value);if not already_notified then self:_near(n)end end
end
function Network:_swap(a,b)
 local h=self.heap;h[a],h[b]=h[b],h[a];h[a].index=a;h[b].index=b
end
function Network:_heap_up(i)
 while i>1 do local p=math.floor(i/2);if not before(self.heap[i],self.heap[p]) then break end;self:_swap(i,p);i=p end
 return i
end
function Network:_heap_down(i)
 local h=self.heap
 while i*2<=#h do
  local j=i*2;if j<#h and before(h[j+1],h[j]) then j=j+1 end
  if not before(h[j],h[i]) then break end;self:_swap(i,j);i=j
 end
end
function Network:_cancel(id)
 local e=self.events[id];if not e then return end
 self.events[id]=nil;local h=self.heap;local i=e.index;local last=table.remove(h)
 if i<=#h then h[i]=last;last.index=i;self:_heap_down(self:_heap_up(i)) end
end
function Network:_schedule(n,delay,priority,reason,earlier)
 -- Vanilla block ticks belong to a position + block type, not an inventory
 -- identity which travels with the piston. A later same-type block at that
 -- position may receive the tick; moving blocks themselves never receive it.
 local key=D.key(n.x,n.y,n.z)..'/'..n.kind..(reason=='torch_restart'and '/restart'or '')
 local due=self.tick+delay;local existing=self.events[key]
 if existing then
  if not earlier or existing.due<=due then return end
  self:_cancel(key)
 end
 if #self.heap>=self.max_nodes*2+64 then return false,'scheduled-tick-capacity'end
 self.serial=self.serial+1
 local e={id=n.id,key=key,x=n.x,y=n.y,z=n.z,kind=n.kind,due=due,priority=priority or 0,reason=reason,serial=self.serial,index=#self.heap+1}
 self.events[key]=e;self.heap[e.index]=e;self:_heap_up(e.index)
end
function Network:_watch(n,add)
 if n.kind~='observer' or n.moving then return end
 local facing=face(n);local v=D.vectors[facing]
 local key=D.key(n.x+v.x,n.y+v.y,n.z+v.z)
 local watchers=self.watchers[key]
 if add then
  if not watchers then watchers={};self.watchers[key]=watchers end
  watchers[D.opposite(facing)]=n.id
 elseif watchers then
  watchers[D.opposite(facing)]=nil
  if not next(watchers)then self.watchers[key]=nil end
 end
end
function Network:_observers(changed)
 local watchers=self.watchers[D.key(changed.x,changed.y,changed.z)]
 if not watchers then return end
 -- Keep vanilla neighbour order if several observing faces share this cell.
 for _,d in ipairs(D.order)do
  local n=self.nodes[watchers[d]]
  if n and not n.properties.powered then self:_schedule(n,2,0,'observer')end
 end
end
function Network:put(record,options)
 options=options or {}
 assert(type(record)=='table' and (type(record.id)=='string' or type(record.id)=='number'),'block identity required')
 D.key(record.x,record.y,record.z)
 local old=self.nodes[record.id];local cell=D.key(record.x,record.y,record.z)
 if self.cells[cell] and self.cells[cell]~=record.id then return false,'occupied-cell' end
 if not old and self.count>=self.max_nodes then return false,'network-capacity' end
 local n=clone(record);n.kind=kind(n);n.properties=n.properties or {}
 if n.properties.facing and not D.valid(n.properties.facing) then return false,'invalid-facing' end
 if (n.kind=='repeater' or n.kind=='comparator') and (face(n)=='up' or face(n)=='down') then return false,'horizontal-facing-required' end
 local same=old and old.x==n.x and old.y==n.y and old.z==n.z and old.kind==n.kind
 if same then
  self:_watch(old,false)
  n.generation=old.generation;n.signal=old.signal;n._toggles=old._toggles;n._last_request=old._last_request
  n._restart_key=old._restart_key;n._torch_blocked=old._torch_blocked
  n._ignite_requested=old._ignite_requested
  -- Any real host/property edit permits a blocked piston to retry once.
  if not equal(old.properties,n.properties) then n._last_request=nil end
 else
  if old then self:remove(record.id) end
  self.generation=self.generation+1;n.generation=self.generation;n.signal=0;self.count=self.count+1
 end
 if n.kind=='wire' then n.signal=level(n.properties.power) end
 if n.kind=='torch' and n.properties.lit==nil then n.properties.lit=true end
 if n.kind=='repeater' then n.properties.delay=math.max(1,math.min(4,math.floor(tonumber(n.properties.delay) or 1))) end
 if n.kind=='comparator' then n.properties.mode=n.properties.mode=='subtract' and 'subtract' or 'compare';n.signal=level(n.properties.output) end
 if n.moving then n.signal=0 end
 if options.restored and is_piston(n)then
  if same then n._restored_retracted=old._restored_retracted
  elseif not n.properties.extended then n._restored_retracted=true end
 end
 self.nodes[n.id]=n;self.cells[cell]=n.id
 self:_watch(n,true)
 self:_near(n,options.restored)
 if options.restored and not same and is_piston(n)then self:_enqueue(n)end
 if not options.restored and (not old or not equal(old.properties,n.properties) or not same or old.moving~=n.moving) then self:_observers(n) end
 if n.kind=='observer'and not n.moving and options.shapes_updated then
  -- updateFromNeighbourShapes at placement/moving-block finalization visits
  -- the observing face, even when that face is air. Never carry an old pulse.
  if n.properties.powered then self:_props(n,{powered=false})end
  self:_schedule(n,2,0,'observer')
 elseif n.kind=='observer'and not n.moving and options.restored and n.properties.powered then
  -- Runtime timers are not serialized by PBZ. A saved high observer must get
  -- one OFF deadline; restoring an unpowered one never creates a new pulse.
  self:_schedule(n,2,0,'observer')
 end
 return true
end
function Network:remove(id)
 local n=self.nodes[id];if not n then return false,'unknown-block' end
 self:_watch(n,false)
 self.nodes[id]=nil;self.cells[D.key(n.x,n.y,n.z)]=nil;self.count=self.count-1
 self.changes[id]=nil;self:_near(n);self:_observers(n)
 return true
end
-- Notify changes to unregistered terrain/support or a failed actuator's vicinity.
function Network:notify(x,y,z,options)
 local n={x=x,y=y,z=z}
 local passive=options and options.shape_changed==false
 self:_near(n,passive)
 if not passive then self:_observers(n)end
end
-- Commit successful actuator changes without manufacturing a delayed input.
function Network:acknowledge(id,properties)
 local n=self.nodes[id];if not n then return false end
 for k,v in pairs(properties or {}) do n.properties[k]=clone(v) end
 n._last_request=nil;self:_near(n);return true
end
function Network:state(id) return clone(self.nodes[id]) end
function Network:already_applied(n)
 local live=self.nodes[n.id]
 return live and live.kind==n.kind and live.x==n.x and live.y==n.y and live.z==n.z
  and live.moving==n.moving and equal(live.properties,n.properties)
end
function Network:drain_changes()
 local result={}
 for _,id in ipairs(self.change_order) do if self.changes[id] then result[#result+1]=self.changes[id];self.changes[id]=nil end end
 self.change_order={};return result
end
-- Direction here is source -> receiver, unlike MC SignalGetter's query direction.
function Network:_output(n,d,strong,exclude_wire)
 if not n or n.moving then return 0 end
 local k=kind(n);local p=n.properties or {};local powered=p.powered==true
 if k=='wire' then
  if exclude_wire or d=='up' then return 0 end
  if d=='down' or (p[d] and p[d]~='none') then return level(n.signal or p.power) end
  return 0
 elseif k=='redstone_block' then return strong and 0 or 15
 elseif k=='lever' then
  return powered and (not strong or d==attachment(n)) and 15 or 0
 elseif k=='torch' then
  local support=p.support or (p.wall and D.opposite(face(n)) or 'down')
  return p.lit~=false and (strong and d=='up' or not strong and d~=support) and 15 or 0
 elseif k=='repeater' or k=='comparator' or k=='observer' then
  if d~=D.opposite(face(n)) then return 0 end
  if k=='comparator' then return level(n.signal or p.output) end
  return powered and 15 or 0
 end
 return 0
end
function Network:_received(n,from,strong,exclude_wire)
 local source=self:_relative(n,from);if not source then return 0 end
 local result=self:_output(source,D.opposite(from),strong,exclude_wire)
 if not strong and conductor(source) then
  for _,d in ipairs(D.order) do
   result=math.max(result,self:_output(self:_relative(source,d),D.opposite(d),true,exclude_wire))
  end
 end
 return result
end
function Network:_power(n,exclude,exclude_wire)
 local result=0
 for _,d in ipairs(D.order) do if d~=exclude then result=math.max(result,self:_received(n,d,false,exclude_wire)) end end
 return result
end
local function connects(n,d)
 if not n then return false end
 local k=kind(n)
 if k=='wire' then return true end
 if k=='repeater' then return face(n)==d or face(n)==D.opposite(d) end
 if k=='observer' then return face(n)==d end
 return k=='lever' or k=='torch' or k=='redstone_block' or k=='comparator'
end
function Network:_wire(n)
 local connections={};local above=conductor(self:_relative(n,'up'))
 local value=self:_power(n,nil,true)
 for _,d in ipairs(D.horizontal) do
  local pos=D.step(n,d);local neighbor=self:_at(pos.x,pos.y,pos.z);local side='none'
  if not above and conductor(neighbor) and connects(self:_at(pos.x,pos.y,pos.z+1),d) then side='up'
  elseif connects(neighbor,d) or (not conductor(neighbor) and connects(self:_at(pos.x,pos.y,pos.z-1),d)) then side='side' end
  connections[d]=side
  if neighbor and kind(neighbor)=='wire' then value=math.max(value,level(neighbor.signal or (neighbor.properties or {}).power)-1) end
  local slope
  if conductor(neighbor) then if not above then slope=self:_at(pos.x,pos.y,pos.z+1) end
  else slope=self:_at(pos.x,pos.y,pos.z-1) end
  if slope and kind(slope)=='wire' then value=math.max(value,level(slope.signal or (slope.properties or {}).power)-1) end
 end
 local ns=connections.north=='none' and connections.south=='none'
 local ew=connections.east=='none' and connections.west=='none'
 if not (n.properties.dot==true and ns and ew) then
  if ns then if connections.west=='none' then connections.west='side' end;if connections.east=='none' then connections.east='side' end end
  if ew then if connections.north=='none' then connections.north='side' end;if connections.south=='none' then connections.south='side' end end
 end
 connections.power=level(value);local changed=self:_props(n,connections);self:_signal(n,value,changed)
end
function Network:_rear(n)
 local input=self:_received(n,face(n),false,false);local rear=self:_relative(n,face(n))
 if rear and kind(rear)=='wire' then input=math.max(input,level(rear.signal or (rear.properties or {}).power)) end
 if kind(n)=='comparator' and rear then
  if rear.analog~=nil then input=level(rear.analog)
  elseif input<15 and conductor(rear) then
   local further=self:_relative(rear,face(n));if further and further.analog~=nil then input=level(further.analog) end
  end
 end
 return input
end
function Network:_side(n,diodes_only)
 local value=0
 for _,d in ipairs({D.clockwise(face(n)),D.counterclockwise(face(n))}) do
  local source=self:_relative(n,d)
  if source then
   local k=kind(source)
   if not diodes_only or k=='repeater' or k=='comparator' then
    local p=(k=='wire' and not diodes_only) and level(source.signal or (source.properties or {}).power)
     or (k=='redstone_block' and not diodes_only) and 15 or self:_output(source,D.opposite(d),true,false)
    value=math.max(value,p)
   end
  end
 end
 return value
end
function Network:_compare(n)
 local rear,side=self:_rear(n),self:_side(n,false)
 return n.properties.mode=='subtract' and math.max(0,rear-side) or (rear>=side and rear or 0)
end
function Network:_torch_input(n)
 local p=n.properties;local support=p.support or (p.wall and D.opposite(face(n)) or 'down')
 return self:_received(n,support,false,false)>0
end
function Network:_prune_toggles(n)
 local list=n._toggles or {};local keep={}
 for _,time in ipairs(list) do if self.tick-time<=60 then keep[#keep+1]=time end end
 n._toggles=keep;return #keep
end
function Network:_actuate(n,extend,intent_changed)
 local tag=extend and 'extend' or 'retract'
 if (n.properties.extended==true)==extend then
  -- Several logical ticks can be drained together after a stall. A falling
  -- edge must cancel an earlier pending extension, even before host commit.
  if intent_changed then self:_change(n,nil,nil,{kind='piston',extend=extend}) end
  n._last_request=nil;return
 end
 if n._last_request~=tag then n._last_request=tag;self:_change(n,nil,nil,{kind='piston',extend=extend}) end
end
function Network:_diode_priority(n,normal)
 local direction=D.opposite(face(n));local front=self:_relative(n,direction)
 return front and (kind(front)=='repeater' or kind(front)=='comparator') and face(front)~=direction and -3 or normal
end
function Network:_evaluate(n)
 local k=n.kind;local p=n.properties
 if n.moving then self:_signal(n,0);return end
 if k=='wire' then self:_wire(n)
 elseif k=='lever' then self:_signal(n,p.powered and 15 or 0,true)
 elseif k=='redstone_block' then self:_signal(n,15,true)
 elseif k=='torch' then
  self:_signal(n,p.lit and 15 or 0,true)
  if not n._torch_blocked and p.lit==self:_torch_input(n) then self:_schedule(n,2,0,'torch',true) end
 elseif k=='repeater' then
  local locked=self:_side(n,true)>0;self:_props(n,{locked=locked});self:_signal(n,p.powered and 15 or 0,true)
  if not locked and (p.powered==true)~=(self:_rear(n)>0) then self:_schedule(n,p.delay*2,self:_diode_priority(n,p.powered and -2 or -1),'repeater') end
 elseif k=='comparator' then
  local output=self:_compare(n);self:_signal(n,p.output or 0,true)
  if output~=n.signal or (p.powered==true)~=(output>0) then self:_schedule(n,2,self:_diode_priority(n,0),'comparator') end
 elseif k=='observer' then self:_signal(n,p.powered and 15 or 0,true)
 elseif k=='door' then
  local other=self:_relative(n,p.half=='upper' and 'down' or 'up')
  local powered=self:_power(n)>0 or (other and kind(other)=='door' and self:_power(other)>0) or false
  if (p.powered==true)~=powered then self:_props(n,{powered=powered,open=powered}) end
  self:_signal(n,powered and 15 or 0)
 elseif k=='piston' or k=='sticky_piston' then
  local previous=p.powered==true
  local powered=self:_power(n,face(n))>0
  -- Java's quasi-connectivity samples around the cell above, excluding down.
  local top={x=n.x,y=n.y,z=n.z+1}
  powered=powered or (not n._restored_retracted and self:_power(top,'down')>0) or false
  self:_props(n,{powered=powered},true);self:_signal(n,powered and 15 or 0,true);self:_actuate(n,powered,previous~=powered)
 elseif k=='tnt' then
  local powered=self:_power(n)>0
  -- A stable cube restored with powered=true may have survived a rejected
  -- host ignition. A fresh binding must request its fuse once as well.
  if powered and not n._ignite_requested then self:_change(n,nil,nil,{kind='ignite'})end
  n._ignite_requested=powered or nil
  self:_props(n,{powered=powered},true);self:_signal(n,powered and 15 or 0,true)
 elseif conductor(n) then
  local value=0;for _,d in ipairs(D.order) do value=math.max(value,self:_received(n,d,true,false)) end
  -- This passive block has no neighbourChanged broadcast of its own. All
  -- consumers read strong power from its actual source in _received().
  self:_signal(n,value,true)
 end
end
function Network:_event(e)
 local id=self.cells[D.key(e.x,e.y,e.z)];local n=id and self.nodes[id]
 if not n or n.kind~=e.kind or n.moving then return end
 local p=n.properties
 if e.reason=='torch' or e.reason=='torch_restart' then
  local count=self:_prune_toggles(n);local input=self:_torch_input(n)
  if p.lit and input then
   self:_props(n,{lit=false});n._toggles[#n._toggles+1]=self.tick
   if #n._toggles>=8 then self:_change(n,nil,nil,{kind='torch_burnout'});self:_schedule(n,160,0,'torch_restart') end
  elseif not p.lit and not input and count<8 then self:_props(n,{lit=true});n._torch_blocked=nil
  elseif not p.lit and not input then n._torch_blocked=true end
 elseif e.reason=='repeater' then
  local locked=self:_side(n,true)>0;self:_props(n,{locked=locked})
  if not locked then
   local should=self:_rear(n)>0
   if p.powered and not should then self:_props(n,{powered=false})
   elseif not p.powered then
    self:_props(n,{powered=true})
    if not should then self:_schedule(n,p.delay*2,-2,'repeater') end
   end
  end
 elseif e.reason=='comparator' then
  local output=self:_compare(n);self:_props(n,{output=output,powered=output>0});self:_signal(n,output,true)
 elseif e.reason=='observer' then
  self:_props(n,{powered=not p.powered})
  if p.powered then self:_schedule(n,2,0,'observer') end
 end
 self:_enqueue(n)
end
-- n adds requested game ticks; budget caps *all* event/cell work. If pending,
-- call advance_ticks(0,budget) later. The logical tick never passes dirty work,
-- so splitting a busy tick across host frames cannot change circuit results.
function Network:advance_ticks(n,budget)
 n=n or 0;assert(D.integer(n) and n>=0,'nonnegative integer tick count required')
 budget=budget or self.budget;assert(D.integer(budget) and budget>=1,'positive work budget required')
 self.target_tick=self.target_tick+n;local work=0
 while work<budget do
  if self.dirty_head<=self.dirty_tail then
   local id=self.dirty[self.dirty_head];self.dirty[self.dirty_head]=nil;self.dirty_head=self.dirty_head+1;self.queued[id]=nil
   local node=self.nodes[id];if node then self:_evaluate(node) end;work=work+1
   if self.dirty_head>self.dirty_tail then self.dirty={};self.dirty_head=1;self.dirty_tail=0 end
  else
   local event=self.heap[1]
   if event and event.due<=self.target_tick then
    self.tick=event.due;self:_cancel(event.key);self:_event(event);work=work+1
   else self.tick=self.target_tick;break end
  end
 end
 self.total_work=self.total_work+work
 local pending=self.dirty_head<=self.dirty_tail or (self.heap[1] and self.heap[1].due<=self.target_tick) or false
 return {tick=self.tick,target_tick=self.target_tick,pending=pending,processed=work,
  dirty=self.dirty_tail-self.dirty_head+1,scheduled=#self.heap}
end
function Network:stats()
 return {nodes=self.count,dirty=self.dirty_tail-self.dirty_head+1,scheduled=#self.heap,
  total_work=self.total_work,tick=self.tick,target_tick=self.target_tick}
end
-- Host barrier: process one specified game tick, never jumping across an
-- actuator commit. The host may split its dirty/event work across frames.
function Network:advance_to_tick(tick,budget)
 assert(D.integer(tick)and tick>=self.tick,'nondecreasing game tick required')
 budget=budget or self.budget;self.tick=tick;self.target_tick=math.max(self.target_tick,tick)
 if self.dirty_head<=self.dirty_tail or self.heap[1] and self.heap[1].due<=tick then self.read_cache={}end
 local work=0
 while work<budget do
  if self.dirty_head<=self.dirty_tail then
   local id=self.dirty[self.dirty_head];self.dirty[self.dirty_head]=nil;self.dirty_head=self.dirty_head+1;self.queued[id]=nil
   local n=self.nodes[id];if n then self:_evaluate(n)end;work=work+1
   if self.dirty_head>self.dirty_tail then self.dirty={};self.dirty_head=1;self.dirty_tail=0 end
  else
   local event=self.heap[1]
   if not event or event.due>tick then break end
   self:_cancel(event.key);self:_event(event);work=work+1
  end
 end
 self.total_work=self.total_work+work
 self.read_cache=nil
 return {tick=tick,target_tick=self.target_tick,processed=work,
  pending=self.dirty_head<=self.dirty_tail or (self.heap[1]and self.heap[1].due<=tick)or false,
  dirty=self.dirty_tail-self.dirty_head+1,scheduled=#self.heap}
end
function M.rebind(network)
 assert(type(network)=='table'and network.nodes and network.heap,'redstone-network-required')
 setmetatable(network,Network)
 network.watchers={}
 for _,n in pairs(network.nodes)do network:_watch(n,true)end
 -- Retain due time, priority and insertion order from the installed scheduler.
 -- Old installations keyed events by ID; snapshot their original positions.
 local events,heap={},{}
 for _,event in ipairs(network.heap)do
  local n=network.nodes[event.id]
  if event.x~=nil or n then
   event.x=event.x or n.x;event.y=event.y or n.y;event.z=event.z or n.z;event.kind=event.kind or n.kind
   event.key=D.key(event.x,event.y,event.z)..'/'..event.kind..(event.reason=='torch_restart'and '/restart'or '')
   local previous=events[event.key]
   if not previous or before(event,previous)then events[event.key]=event end
  end
 end
 for _,event in pairs(events)do heap[#heap+1]=event end
 table.sort(heap,before);for i,event in ipairs(heap)do event.index=i end
 network.events=events;network.heap=heap
 return network
end
M.clone=clone
return M
