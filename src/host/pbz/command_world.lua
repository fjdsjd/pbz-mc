-- Commands own only placed MC objects. Native PBZ geometry is never a block
-- record, never queried as mineable content, and never removed by this adapter.
-- Every request is validated before mutation; native work uses small reversible
-- build-session batches, with a caller checkpoint between batches.
local Props=require('rules.block_properties')
local State=require('storage.state')
local Occupancy=require('rules.build_occupancy')
local M={};M.__index=M
local axes={'x','y','z'}
local hidden={auto=true,track_output=true,command=true,success_count=true,last_output=true,
  spawn_egg=true,wall_inset=true,signal=true,output=true,dot=true,falling=true}
local command_fields={Command='command',auto='auto',TrackOutput='track_output',SuccessCount='success_count',LastOutput='last_output'}
local immutable={id=true,x=true,y=true,z=true}
local function copy(t)local out={};for k,v in pairs(t or {})do out[k]=v end;return out end
local function finite(n)return type(n)=='number'and n==n and math.abs(n)<=1e9 end
local function position(p)
  assert(type(p)=='table','command-block-position-required')
  local out={};for _,k in ipairs(axes)do
    assert(finite(p[k])and p[k]%1==0,'command-block-integer-position');out[k]=math.tointeger(p[k])
  end
  return out
end
local function equal(a,b)
  if type(a)~=type(b)then return false end
  if type(a)~='table'then return a==b end
  for k,v in pairs(a)do if not equal(v,b[k])then return false end end
  for k in pairs(b)do if a[k]==nil then return false end end
  return true
end
local function attempt(fn,self,...)
  local ok,a,b=pcall(fn,self,...);if not ok then return nil,tostring(a)end;return a,b
