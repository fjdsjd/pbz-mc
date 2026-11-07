-- Registered-callback host operations for enchant and safe entity scattering.
-- A transaction step handles one entity or one bounded terrain query. Its
-- journal remains owned until commit/rollback; plain Lua workers never use UE.
local rules=require('rules.commands.gameplay')
local M={};M.__index=M
local function finite(n)return type(n)=='number'and n==n and math.abs(n)<math.huge end
local function copy(p)return {x=p.x,y=p.y,z=p.z}end
local function message(why)return tostring(why):gsub('^.-%.lua:%d+:%s*','')end
local function probe(binding,ignored)
 local query=require('host.pbz.chorus_world').new(binding)
 local valid=require('host.pbz.appearance').valid
 local color={R=0,G=0,B=0,A=0};local types={};for i=0,31 do types[#types+1]=i end
 local function v(x,y,z)return {X=x,Y=y,Z=z}end
 -- Reuse the chorus support classifier and five-point verification, changing
 -- only the ignored actors. Ignoring the player for a native NPC would let
 -- that NPC land inside the player. Selected actors are vacated by this job.
 function query:column(x,y,top,bottom,budget,cursor)
  assert(binding:is_current(),'spreadplayers-world-changed')
  local z=cursor or top;local result={surfaces={},cost=0,complete=false}
  while result.cost<math.min(2,budget)do
   if z<=bottom then result.complete=true;break end
   local hit={};local yes=self.kismet:LineTraceSingle(binding.actor,v(x,y,z),v(x,y,bottom),0,false,ignored,0,hit,false,color,color,0)
   self.report.queries=self.report.queries+1;result.cost=result.cost+1
   if not yes then result.complete=true;break end
   local ok,c=pcall(function()return hit.Component:Get()end)
   c=ok and valid(c)and c or nil
   local p,n=hit.ImpactPoint,hit.ImpactNormal
   assert(p and n and finite(p.Z)and finite(n.Z),'spreadplayers-invalid-floor-hit')
   local starting=not finite(hit.Time)or hit.Time<=1e-6
   if not starting and p.Z<=z+.1 and p.Z>=bottom then
    result.surfaces[#result.surfaces+1]={z=p.Z,normal_z=n.Z,kind=self:ground_kind(c)}
   end
   z=math.min(z-(starting and 32 or 2),p.Z-2)
  end
  if z<=bottom then result.complete=true end
  if not result.complete then result.cursor=z end
  result.cost=math.max(1,result.cost);return result
 end
 function query:clear(position,radius,half)
  assert(binding:is_current(),'spreadplayers-world-changed')
  local p=v(position.x,position.y,position.z);local hit,out={},{}
  local blocked=self.kismet:CapsuleTraceSingle(binding.actor,v(p.X,p.Y,p.Z+2),p,radius,half,
   0,false,ignored,0,hit,false,color,color,0)
  self.kismet:CapsuleOverlapComponents(binding.actor,p,radius,half,types,self.primitive,ignored,out)
  self.report.queries=self.report.queries+2
  for _,wrapped in ipairs(out)do
   local c=wrapped;if not c.GetFullName then c=c:get()end
   if not valid(c)then blocked=true;break end
   local owner=c:GetOwner()
   if c:GetCollisionResponseToChannel(2)==2 or valid(owner)and(owner:IsA(self.pawn_class)
    or valid(self.volume_class)and owner:IsA(self.volume_class)and owner.bWaterVolume)then blocked=true;break end
  end
  return not blocked,2
 end
 return query
end
function M.new(binding,entities,options)
 options=options or {};assert(type(options.origin)=='function','spreadplayers-origin-required')
 assert(options.native_context==nil or type(options.native_context)=='function','invalid-command-native-context')
 return setmetatable({binding=binding,entities=entities,options=options},M)
end
function M:_native()
 if self.options.native_context then
  local ok,value=pcall(self.options.native_context)
  assert(ok,'command-gameplay-native-context-check-failed:'..tostring(value))
  assert(value==true,'command-gameplay-native-context-required')
 else local _,main=coroutine.running();assert(main,'command-gameplay-main-thread-required')end
end
function M:has_pending_mutations()return self.transaction~=nil and #self.transaction.journal>0 end
function M:begin_spread(request)
 local ok,value=pcall(function()
  assert(not self.closed and not self.transaction,'command-gameplay-transaction-busy')
  local groups,entries=rules._spread_groups(request,self.options.max_targets or 128)
  local tx={owner=self,request=request,groups=groups,entries=entries,ignored={},journal={},
   phase='prepare',index=1,group_index=1,attempts=0,queries=0,moved=0,rollback_errors={}}
  self.transaction=tx;return tx
 end)
 return ok and value or nil,not ok and message(value)or nil
end
function M:cancel(tx,why)
 assert(tx and tx.owner==self,'invalid-spread-transaction')
 if not tx.done then tx.cancelled=why or 'spreadplayers-cancelled' end
 return true
end
function M:begin_rollback(why)
 local tx=self.transaction;if not tx then return nil,'spreadplayers-no-pending-transaction'end
 self:cancel(tx,why or 'spreadplayers-cancelled');return tx
end
function M:_finish(tx,ok,value)
 assert(#tx.journal==0,'spreadplayers-journal-not-resolved')
 tx.done=true;tx.ok=ok;tx.value=value;tx.phase='done'
 self.last={success=ok,value=value,moved=tx.moved,groups=#tx.groups,attempts=tx.attempts,queries=tx.queries,
  rollback_errors=tx.rollback_errors,height_min=tx.height_min,height_max=tx.height_max}
 if self.transaction==tx then self.transaction=nil end
 tx.probe=nil;tx.ignored=nil
 return true,ok,value
end
function M:_failure(tx,why)
 if tx.phase=='rollback'and #tx.journal>0 then
  tx.blocked=message(why);return false,nil,{phase='rollback',error=tx.blocked,remaining=#tx.journal}
 end
 tx.error=tx.error or message(why);tx.phase='rollback';tx.blocked=nil
 if #tx.journal==0 then return self:_finish(tx,false,tx.error)end
 return false,nil,{phase='rollback',remaining=#tx.journal}
end
function M:_verify(tx,row,position)
 local p=self.entities:_ue(position,row.half)
 local ok,why=tx.probe:verify({x=p.X,y=p.Y,z=p.Z},row.radius+3,row.half+3)
 tx.queries=tx.probe.report and tx.probe.report.queries or tx.queries
 assert(tx.queries<=(self.options.max_queries or 32768),'spreadplayers-terrain-query-budget')
 return ok,why
end
function M:_surface(tx)
 local group=tx.groups[tx.group_index]
 while tx.surface_index<=#tx.surfaces do
  local surface=tx.surfaces[tx.surface_index];tx.surface_index=tx.surface_index+1
  if surface.kind=='static'and surface.normal_z>=.97 then
   local y=.5+(surface.z+6-tx.origin.z)/100
   if y<=tx.height_max then
    tx.candidate.y=y;tx.phase='verify';return
   end
  end
 end
 tx.phase=tx.column_complete and 'candidate'or 'column'
 if tx.phase=='candidate'then tx.cursor=nil;tx.candidate=nil end
end
function M:_step(tx)
 if tx.done then return true,tx.ok,tx.value end
 assert(self.transaction==tx,'spreadplayers-transaction-retired')
 if not self.binding:is_current()then
  -- Positions only belong to this retired world; no profile value or native
  -- pointer is persisted. Never call an old actor after its binding retires.
  if #tx.journal>0 then tx.rollback_errors[#tx.rollback_errors+1]='spreadplayers-rollback-world-retired' end
  tx.journal={};return self:_finish(tx,false,(tx.error or tx.cancelled or 'spreadplayers-world-changed')
   ..(#tx.rollback_errors>0 and '; spreadplayers-rollback-world-retired'or ''))
 end
 if tx.cancelled and tx.phase~='rollback'then return self:_failure(tx,tx.cancelled)end
 if tx.phase=='rollback'then
  local row=tx.journal[#tx.journal]
  if not row then return self:_finish(tx,false,tx.error or tx.cancelled or 'spreadplayers-cancelled')end
  local resolved,h=pcall(self.entities._resolve,self.entities,row.entity)
  if not resolved then
   local why=message(h)
   if not(why:find('command-entity-stale',1,true)or why:find('command-summon-retired',1,true)
    or why:find('command-boat-retired',1,true))then
    tx.blocked=why;return false,nil,{phase='rollback',error=why,remaining=#tx.journal}
   end
   -- A destroyed actor has no position to restore. Record the incomplete
   -- restoration explicitly and release only this vanished actor's row.
   tx.rollback_errors[#tx.rollback_errors+1]=why;table.remove(tx.journal)
  else
   local ok,why=self.entities:teleport(row.entity,row.before.pos,row.before.yaw,row.before.pitch)
   if not ok then tx.blocked=message(why);return false,nil,{phase='rollback',error=tx.blocked,remaining=#tx.journal}end
   tx.blocked=nil;table.remove(tx.journal)
  end
  if #tx.journal==0 then
   local why=tx.error or tx.cancelled or 'spreadplayers-cancelled'
   if #tx.rollback_errors>0 then why=why..'; spreadplayers-rollback-incomplete:'..table.concat(tx.rollback_errors,';')end
   return self:_finish(tx,false,why)
  end
 elseif tx.phase=='prepare'then
  local row=tx.entries[tx.index]
  local h=self.entities:_resolve(row.entity);assert(h.kind~='boat','spreadplayers-boat-shape-unavailable')
  local current=self.entities:_descriptor(h);assert(current.alive,'spreadplayers-target-dead')
  local half,radius=self.entities:_dimensions(h)
  assert(finite(half)and finite(radius)and half>=radius and radius>0,'spreadplayers-capsule-required')
  row.half,row.radius=half,radius;tx.ignored[#tx.ignored+1]=h.actor
  row.group.half=math.max(row.group.half,half);row.group.radius=math.max(row.group.radius,radius)
  tx.lowest=math.min(tx.lowest or current.pos.y,current.pos.y);tx.highest=math.max(tx.highest or current.pos.y,current.pos.y)
  tx.index=tx.index+1;if tx.index>#tx.entries then tx.phase='bounds'end
 elseif tx.phase=='bounds'then
  tx.origin=self.options.origin();assert(tx.origin and finite(tx.origin.x)and finite(tx.origin.y)and finite(tx.origin.z),'spreadplayers-origin-unavailable')
  local lower,upper
  if self.options.height_bounds then lower,upper=self.options.height_bounds()end
  -- PBZ has no MC dimension build-height registry. Search the loaded scene
  -- around its selected actors; the caller may supply verified level bounds.
  upper=tx.request.max_height or upper or tx.highest+128
  lower=lower or math.min(tx.lowest,upper)-512
  assert(finite(lower)and finite(upper)and lower<upper and math.abs(lower)<=30000000 and math.abs(upper)<=30000000,
   'spreadplayers-invalid-height-window')
  tx.height_min,tx.height_max=lower,upper
  tx.probe=(self.options.probe_factory or probe)(self.binding,tx.ignored)
  tx.phase='candidate'
 elseif tx.phase=='candidate'then
  for _=1,8 do
   tx.attempts=tx.attempts+1
   assert(tx.attempts<=(self.options.max_attempts or 4096),'spreadplayers-no-safe-spread-within-budget')
   local p=rules._spread_point(tx.request,tx.groups,tx.group_index,self.options.random or math.random)
   if p then tx.candidate=p;tx.phase='column';tx.cursor=nil;tx.columns=0;break end
  end
 elseif tx.phase=='column'then
  tx.columns=tx.columns+1
  if tx.columns>64 then tx.phase='candidate';tx.candidate=nil;tx.cursor=nil;return false,nil,{phase='candidate'}end
  local p=self.entities:_ue({x=tx.candidate.x,y=0,z=tx.candidate.z},0)
  local top=tx.origin.z+(tx.height_max-.5)*100;local bottom=tx.origin.z+(tx.height_min-.5)*100
  local result=tx.probe:column(p.X,p.Y,top,bottom,2,tx.cursor)
  tx.queries=tx.probe.report and tx.probe.report.queries or tx.queries
  assert(tx.queries<=(self.options.max_queries or 32768),'spreadplayers-terrain-query-budget')
  tx.cursor=result.cursor;tx.column_complete=result.complete;tx.surfaces=result.surfaces;tx.surface_index=1
  self:_surface(tx)
 elseif tx.phase=='verify'then
  local group=tx.groups[tx.group_index]
  local good=self:_verify(tx,group,tx.candidate)
  if good then
   group.pos=copy(tx.candidate);tx.candidate=nil;tx.cursor=nil;tx.group_index=tx.group_index+1
   if tx.group_index>#tx.groups then tx.phase='preflight';tx.index=1 else tx.phase='candidate'end
  else self:_surface(tx)end
 elseif tx.phase=='preflight'then
  local row=tx.entries[tx.index];local h=self.entities:_resolve(row.entity)
  local half,radius=self.entities:_dimensions(h)
  assert(half==row.half and radius==row.radius and self.entities:_descriptor(h).alive,'spreadplayers-target-changed')
  local good,why=self:_verify(tx,row,row.group.pos);assert(good,why or 'spreadplayers-destination-changed')
  tx.index=tx.index+1;if tx.index>#tx.entries then tx.phase='commit';tx.index=1 end
 elseif tx.phase=='commit'then
  local row=tx.entries[tx.index];local h=self.entities:_resolve(row.entity)
  local before=self.entities:_descriptor(h);assert(before.alive,'spreadplayers-target-dead')
  local half,radius=self.entities:_dimensions(h);assert(half==row.half and radius==row.radius,'spreadplayers-target-changed')
  local good,why=self:_verify(tx,row,row.group.pos);assert(good,why or 'spreadplayers-destination-changed')
  -- Journal before calling the adapter, including a rare failure after native
  -- movement but before its final readback/AI-home update.
  tx.journal[#tx.journal+1]={entity=row.entity,before={pos=copy(before.pos),yaw=before.yaw,pitch=before.pitch}}
  local ok,value=self.entities:teleport(row.entity,row.group.pos,before.yaw,before.pitch);assert(ok,value)
  tx.moved=tx.moved+1;tx.index=tx.index+1
  if tx.index>#tx.entries then tx.journal={};return self:_finish(tx,true,#tx.groups)end
 else error('invalid-spreadplayers-phase:'..tostring(tx.phase))end
 return false,nil,{phase=tx.phase,moved=tx.moved,attempts=tx.attempts,queries=tx.queries}
end
function M:step(tx)
 assert(tx and tx.owner==self,'invalid-spread-transaction');self:_native()
 local result=table.pack(pcall(self._step,self,tx))
 if not result[1]then return self:_failure(tx,result[2])end
 return table.unpack(result,2,result.n)
end
function M:enchant_items(targets,id,level)
 self:_native();assert(self.binding:is_current(),'command-gameplay-world-changed')
 id,level=rules._enchantment(id,level)
 local player
 for _,target in ipairs(targets)do if target.player then
  local h=self.entities:_resolve(target);assert(h.player,'enchant-player-identity-required');player=target;break
 end end
 assert(player,#targets==1 and 'enchant-entity-equipment-unavailable'or 'enchant-no-supported-mainhand')
 return require('host.pbz.campaign_inventory').command_items(self.binding,
  function(containers)return rules._enchant_inventory(containers,id,level)end)
end
function M:close()
 if self.transaction then self:cancel(self.transaction,'command-gameplay-closing');return false,'command-gameplay-rollback-pending'end
 self.closed=true;return true
end
return M
