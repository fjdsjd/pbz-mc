local syntax=require('rules.commands.syntax')
local M={}
local function targets(engine,raw,context)
 local found=engine:select(raw or '@s',context);assert(#found>0,'no-entities-found');return found
end
function M.kill(e,a,c)
 assert(#a<=1,'usage:kill [targets]');local found=targets(e,a[1],c)
 for _,t in ipairs(found)do e:spend();e:mutate('kill',t)end
 return #found
end
function M.damage(e,a,c)
 local t=e:select(assert(a[1],'damage-target-required'),c,true)[1]
 local amount=syntax.number(a[2],0,1e9);local kind=a[3] and syntax.id(a[3]) or 'minecraft:generic'
 local source
 if a[4] then
  assert(a[4]=='by','unsupported-damage-source-clause');source=e:select(a[5],c,true)[1]
  assert(not a[6],'unsupported-damage-cause-clause')
 end
 e:mutate('damage',t,amount,kind,source);return 1
end
local function angle(raw,base)
 return raw:sub(1,1)=='~' and (base or 0)+(raw:sub(2)=='' and 0 or syntax.number(raw:sub(2))) or syntax.number(raw)
end
local function coordinate(raw)return raw and (raw:sub(1,1)=='~'or raw:sub(1,1)=='^'or tonumber(raw)~=nil)end
function M.teleport(e,a,c)
 assert(#a>=1,'teleport-destination-required');local found,index
 if #a==1 or #a>=3 and coordinate(a[1])then found=targets(e,'@s',c);index=1
 else found=targets(e,a[1],c);index=2 end
 local position,next_index,yaw,pitch
 if coordinate(a[index])and #a-index>=2 then position,next_index=syntax.position(a,index,c,true)
 else
  local destination=e:select(assert(a[index],'missing-destination'),c,true)[1]
  position=destination.pos;yaw=destination.yaw;pitch=destination.pitch;next_index=index+1
 end
 if a[next_index]=='facing'then
  local p
  if a[next_index+1]=='entity'then
   local t=e:select(a[next_index+2],c,true)[1];p={x=t.pos.x,y=t.pos.y,z=t.pos.z}
   local anchor=a[next_index+3]
   assert((not anchor or anchor=='eyes'or anchor=='feet')and not a[next_index+4],'invalid-teleport-facing-anchor')
   if anchor=='eyes'then p.y=p.y+(t.height or 1.8)*.9 end
  else local stop;p,stop=syntax.position(a,next_index+1,c);assert(not a[stop],'teleport-extra-arguments')end
  local dx,dy,dz=p.x-position.x,p.y-position.y,p.z-position.z
  yaw=math.deg(math.atan(-dx,dz));pitch=-math.deg(math.atan(dy,math.sqrt(dx*dx+dz*dz)))
 elseif a[next_index]then
  yaw=angle(a[next_index],c.yaw);pitch=angle(assert(a[next_index+1],'missing-pitch'),c.pitch)
  assert(not a[next_index+2],'teleport-extra-arguments')
 end
 for _,t in ipairs(found)do e:spend();e:mutate('teleport',t,position,yaw,pitch)end
 return #found
end
function M.rotate(e,a,c)
 local found=targets(e,a[1],c);assert(a[2] and a[3] and not a[4],'usage:rotate targets yaw pitch')
 for _,t in ipairs(found)do e:spend();e:mutate('teleport',t,t.pos,angle(a[2],c.yaw),angle(a[3],c.pitch))end
 return #found
end
function M.summon(e,a,c)
 local id=syntax.id((assert(a[1],'summon-id-required')));local pos,index=c.pos,2
 if a[2] and a[2]:sub(1,1)~='{'then pos,index=syntax.position(a,2,c,true)end
 local nbt=a[index] and syntax.snbt(a[index]) or {};assert(not a[index+1],'summon-extra-arguments')
 assert(type(nbt)=='table'and require('storage.state').json_kind(nbt)=='object','summon-nbt-compound-required')
 local entity,why=e.host.entities:summon(id,pos,nbt);assert(entity,why)
 return 1, '已召唤 '..(entity.name or id)
end
function M.effect(e,a,c)
 local action=table.remove(a,1);assert(action=='give' or action=='clear','usage:effect give|clear')
 local found=targets(e,a[1] or '@s',c);local id=a[2] and syntax.id(a[2]):gsub('^minecraft:','')
 if action=='clear'then
  assert(not a[3],'effect-extra-arguments');for _,t in ipairs(found)do e:spend();e:mutate('clear_effect',t,id)end
 else
  assert(id,'effect-id-required');local duration=a[3]=='infinite' and 2147483647 or syntax.number(a[3] or 30,0,1000000,true)*20
  local level=syntax.number(a[4] or 0,0,255,true);assert(not a[6] and (not a[5] or a[5]=='true' or a[5]=='false'),'effect-extra-arguments')
  for _,t in ipairs(found)do e:spend();e:mutate('effect',t,id,duration,level,a[5]=='true')end
 end
 return #found
end
function M.attribute(e,a,c)
 local target=e:select(a[1],c,true)[1];local id=syntax.id(a[2]);local operation=a[3];local index=4
 if operation=='base'then operation='base_'..tostring(a[4]);index=5 end
 assert(operation=='get' or operation=='base_get' or operation=='base_set','attribute-operation-unavailable')
 local value=a[index] and syntax.number(a[index]) or nil;assert(not a[index+1],'attribute-extra-arguments')
 assert(operation~='base_set'or value~=nil,'attribute-value-required')
 local result,why=e.host.entities:attribute(target,id,operation,operation=='base_set'and value or nil)
 assert(result~=nil and result~=false,why)
 if operation~='base_set'then assert(type(result)=='number','attribute-value-unavailable');return math.floor(result*(value or 1)),nil,true end
 return 1
end
function M.tag(e,a,c)
 local found=targets(e,a[1],c);local action=a[2];assert(action=='add' or action=='remove' or action=='list','invalid-tag-action')
 if action=='list'then
  assert(not a[3],'tag-extra-arguments')
  local set={};for _,t in ipairs(found)do for tag in pairs(t.tags)do set[tag]=true end end
  local names={};for name in pairs(set)do names[#names+1]=name end;table.sort(names);return #names,table.concat(names,', ')
 end
 local tag=syntax.string(assert(a[3],'tag-required'));assert(#tag>0 and #tag<=256 and not a[4],'invalid-tag')
 local count=e:edit(function(s)
  local changed=0
  for _,t in ipairs(found)do
   local tags=s.tags[t.id] or {};s.tags[t.id]=tags
   if action=='add' and not tags[tag]then tags[tag]=true;changed=changed+1
   elseif action=='remove' and tags[tag]then tags[tag]=nil;changed=changed+1 end
  end
  return changed
 end)
 return count
end
function M.ride(e,a,c)
 local passenger=e:select(a[1],c,true)[1]
 if a[2]=='dismount'then assert(not a[3],'ride-extra-arguments');e:mutate('dismount',passenger)
 else assert(a[2]=='mount' and not a[4],'usage:ride target mount vehicle');e:mutate('mount',passenger,e:select(a[3],c,true)[1])end
 return 1
end
return M