end
local function object(value)
  assert(type(value)=='table'and State.json_kind(value)=='object','block-data-compound-required')
  State.validate_value(value)
  assert(#require('storage.canonical_json')(value)<=65536,'block-data-too-large')
  return value
end
local function same(a,b)
  if a==b then return true end
  if not a or not b then return false end
  for _,k in ipairs({'id','content_id','world','x','y','z','yaw'})do if a[k]~=b[k]then return false end end
  return equal(a.properties,b.properties)
end
function M.new(build,options)
  assert(build and build.session and build.mechanisms and build.world,'command-build-service-required')
  options=options or {}
  assert(options.native_context==nil or type(options.native_context)=='function','command-native-context-validator-required')
  local size=options.batch_size or 8
  assert(type(size)=='number'and size%1==0 and size>=1 and size<=16,'command-batch-size:1..16')
  return setmetatable({build=build,session=build.session,mechanisms=build.mechanisms,
    options=options,batch_size=size,registry=build.session.registry},M)
end
function M:_current()
  local s=self.session
  assert(not s.closed and not s.quarantined and not s.busy,'command-build-session-unavailable')
  assert(self.build.world:is_current(),'command-build-world-stale')
  if self.build.binding then assert(self.build.binding:is_current(),'command-build-binding-stale')end
  if self.build.store.current then assert(self.build.store:current(),'command-build-store-stale')end
end
function M:origin()
  local source=self.session.grid or (self.options.origin and self.options.origin())or self.mechanisms.origin
  local o={};for _,k in ipairs(axes)do assert(source and finite(source[k]),'command-grid-origin-unavailable');o[k]=source[k]end
  return o
end
function M:_point(p)
  local o=self:origin();local out={x=o.x+p.x*100,y=o.y-p.z*100,z=o.z+p.y*100,yaw=0}
  for _,k in ipairs(axes)do assert(finite(out[k]),'command-block-outside-host-range')end
  return out
end
function M:_record(p)
  local point=self:_point(position(p))
  -- read_world is the placed-object index. mechanisms:read also probes native
  -- terrain and must not be used here.
  local ticket=self.mechanisms:read_world(point.x,point.y,point.z)
  local record=ticket and self.session.data.buildings[ticket.id]
  if not record or record.world~=self.session.world then return nil end
  for _,k in ipairs(axes)do if math.abs(record[k]-point[k])>.001 then return nil end end
  return record
end
function M:record(p)return attempt(function(self,p)self:_current();return self:_record(p)end,self,p)end
local function defaults(def)
  local p=copy(def.defaults)
  if def.axis and p.axis==nil then p.axis=def.default_axis or 'y'end
  return p
end
function M:_description(record)
  if not record then return {id='minecraft:air',properties={}}end
  local def=assert(self.registry.get(record.content_id),'command-block-content-unavailable')
  local p=defaults(def);for k,v in pairs(record.properties or {})do p[k]=v end
  local name=record.content_id:gsub('^pbzmc:','')
  if name=='redstone_dust'then name='redstone_wire'end
  if name=='redstone_torch'and p.face=='wall'then name='redstone_wall_torch'end
  local visible={};for k,v in pairs(p)do if not hidden[k]then visible[k]=v end end
  if def.mechanism=='torch'then visible.face=nil;if p.face~='wall'then visible.facing=nil end end
  if def.fluid then visible.level=(p.level or 0)+(p.falling and 8 or 0)end
  local result={id='minecraft:'..name,properties=visible}
  if def.command_block or record.content_id=='pbzmc:spawner'then
    result.data=self:_data(record)
    -- A clone carries entity state but destination coordinates are its own.
    for k in pairs(immutable)do result.data[k]=nil end
  end
  return result
end
function M:read_block(p)return attempt(function(self,p)self:_current();return self:_description(self:_record(p))end,self,p)end
function M:_data(record)
  assert(record,'block-has-no-data')
  local def=assert(self.registry.get(record.content_id),'command-block-content-unavailable')
  local o=self:origin();local p=record.properties or {}
  local data=State.object({id=def.command_block and 'minecraft:command_block'or 'minecraft:mob_spawner',
    x=math.floor((record.x-o.x)/100+.5),y=math.floor((record.z-o.z)/100+.5),z=math.floor(-(record.y-o.y)/100+.5)})
  if def.command_block then
    local all=defaults(def);for k,v in pairs(p)do all[k]=v end
    data.Command=all.command or '';data.auto=all.auto==true;data.TrackOutput=all.track_output~=false
    data.SuccessCount=all.success_count or 0;data.LastOutput=all.last_output or ''
  elseif record.content_id=='pbzmc:spawner'then
    local egg=p.spawn_egg and require('content.summon_mobs').egg(p.spawn_egg)
    data.SpawnData=State.object({entity=State.object(egg and {id='minecraft:'..egg.name}or {})})
  else error('block-has-no-data')end
  return data
end
function M:block_data(p)return attempt(function(self,p)
  self:_current();local record=self:_record(p);return self:_data(record),State.clone(record)
end,self,p)end
function M:_apply_data(record,value,replace)
  object(value)
  local def=assert(self.registry.get(record.content_id),'command-block-content-unavailable')
  assert(def.command_block or record.content_id=='pbzmc:spawner','block-has-no-data')
  local current=self:_data(record);local p=copy(record.properties)
  if replace then
    for k in pairs(immutable)do assert(equal(value[k],current[k]),'block-data-read-only:'..k)end
    if def.command_block then
      p.command='';p.auto=def.command_block=='chain';p.track_output=true;p.success_count=0;p.last_output=nil
    else p.spawn_egg=nil end
  end
  for k,v in pairs(value)do
    if immutable[k]then assert(equal(v,current[k]),'block-data-read-only:'..k)
    elseif def.command_block and command_fields[k]then
      if k=='auto'or k=='TrackOutput'then
        assert(type(v)=='boolean'or v==0 or v==1,'invalid-command-block-boolean:'..k);v=v==true or v==1
      end
      p[command_fields[k]]=v
    elseif record.content_id=='pbzmc:spawner'and k=='SpawnData'then
      object(v);object(v.entity)
      for q in pairs(v)do assert(q=='entity','spawner-data-unavailable:'..tostring(q))end
      for q in pairs(v.entity)do assert(q=='id','spawner-entity-data-unavailable:'..tostring(q))end
      local id=v.entity.id
      if id==nil then p.spawn_egg=nil else
        assert(type(id)=='string','spawner-entity-id-required')
        local species=id:match('^minecraft:([a-z0-9_]+)$')or id:match('^([a-z0-9_]+)$')
        local egg=species and 'pbzmc:'..species..'_spawn_egg'
        assert(egg and require('content.summon_mobs').egg(egg),'spawner-entity-unavailable:'..id);p.spawn_egg=egg
      end
    else error('block-data-field-unavailable:'..tostring(k))end
  end
  Props.validate(p);local after=copy(record);after.properties=p;return after
end
function M:_definition(entry)
  assert(type(entry)=='table'and type(entry.id)=='string','command-block-required')
  local name=entry.id:match('^minecraft:([a-z0-9_]+)$')or entry.id:match('^pbzmc:([a-z0-9_]+)$')or entry.id:match('^([a-z0-9_]+)$')
  assert(name,'command-block-id-invalid')
  if name=='air'or name=='cave_air'or name=='void_air'then
    assert(not entry.properties or not next(entry.properties),'air-has-no-block-states')
    assert(not entry.data or not next(object(entry.data)),'air-has-no-block-data');return nil
  end
  local wall=name=='redstone_wall_torch'
  if name=='redstone_wire'then name='redstone_dust'elseif wall then name='redstone_torch'end
  local id='pbzmc:'..name;local def=self.registry.get(id)
  assert(def and def.id==id and not def.utility,'block-unavailable:'..entry.id)
  local p=defaults(def);local allowed=copy(p)
  for k in pairs(hidden)do allowed[k]=nil end
  if def.mechanism=='torch'then allowed.face=nil;if not wall then allowed.facing=nil end;p.face=wall and 'wall'or 'floor'end
  assert(entry.properties==nil or type(entry.properties)=='table','command-block-states-invalid')
  for k,v in pairs(entry.properties or {})do
    assert(allowed[k]~=nil,'block-state-unavailable:'..tostring(k))
    if def.fluid and k=='level'then
      assert(type(v)=='number'and v%1==0 and v>=0 and v<=15,'invalid-fluid-level');p.level=v%8;p.falling=v>=8
    else assert(type(v)==type(allowed[k]),'invalid-block-state-type:'..tostring(k));p[k]=v end
  end
  if p.facing and not (def.command_block or def.mechanism=='observer'or def.mechanism=='end_rod'or def.mechanism=='piston'
    or def.mechanism=='sticky_piston'or def.mechanism=='piston_head')then
    assert(p.facing~='up'and p.facing~='down','block-facing-must-be-horizontal')
  end
  if p.half then
    local door=def.mechanism=='door'and def.family~='trapdoor'and def.family~='gate'
    assert(door and (p.half=='upper'or p.half=='lower')or not door and (p.half=='top'or p.half=='bottom'),'invalid-block-half')
  end
  if p.type then
    assert(def.family=='slab'and (p.type=='top'or p.type=='bottom'or p.type=='double')
      or def.mechanism=='piston_head'and (p.type=='normal'or p.type=='sticky'),'invalid-block-type')
  end
  for _,k in ipairs({'north','east','south','west'})do if type(p[k])=='string'then
    if def.family=='wall'then assert(p[k]=='none'or p[k]=='low'or p[k]=='tall','invalid-wall-side')
    else assert(p[k]=='none'or p[k]=='side'or p[k]=='up','invalid-wire-side')end
  end end
  Props.validate(p);return def,p
end
function M:_checkpoint(done,total,phase)
  if self.options.checkpoint then local value,why=self.options.checkpoint(done,total,phase);assert(value~=false,why or 'command-block-cancelled')end
  self:_current()
end
function M:_prepare(entries)
  self:_current();assert(type(entries)=='table'and #entries<=16384,'command-block-write-limit:16384')
  local count=0;for k in pairs(entries)do
    count=count+1;assert(type(k)=='number'and k%1==0 and k>=1 and k<=#entries,'command-block-array-required')
  end
  assert(count==#entries,'command-block-array-required')
  local map,order={},{}
  for i,item in ipairs(entries)do
    assert(type(item)=='table','command-block-entry-required')
    local p=position(item.pos);local key=p.x..':'..p.y..':'..p.z
    -- Validate even an overwritten entry: malformed input cannot hide behind
    -- the final write in a clone-move overlap.
    local def,props=self:_definition(item.block);local before=self:_record(p);local after
    if def then
      after=self:_point(p);after.content_id=def.id;after.world=self.session.world
      after.id=before and before.id or 'command-draft-'..i;after.properties=props
      if item.block.data~=nil then after=self:_apply_data(after,item.block.data,false)end
    end
    if not map[key]then order[#order+1]=key end
    map[key]={before=before,after=after,pos=p}
    if i%128==0 then self:_checkpoint(i,#entries,'validate')end
  end
  local changes,ignored={},{}
  for _,key in ipairs(order)do
    local row=map[key]
    if row.before then assert(self.session.handles[row.before.id],'command-block-not-restored');ignored[row.before.id]=true end
    if not same(row.before,row.after)then changes[#changes+1]=row end
  end
  local delta,why=Occupancy.for_session(self.session):delta(changes);assert(delta,why)
  for i,row in ipairs(changes)do
    if row.after then
      local clear,reason=self.build.world:can_place(row.after,ignored,{command=true});assert(clear,reason or 'command-block-space-occupied')
    end
    if i%self.batch_size==0 then self:_checkpoint(i,#changes,'preflight')end
  end
  -- A checkpoint can yield to the game. Do not overwrite blocks that changed
  -- during preflight, even if that mutation was an ordinary redstone update.
  for _,row in ipairs(changes)do assert(same(row.before,self:_record(row.pos)),'command-block-changed-during-preflight')end
  table.sort(changes,function(a,b)
    local x=not a.after and 0 or a.before and 1 or 2;local y=not b.after and 0 or b.before and 1 or 2
    if x~=y then return x<y end
    if a.pos.y~=b.pos.y then return a.pos.y<b.pos.y end
    if a.pos.z~=b.pos.z then return a.pos.z<b.pos.z end
    return a.pos.x<b.pos.x
  end)
  return changes
end
function M:_rollback(committed)
  local restored,failed=0,nil
  for at=#committed,1,-self.batch_size do
    local batch={}
    for i=at,math.max(1,at-self.batch_size+1),-1 do
      local row=committed[i];local current=self:_record(row.pos)
      if not same(current,row.after)then failed='command-block-rollback-state-changed';break end
      batch[#batch+1]={before=current,after=row.before}
    end
    if failed then break end
    local ok,why=self.mechanisms:commit(batch,{grid=self:origin(),command=true,rollback=true})
    if not ok then failed=tostring(why);break end
    restored=restored+#batch
    for _=1,#batch do table.remove(committed)end
    if at>self.batch_size then
      local ok,why=pcall(self._checkpoint,self,restored,#committed,'rollback');if not ok then failed=tostring(why);break end
    end
  end
  return restored,failed
end
function M:has_pending_mutations()
  return self.pending~=nil and (self.pending.attempting or #self.pending.rows>0)or false
end
function M:_native_current()
  local ok,current=pcall(function()
    return self.build.world:is_current()and (not self.build.binding or self.build.binding:is_current())
      and (not self.build.store.current or self.build.store:current())
  end)
  return ok and current==true
end
-- Shutdown-only escape hatch. The captured campaign callback owns a reference
-- to the original memory store and performs reverse compare-and-swap without
-- dereferencing a stale native actor. Native handles are retired by build.close.
function M:rollback_memory()
  local pending=self.pending
  if not pending then return true,0 end
  if pending.attempting then return false,'command-native-batch-still-active'end
  if #pending.rows==0 then self.pending=nil;return true,0 end
  if self:_native_current()then return false,'command-live-world-requires-native-rollback'end
  if not self.options.rollback_memory then return false,'command-memory-rollback-unavailable'end
  local called,ok,why=pcall(self.options.rollback_memory,State.clone(pending.rows),copy(pending.origin))
  if not called then return false,tostring(ok)end
  if not ok then return false,why or 'command-memory-rollback-rejected'end
  local count=#pending.rows;self.pending=nil;return true,count
end
function M:rollback_pending()
  local pending=self.pending;if not pending then return true,0 end
  if pending.attempting then return false,'command-native-batch-still-active'end
  if not self:_native_current()then return self:rollback_memory()end
  local total=#pending.rows
  local called,restored,why=pcall(self._rollback,self,pending.rows)
  if not called then why=restored end
  if #pending.rows==0 then self.pending=nil;return true,total end
  -- A world can retire during exceptional cleanup. The remaining rows still
  -- have their original store lease, so finish without accessing its actors.
  if not self:_native_current()then
    local ok,n=self:rollback_memory();if ok then return true,total end;why=n
  end
  return false,why or 'command-native-rollback-pending'
end
function M:_write(entries)
  assert(not self.pending and not self.transaction,'command-previous-transaction-pending')
  local changes=self:_prepare(entries);if #changes==0 then return 0 end
  local committed={};local origin=self:origin()
  self.pending={rows=committed,origin=copy(origin),attempting=false}
  local ok,why=pcall(function()
    for at=1,#changes,self.batch_size do
      self:_current();local batch={}
      for i=at,math.min(#changes,at+self.batch_size-1)do
        local row=changes[i];local current=self:_record(row.pos)
        assert(same(row.before,current),'command-block-changed-before-commit')
        row.before=current
        if row.after and not row.before then row.after.id=self.session:next_id()end
        batch[#batch+1]={before=current,after=row.after}
      end
      self.pending.attempting=true
      local called,success,reason=pcall(self.mechanisms.commit,self.mechanisms,batch,{grid=origin,command=true})
      self.pending.attempting=false
      assert(called,success);assert(success,reason)
      for i=at,math.min(#changes,at+self.batch_size-1)do
        local row=changes[i]
        -- Store-owned values remain journaled even if a notification or a
        -- lifecycle callback invalidates the spatial index immediately after
        -- commit. Never journal a desired value that the store did not accept.
        local saved=row.after and self.session.data.buildings[row.after.id]or nil
        committed[#committed+1]={before=State.clone(row.before),after=State.clone(saved),pos=copy(row.pos)}
      end
      if at+self.batch_size<=#changes then self:_checkpoint(#committed,#changes,'commit')end
    end
  end)
  if not ok then
    local total=#committed;local restored,rollback_error=0,nil
    local reverted,n=self:rollback_pending();if not reverted then rollback_error=n end
    local remaining=self.pending and #self.pending.rows or 0
    restored=total-remaining
    if remaining==0 then self.pending=nil end
    -- A failed rollback keeps its journal available for explicit shutdown
    -- recovery; savepoint publication must remain fenced until resolved.
    local detail='command-block-write-failed:'..tostring(why)..';rolled-back='..restored..';remaining='..remaining
    if rollback_error then detail=detail..';rollback='..tostring(rollback_error)end
    return nil,detail
  end
  self.pending=nil
  return #committed
end
function M:write_blocks(entries)return attempt(M._write,self,entries)end
function M:_write_data(p,value,expected)
    self:_current();p=position(p);local before=assert(self:_record(p),'block-has-no-data')
    assert(self.session.handles[before.id],'command-block-not-restored')
    if expected then
      local a,b=State.clone(before),State.clone(expected)
      local command=(self.registry.get(before.content_id)or {}).command_block
      if command then
        -- A running block changes these fields independently of its command
        -- data. Preserve them unless the NBT operation actually changed one.
        for _,key in ipairs({'success_count','last_output','powered'})do
          a.properties[key]=nil;b.properties[key]=nil
        end
      end
      assert(same(a,b),'command-block-data-changed-before-commit')
      if command then
        local old,current=self:_data(expected),self:_data(before);value=State.clone(value)
        for _,key in ipairs({'SuccessCount','LastOutput'})do
          if equal(value[key],old[key])then value[key]=current[key]end
        end
      end
    end
    local after=self:_apply_data(before,value,true)
    if same(before,after)then return 0 end
    local ok,why=self.mechanisms:commit({{before=before,after=after}},{grid=self:origin(),command=true});assert(ok,why)
    return 1
end
function M:write_block_data(p,value,expected)
  return attempt(function(self,p,value,expected)
    assert(not self.pending and not self.transaction,'command-previous-transaction-pending')
    return self:_write_data(p,value,expected)
  end,self,p,value,expected)
end

-- UE4SS registers each callback Lua state; it need not be Lua's initial main
-- thread. The service explicitly authorizes its current callback state. A step never yields or
-- invokes the legacy checkpoint callback, and touches at most eight records.
-- begin_write_blocks/ begin_write_block_data -> transaction | nil,error.
-- step -> false,nil,progress while pending; true,true,count on success;
-- true,false,error only once failure rollback has finished. A blocked rollback
-- remains pending. cancel is pure; begin_rollback adopts a retained journal.
local function native_context(self)
  if self.options.native_context then
    -- This must be a pure Lua scope/thread check supplied by the service. Never
    -- ask an Unreal function whether an unregistered worker is permitted.
    local called,accepted=pcall(self.options.native_context)
    if not called then return false,'command-world-native-context-check-failed:'..tostring(accepted)end
    return accepted==true,'command-world-native-context-required'
  end
  local _,main=coroutine.running();return main==true,'command-world-main-thread-required'
end
local function earlier(a,b)
  local x=not a.after and 0 or a.before and 1 or 2
  local y=not b.after and 0 or b.before and 1 or 2
  if x~=y then return x<y end
  if a.pos.y~=b.pos.y then return a.pos.y<b.pos.y end
  if a.pos.z~=b.pos.z then return a.pos.z<b.pos.z end
  return a.pos.x<b.pos.x
end
local function heap_push(heap,row)
  local at=#heap+1
  while at>1 do local parent=at//2;if not earlier(row,heap[parent])then break end
    heap[at]=heap[parent];at=parent
  end
  heap[at]=row
end
local function heap_pop(heap)
  local first,last=heap[1],table.remove(heap)
  if #heap>0 then
    local at=1
    while at*2<=#heap do
      local child=at*2;if heap[child+1]and earlier(heap[child+1],heap[child])then child=child+1 end
      if not earlier(heap[child],last)then break end
      heap[at]=heap[child];at=child
    end
    heap[at]=last
  end
  return first
end
local function occupancy()
  return {total=0,cells={},counts={},limits={}}
end
local function add(map,key,n)
  map[key]=(map[key]or 0)+n;if map[key]==0 then map[key]=nil end
end
local function cell(record)return string.pack('<ddd',record.x+0.,record.y+0.,record.z+0.)end
local function tally(self,index,record,n)
  index.total=index.total+n
  if record.world~=self.session.world then return end
  add(index.cells,cell(record),n)
  local definition=self.registry.get(record.content_id)
  if definition then
    local group=definition.group or 'block';add(index.counts,group,n)
    index.limits[group]=index.limits[group]or {};add(index.limits[group],definition.limit or 1024,n)
  end
end
local function iterate(tx,prefix,value)
  tx[prefix..'_iterator'],tx[prefix..'_state'],tx[prefix..'_key']=pairs(value)
end
local function next_row(tx,prefix)
  local key,value=tx[prefix..'_iterator'](tx[prefix..'_state'],tx[prefix..'_key'])
  tx[prefix..'_key']=key;return key,value
end
local function progress(tx)
  return false,nil,{phase=tx.phase,processed=tx.cursor or tx.processed or 0,
    total=tx.total or tx.length or 0,blocked=tx.blocked,remaining=tx.pending and #tx.pending.rows or 0}
end
function M:_finish_transaction(tx,ok,value)
  tx.done=true;tx.success=ok;tx.result=ok and value or nil;tx.error=not ok and tostring(value)or nil
  if self.transaction==tx then self.transaction=nil end
  if self.pending and self.pending==tx.pending and (ok or #self.pending.rows==0)then self.pending=nil end
  return true,ok,value
end
function M:_begin_transaction(kind,entries)
  assert(not self.transaction and not self.pending,'command-previous-transaction-pending')
  assert(type(entries)=='table'and #entries<=16384,'command-block-write-limit:16384')
  local tx={owner=self,kind=kind,entries=entries,length=#entries,phase='shape',count=0,cursor=1,
    map={},order={},changes={},heap={},ignored={},delta=occupancy(),restored=0,committed=0,
    batch_size=math.min(8,self.batch_size)}
  iterate(tx,'shape',entries);self.transaction=tx;return tx
end
function M:begin_write_blocks(entries)
  return attempt(M._begin_transaction,self,'blocks',entries)
end
function M:begin_write_block_data(p,value,expected)
  return attempt(M._begin_transaction,self,'data',{{pos=p,data=value,expected=expected}})
end
function M:cancel(tx,reason)
  if type(tx)~='table'or tx.owner~=self then return false,'command-transaction-owner-mismatch'end
  if tx.done then return true end
  if self.transaction~=tx then return false,'command-transaction-not-active'end
  tx.cancelled=true;tx.error=tx.error or tostring(reason or 'command-cancelled');tx.phase='rollback'
  return true
end
function M:begin_rollback(reason)
  if self.transaction then
    local tx=self.transaction;self:cancel(tx,reason or 'command-cancelled');return tx
  end
  local tx={owner=self,kind='recovery',recovery=true,phase='rollback',restored=0,
    pending=self.pending,batch_size=math.min(8,self.batch_size),error=reason}
  self.transaction=tx;return tx
end
function M:_transaction_failure(tx,why)
  tx.error=tx.error or tostring(why);tx.phase='rollback'
  if tx.pending and #tx.pending.rows>0 then return progress(tx)end
  return self:_finish_transaction(tx,false,tx.error)
end
function M:_step_rollback(tx)
  local pending=tx.pending or self.pending;tx.pending=pending
  if not pending or #pending.rows==0 then
    if tx.recovery then return self:_finish_transaction(tx,true,tx.restored)end
    local why='command-block-write-failed:'..tostring(tx.error or 'command-cancelled')..
      ';rolled-back='..tx.restored..';remaining=0'
    return self:_finish_transaction(tx,false,why)
  end
  if pending.attempting then tx.blocked='command-native-batch-still-active';return progress(tx)end
  local last=#pending.rows;local first=math.max(1,last-tx.batch_size+1);local batch={}
  local called,ok,why=pcall(function()
    if not self:_native_current()then
      assert(self.options.rollback_memory,'command-memory-rollback-unavailable')
      -- The callback reverses its forward journal; preserve forward order here.
      for index=first,last do batch[#batch+1]=State.clone(pending.rows[index])end
      return self.options.rollback_memory(batch,copy(pending.origin))
    end
    self:_current()
    for index=last,first,-1 do
      local row=pending.rows[index];local current=self:_record(row.pos)
      assert(same(current,row.after),'command-block-rollback-state-changed')
      batch[#batch+1]={before=current,after=row.before}
    end
    pending.attempting=true
    local accepted,success,reason=pcall(self.mechanisms.commit,self.mechanisms,batch,
      {grid=pending.origin,command=true,rollback=true})
    pending.attempting=false
    assert(accepted,success);return success,reason
  end)
  if not called or not ok then
    pending.attempting=false;tx.blocked=tostring(not called and ok or why or 'command-rollback-rejected')
    return progress(tx)
  end
  tx.blocked=nil;local count=last-first+1
  for _=1,count do table.remove(pending.rows)end
  tx.restored=tx.restored+count
  if #pending.rows==0 then return self:_step_rollback(tx)end
  return progress(tx)
end
function M:_step_transaction(tx)
  if tx.phase=='rollback'then return self:_step_rollback(tx)end
  if tx.kind=='data'then
    -- One bounded, metadata-only record needs no collision/capacity scan. Keep
    -- read/validate/CAS in this registered callback so repeat output cannot
    -- invalidate a multi-frame preflight before an auto=0 edit can commit.
    local item=tx.entries[1]
    local count=self:_write_data(item.pos,item.data,item.expected)
    return self:_finish_transaction(tx,true,count)
  end
  self:_current()
  tx.origin=tx.origin or self:origin()
  assert(equal(tx.origin,self:origin()),'command-building-grid-changed')
  local size=tx.batch_size
  if tx.phase=='shape'then
    for _=1,size do
      local key=next_row(tx,'shape')
      if key==nil then
        assert(tx.count==tx.length,'command-block-array-required');tx.phase='validate';break
      end
      tx.count=tx.count+1
      assert(type(key)=='number'and key%1==0 and key>=1 and key<=tx.length,'command-block-array-required')
    end
  elseif tx.phase=='validate'then
    for _=1,size do
      local index=tx.cursor;if index>tx.length then tx.phase='collect';tx.cursor=1;tx.entries=nil;break end
      local item=tx.entries[index];assert(type(item)=='table','command-block-entry-required')
      local p=position(item.pos);local key=p.x..':'..p.y..':'..p.z
      local before=self:_record(p);local after
      if tx.kind=='data'then
        assert(before,'block-has-no-data');after=self:_apply_data(before,item.data,true)
      else
        -- Every input is validated, including a later-overwritten clone cell.
        local definition,properties=self:_definition(item.block)
        if definition then
          after=self:_point(p);after.content_id=definition.id;after.world=self.session.world
          after.id=before and before.id or 'command-draft-'..index;after.properties=properties
          if item.block.data~=nil then after=self:_apply_data(after,item.block.data,false)end
        end
      end
      if not tx.map[key]then tx.order[#tx.order+1]=key end
      tx.map[key]={before=State.clone(before),after=after,pos=p};tx.cursor=index+1
    end
  elseif tx.phase=='collect'then
    for _=1,size do
      local key=tx.order[tx.cursor]
      if not key then
        tx.total=#tx.changes;tx.cursor=1
        if tx.total==0 then return self:_finish_transaction(tx,true,0)end
        if tx.capacity_changed then
          tx.base=occupancy();iterate(tx,'base',self.session.data.buildings);tx.phase='base'
        else tx.phase='preflight'end
        break
      end
      local row=tx.map[key]
      if row.before then
        assert(self.session.handles[row.before.id],'command-block-not-restored');tx.ignored[row.before.id]=true
      end
      if not same(row.before,row.after)then
        tx.changes[#tx.changes+1]=row;heap_push(tx.heap,row)
        local a,b=row.before,row.after
        if not(a and b and a.content_id==b.content_id and a.x==b.x and a.y==b.y and a.z==b.z)then
          if a then tally(self,tx.delta,a,-1)end;if b then tally(self,tx.delta,b,1)end
          tx.capacity_changed=true
        end
      end
      tx.cursor=tx.cursor+1
    end
  elseif tx.phase=='base'then
    for _=1,size do
      local key,row=next_row(tx,'base')
      if key==nil then
        assert(tx.base.total+tx.delta.total<=8192,'world-building-capacity')
        iterate(tx,'groups',tx.delta.counts);tx.phase='capacity';break
      end
      tally(self,tx.base,row,1)
    end
  elseif tx.phase=='capacity'then
    for _=1,size do
      local group,increase=next_row(tx,'groups')
      if group==nil then tx.phase='preflight';tx.cursor=1;break end
      if increase>0 then
        local count=(tx.base.counts[group]or 0)+increase
        local old,changed=tx.base.limits[group]or {},tx.delta.limits[group]
        for limit,n in pairs(old)do assert(count<=limit or n+(changed[limit]or 0)<=0,'building-capacity')end
        for limit,n in pairs(changed)do assert(n<=0 or count<=limit,'building-capacity')end
      end
    end
  elseif tx.phase=='preflight'then
    for _=1,size do
      local row=tx.changes[tx.cursor]
      if not row then tx.phase='verify';tx.cursor=1;break end
      if row.after and tx.kind~='data'then
        if tx.base then
          local key=cell(row.after)
          assert((tx.base.cells[key]or 0)+(tx.delta.cells[key]or 0)<=1,'batch-grid-occupied')
        end
        local ok,why=self.build.world:can_place(row.after,tx.ignored,{command=true});assert(ok,why or 'command-block-space-occupied')
      end
      tx.cursor=tx.cursor+1
    end
  elseif tx.phase=='verify'then
    for _=1,size do
      local row=tx.changes[tx.cursor]
      if not row then
        tx.pending={rows={},origin=copy(tx.origin),attempting=false};self.pending=tx.pending
        tx.phase='commit';tx.cursor=0;break
      end
      assert(same(row.before,self:_record(row.pos)),'command-block-changed-during-preflight');tx.cursor=tx.cursor+1
    end
  elseif tx.phase=='commit'then
    local rows,batch={},{}
    for _=1,math.min(size,#tx.heap)do
      local row=heap_pop(tx.heap);local current=self:_record(row.pos)
      assert(same(row.before,current),'command-block-changed-before-commit');row.before=current
      if row.after and not row.before then row.after.id=self.session:next_id()end
      rows[#rows+1]=row;batch[#batch+1]={before=current,after=row.after}
    end
    tx.pending.attempting=true
    local called,ok,why=pcall(self.mechanisms.commit,self.mechanisms,batch,{grid=tx.origin,command=true})
    tx.pending.attempting=false;assert(called,ok);assert(ok,why)
    for _,row in ipairs(rows)do
      local saved=row.after and self.session.data.buildings[row.after.id]or nil
      tx.pending.rows[#tx.pending.rows+1]={before=State.clone(row.before),after=State.clone(saved),pos=copy(row.pos)}
    end
    tx.committed=tx.committed+#rows;tx.cursor=tx.committed
    if tx.cancelled then tx.phase='rollback'
    elseif #tx.heap==0 then return self:_finish_transaction(tx,true,tx.committed)end
  else error('command-transaction-phase-invalid:'..tostring(tx.phase))end
  return progress(tx)
end
function M:step(tx)
  -- Reject misuse before _current or any UObject call, including rollback.
  local permitted,reason=native_context(self)
  if not permitted then return true,false,reason end
  if type(tx)~='table'or tx.owner~=self then return true,false,'command-transaction-owner-mismatch'end
  if tx.done then return true,tx.success,tx.success and tx.result or tx.error end
  if self.transaction~=tx then return true,false,'command-transaction-not-active'end
  local called,done,ok,value=pcall(self._step_transaction,self,tx)
  if called then return done,ok,value end
  return self:_transaction_failure(tx,done)
end
return M
