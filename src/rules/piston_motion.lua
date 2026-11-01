-- Pure placement transaction plans. Host collision/storage commits stay outside.
local D=require('rules.block_directions')
local M={MAX_PUSH=12,DURATION_TICKS=2}
local fragile={wire=true,torch=true,repeater=true,comparator=true,lever=true,door=true,water=true,lava=true}
local immovable={piston_head=true,moving_piston=true,ender_chest=true,obsidian=true,bedrock=true}
local function copypos(n) return {x=n.x,y=n.y,z=n.z} end
local function kind(n)
 local k=n.kind or ((n.content_id or ''):match(':(.+)$')) or 'solid'
 if k:match('_door$') then return 'door' end
 return ({redstone='wire',redstone_wire='wire',redstone_torch='torch',redstone_wall_torch='torch'})[k] or k
end
function M.reaction(n)
 if not n or n.air or n.kind=='air' then return 'air' end
 local p=n.properties or {};local k=kind(n)
 if n.moving or n.native_terrain or n.block_entity or p.block_entity or n.hardness==-1 or immovable[k]
  or ((k=='piston' or k=='sticky_piston') and p.extended) then return 'block' end
 local r=n.push_reaction or p.push_reaction
 if r then
  local aliases={normal='normal',push_pull='normal',PUSH_PULL='normal',block='block',
   immovable='block',IMMOVEABLE='block',destroy='destroy',popped='destroy',POPPED='destroy',
   push_only='push_only',PUSH='push_only'}
  return aliases[r] or 'block'
 end
 if fragile[k] then return 'destroy' end
 return 'normal'
end
function M.sticky(n)
 local k=n and kind(n)
 return k=='slime_block' and 'slime' or k=='honey_block' and 'honey' or nil
end
function M.sticks(a,b)
 local x,y=M.sticky(a),M.sticky(b)
 return (x~=nil or y~=nil) and not (x and y and x~=y)
end
-- read(x,y,z) returns a stable record (or nil for air). can_move is optional
-- host preflight; it receives record, destination, movement direction, plan.
-- A false return rejects the *entire* extension. Never mutates read records.
function M.plan(piston,extending,read,options)
 options=options or {};assert(type(read)=='function','read callback required')
 assert(type(extending)=='boolean','boolean extension required')
 D.key(piston.x,piston.y,piston.z)
 local p=piston.properties or {};local facing=p.facing or piston.facing or 'north'
 assert(D.valid(facing),'invalid piston facing')
 local front=D.step(piston,facing);local direction=extending and facing or D.opposite(facing)
 local plan={id=piston.id,extend=extending,direction=facing,movement=direction,moves={},destroy={},
  head={action=extending and 'create' or 'remove',x=front.x,y=front.y,z=front.z,
   facing=facing,sticky=kind(piston)=='sticky_piston',owner=piston.id},
  properties={extended=extending},duration_ticks=M.DURATION_TICKS}
 if (p.extended==true)==extending then plan.unchanged=true;plan.head.action='none';return plan end
 local function at(pos)
  local n=read(pos.x,pos.y,pos.z)
  if not extending and pos.x==front.x and pos.y==front.y and pos.z==front.z and n
   and kind(n)=='piston_head' and ((n.properties or {}).owner==piston.id or n.owner==piston.id)then return nil end
  return n
 end
 local function within(pos)
  return (not options.min_z or pos.z>=options.min_z) and (not options.max_z or pos.z<=options.max_z)
   and (not options.within_bounds or options.within_bounds(pos))
 end
 local function move(n,to)
  if not within(to) then return false,'world-boundary' end
  if options.can_move and not options.can_move(n,to,extending and facing or D.opposite(facing),plan) then
   return false,'collision-blocked'
  end
  plan.moves[#plan.moves+1]={id=n.id,from=copypos(n),to=to}
  return true
 end
 if not extending and (kind(piston)~='sticky_piston' or options.drop_pull)then return plan end
 local start=extending and front or D.step(piston,facing,2)
 if not extending then
  local target,destination=at(start),at(front)
  -- Native geometry queries are asynchronous. Unknown is neither air nor a
  -- proven immovable block; postponing the event preserves sticky pulling.
  if target and target.pending or destination and destination.pending then return nil,'terrain-pending'end
  if M.reaction(target)~='normal' or M.reaction(destination)~='air'then return plan end
 end
 local selected,ordered,destroyed={},{},{}
 -- Dependencies are monotone and capped at 12. Sticky neighbours attach only
 -- when movable; immovable side supports stay in place. A blocked destination
 -- rejects the whole assembly. Honey and slime never attach to each other.
 local function add(pos,attachment,incoming)
  if not within(pos)then return false,'world-boundary'end
  local n=at(pos);local reaction=M.reaction(n)
  if reaction=='air'then return true end
  local isbase=pos.x==piston.x and pos.y==piston.y and pos.z==piston.z
  if attachment and (isbase or reaction=='block' or reaction=='destroy' or reaction=='push_only' and incoming~=direction)then return true end
  if isbase or reaction=='block'then return false,n and n.pending and 'terrain-pending' or n and n.moving and 'moving-block' or 'immovable'end
  if not n.id then return false,'missing-block-identity'end
  if reaction=='destroy'then
   if not destroyed[n.id]then
    if options.can_destroy and not options.can_destroy(n,plan)then return false,'destroy-blocked'end
    destroyed[n.id]=true;plan.destroy[#plan.destroy+1]={id=n.id,at=copypos(pos)}
   end
   return true
  end
  if selected[n.id]then return true end
  if #ordered>=M.MAX_PUSH then return false,'push-limit'end
  selected[n.id]=n;ordered[#ordered+1]=n;return true
 end
 local ok,reason=add(start,false,direction)
 local index=1
 while ok and index<=#ordered do
  local n=ordered[index];index=index+1
  ok,reason=add(D.step(n,direction),false,direction)
  if ok and M.sticky(n)then
   for _,d in ipairs(D.order)do
    if d~=direction then
     local pos=D.step(n,d);local other=at(pos)
     if other and M.sticks(n,other)then ok,reason=add(pos,true,d);if not ok then break end end
    end
   end
  end
 end
 if ok then
  local v=D.vectors[direction]
  table.sort(ordered,function(a,b)
   local da,db=a.x*v.x+a.y*v.y+a.z*v.z,b.x*v.x+b.y*v.y+b.z*v.z
   if da~=db then return da>db end
   return D.key(a.x,a.y,a.z)<D.key(b.x,b.y,b.z)
  end)
  for _,n in ipairs(ordered)do ok,reason=move(n,D.step(n,direction));if not ok then break end end
 end
 if not ok then
  if extending or reason=='terrain-pending'then return nil,reason end
  -- A sticky pull can fail without retaining the extended head or destroying
  -- anything. This matches MC's ordinary inability to pull a blocked assembly.
  plan.moves={};plan.destroy={};plan.pull_blocked=true;plan.pull_reason=reason
 end
 if extending and options.can_head and not options.can_head(front,plan)then return nil,'head-blocked'end
 return plan
end
return M
