-- Pure command syntax, team grouping and real mace enchantment state.
-- Java 26.3 EnchantCommand/SpreadPlayersCommand semantics; host owns movement.
local syntax=require('rules.commands.syntax')
local state=require('storage.state')
local M={}
local enchantments={['minecraft:density']={field='density',max=5},
 ['minecraft:breach']={field='breach',max=4},['minecraft:wind_burst']={field='wind_burst',max=3}}
local function finite(n)return type(n)=='number'and n==n and math.abs(n)<math.huge end
function M._enchantment(id,level)
 id=syntax.id(id);local definition=assert(enchantments[id],'enchantment-effect-unavailable:'..id)
 level=syntax.number(level or 1,0,definition.max,true)
 return id,level,definition
end
function M._mace_enchantments(stack)
 assert(stack and not require('rules.native_slot_reference').is(stack),'enchant-native-equipment-unavailable')
 local profile=require('content.combat_profiles').get(stack.content_id)
 assert(profile.kind=='mace','enchantment-incompatible-item')
 local saved=stack.metadata and stack.metadata.command_enchantments
 local result=state.object()
 if saved~=nil then
  assert(type(saved)=='table'and state.json_kind(saved)=='object','invalid-command-enchantments')
  for id,level in pairs(saved)do
   local canonical,n=M._enchantment(id,level)
   assert(canonical==id and n>0,'invalid-command-enchantment-level');result[id]=n
  end
 else
  for id,definition in pairs(enchantments)do
   local level=profile[definition.field]or 0;if level>0 then result[id]=level end
  end
 end
 assert(not(result['minecraft:density']and result['minecraft:breach']),'enchantment-incompatible')
 return result,profile
end
function M._mace_profile(stack)
 local levels,base=M._mace_enchantments(stack)
 local profile={};for k,v in pairs(base)do profile[k]=v end
 for id,definition in pairs(enchantments)do profile[definition.field]=levels[id]or 0 end
 return profile
end
function M._enchant_inventory(containers,id,level)
 id,level=M._enchantment(id,level)
 local slots=require('rules.container_slots');local address='player/hotbar/'..containers.player.selected
 local before=assert(slots.get(containers,address),'enchant-mainhand-empty')
 local levels=M._mace_enchantments(before)
 assert(not levels[id],'enchantment-already-present')
 assert(not(id=='minecraft:density'and levels['minecraft:breach']or id=='minecraft:breach'and levels['minecraft:density']),
  'enchantment-incompatible')
 -- Vanilla accepts level zero, but its mutable enchantment component inserts
 -- no level-zero entry. Existing identical enchantments still reject above.
 if level==0 then return nil,1 end
 levels[id]=level
 local after=state.clone(before);after.content_id='pbzmc:mace'
 after.metadata.command_enchantments=levels
 require('rules.item_stack').validate(after,require('content.items'))
 local draft=slots.edit(containers);draft:set(address,after);return draft.data,1
end
function M.enchant(e,a,c)
 assert(a[1]and a[2]and not a[4],'usage:enchant targets enchantment [level]')
 local id,level=M._enchantment(a[2],a[3]or 1)
 local targets=e:select(a[1],c);assert(#targets>0,'no-entities-found');e:spend()
 return e:call('enchant_items',targets,id,level)
end
function M.spreadplayers(e,a,c)
 assert(a[1]and a[2]and a[3]and a[4],'usage:spreadplayers center spreadDistance maxRange [under maxHeight] respectTeams targets')
 assert(a[1]:sub(1,1)~='^'and a[2]:sub(1,1)~='^','spreadplayers-local-coordinates-unavailable')
 local p=syntax.position({a[1],'0',a[2]},1,c,true)
 local distance=syntax.number(a[3],0,30000000);local range=syntax.number(a[4],1,30000000)
 local index,max_height=5
 if a[index]=='under'then max_height=syntax.number(a[index+1],-30000000,30000000,true);index=index+2 end
 assert(a[index]=='true'or a[index]=='false','spreadplayers-respectTeams-boolean-required')
 assert(a[index+1]and not a[index+2],'spreadplayers-targets-required')
 assert(math.abs(p.x)+range<=30000000 and math.abs(p.z)+range<=30000000,'coordinate-out-of-range')
 local targets=e:select(a[index+1],c);assert(#targets>0,'no-entities-found');e:spend()
 return e:call('spread_players',{targets=targets,center={x=p.x,z=p.z},distance=distance,range=range,
  max_height=max_height,respect_teams=a[index]=='true'})
end
function M._spread_groups(request,limit)
 assert(type(request)=='table'and type(request.targets)=='table','invalid-spread-request')
 assert(#request.targets>0 and #request.targets<=(limit or 128),'spreadplayers-target-limit')
 assert(type(request.center)=='table'and finite(request.center.x)and finite(request.center.z),'invalid-spread-center')
 assert(finite(request.distance)and request.distance>=0 and finite(request.range)and request.range>=1,'invalid-spread-range')
 assert(math.abs(request.center.x)+request.range<=30000000 and math.abs(request.center.z)+request.range<=30000000,'coordinate-out-of-range')
 assert(type(request.respect_teams)=='boolean','invalid-spread-teams')
 assert(request.max_height==nil or finite(request.max_height)and request.max_height%1==0
  and math.abs(request.max_height)<=30000000,'invalid-spread-height')
 local groups,by_key,entries,seen={},{},{},{}
 for i,target in ipairs(request.targets)do
  assert(type(target)=='table'and type(target.id)=='string'and not seen[target.id],'invalid-spread-target')
  assert(target.alive~=false,'spreadplayers-target-dead');seen[target.id]=true
  -- Vanilla only players carry a team here. Every other entity and unteamed
  -- player share the null group when respectTeams is enabled.
  local key=request.respect_teams and(target.player and target.team and 'team:'..target.team or 'no-team')or 'entity:'..target.id
  local group=by_key[key]
  if not group then group={members={},radius=0,half=0};groups[#groups+1]=group;group.index=#groups;by_key[key]=group end
  local row={entity=target,group=group};entries[i]=row;group.members[#group.members+1]=row
 end
 return groups,entries
end
function M._spread_point(request,groups,index,random)
 local function unit()local n=random();assert(finite(n)and n>=0 and n<1,'invalid-spread-random');return n end
 local p={x=math.floor(request.center.x-request.range+unit()*request.range*2)+.5,
  z=math.floor(request.center.z-request.range+unit()*request.range*2)+.5}
 if math.abs(p.x-request.center.x)>request.range or math.abs(p.z-request.center.z)>request.range then return nil end
 for i=1,index-1 do
  local q=groups[i].pos
  local minimum=math.max(request.distance,(groups[i].radius+groups[index].radius+6)/100)
  if q and (p.x-q.x)^2+(p.z-q.z)^2<minimum^2 then return nil end
 end
 return p
end
return M
