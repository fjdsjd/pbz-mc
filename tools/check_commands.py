"""Run command rules, memory transactions and logical-tick scheduling without PBZ.

Uses an installed lupa.lua54, or the repository's existing build/lua-check copy.
Native entity/world operations are explicit mocks; these checks do not establish
native damage, collision, rendering, UI or packaged-install acceptance.
"""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
try:
    from lupa.lua54 import LuaRuntime
except ModuleNotFoundError:
    sys.path.insert(0, str(ROOT / "build/lua-check"))
    try:
        from lupa.lua54 import LuaRuntime
    except ModuleNotFoundError as error:
        raise SystemExit("Lua 5.4 binding required: install lupa or provide build/lua-check/lupa") from error

lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute("local root=...;package.path=root..'/src/?.lua;'..root..'/third_party/dkjson/?.lua;'..package.path", ROOT.as_posix())
lua.execute(r'''
local Engine=require('rules.commands.engine')
local Syntax=require('rules.commands.syntax')
local Select=require('rules.commands.selectors')
local Items=require('content.items')
local Slots=require('rules.container_slots')
local Native=require('rules.native_slot_reference')
local Inventory=require('rules.commands.inventory')
local State=require('storage.state')
local Encode=require('storage.canonical_json')
local PlayerStore=require('storage.player_store')
local Scheduler=require('rules.command_blocks')
local passed=0
local function test(name,fn)local ok,why=pcall(fn);assert(ok,name..': '..tostring(why));passed=passed+1;print('PASS '..name)end
local function near(a,b)assert(math.abs(a-b)<1e-8,tostring(a)..' != '..tostring(b))end
local function ok(result)assert(result.success,result.error or result.message);return result end
local function bad(result,fragment)
 assert(not result.success,'unexpected success: '..tostring(result.message))
 if fragment then assert((result.error or result.message):find(fragment,1,true),tostring(result.error or result.message))end
 return result
end
local function p(x,y,z)return {x=x,y=y,z=z}end
local function key(pos)return string.format('%g:%g:%g',pos.x,pos.y,pos.z)end
local function commands()return State.object({scores={},objectives={},teams={},members={},tags={},storage={},rules={}})end
local function fixture()
 local durable=setmetatable({loaded=true,read_only=false,core=require('storage.player_state').empty(),
  head={pages={}},generation=0,definitions=Items,disk_commits=0},{__index=PlayerStore})
 durable.core.commands=commands()
 function durable:commit(ticket,data)
  self:validate_ownership(data,self.head.pages,ticket.pages);self.core=State.clone(data)
  self.generation=self.generation+1;self.disk_commits=self.disk_commits+1;return true
 end
 local session=require('storage.session_store').new(durable)
 local rows={
  {id='player',type='minecraft:player',name='Steve',player=true,alive=true,pos=p(0,64,0),yaw=0,pitch=0,height=1.8,radius=.3,data={Health=20}},
  {id='zombie',type='minecraft:zombie',name='Zombie',alive=true,pos=p(2,64,0),yaw=175,pitch=10,height=1.8,radius=.3,data={Health=20}},
  {id='native',type='pbz:bp_neutral_c',name='Native',alive=true,pos=p(-3,64,0),yaw=-175,pitch=-10,height=2,radius=.5,data={Health=500}},
  {id='cow',type='minecraft:cow',name='Cow',alive=true,pos=p(10,64,0),yaw=0,pitch=0,height=1.3,radius=.5,data={Health=20}},
  {id='dead',type='minecraft:zombie',name='Dead',alive=false,pos=p(1,64,0),yaw=0,pitch=0,height=1.8,radius=.3,data={Health=0}},
 }
 local host={session=session,durable=durable,rows=rows,cells={},messages={},reads=0,writes=0,checkpoints=0,mutations=0,functions={},jobs={}}
 local entities={}
 function entities:list()return rows end
 function entities:begin_command()end
 function entities:invalidate()end
 local function actual(e)for _,row in ipairs(rows)do if row.id==e.id then return row end end;error('stale-mock-entity')end
 function entities:read_data(e)
  host.reads=host.reads+1;local row=actual(e);local data=State.clone(row.data)
  data.Tags=setmetatable({},{__jsontype='array'});for tag in pairs(session.core.commands.tags[e.id]or {})do data.Tags[#data.Tags+1]=tag end
  table.sort(data.Tags);data.Pos={row.pos.x,row.pos.y,row.pos.z};return data
 end
 function entities:write_data(e,value,options)
  assert(options.replace);host.mutations=host.mutations+1;actual(e).data=State.clone(value);return true,value
 end
 function entities:teleport(e,pos,yaw,pitch)
  if host.reject then return false,'native-teleport-rejected'end
  host.mutations=host.mutations+1;local row=actual(e);row.pos=State.clone(pos)
  row.yaw=yaw or row.yaw;row.pitch=pitch or row.pitch;return true
 end
 function entities:kill(e)
  if host.reject then return false,'native-death-pending'end
  host.mutations=host.mutations+1;actual(e).alive=false;return true
 end
 function entities:damage(e,amount,kind,source)
  if host.reject then return false,'native-damage-rejected'end
  host.damage={target=e.id,amount=amount,kind=kind,source=source and source.id};host.mutations=host.mutations+1;return true
 end
 function entities:summon(id,pos,data)
  host.mutations=host.mutations+1;host.spawn={type=id,pos=State.clone(pos),data=State.clone(data)};return {id='spawn',name=id}
 end
 function entities:effect(e,id,ticks,level,hide)host.effect={e.id,id,ticks,level,hide};host.mutations=host.mutations+1;return true end
 function entities:clear_effect(e,id)host.cleared={e.id,id};host.mutations=host.mutations+1;return true end
 function entities:attribute(e,id,op,value)
  if op=='base_set'then host.attribute=value;host.mutations=host.mutations+1;return true end
  return host.attribute or 2.75
 end
 function entities:mount(e,vehicle)host.mount={e.id,vehicle.id};return true end
 function entities:dismount(e)host.mount=nil;return true end
 host.entities=entities
 function host:context()local row=rows[1];return {executor=row.id,pos=State.clone(row.pos),yaw=row.yaw,pitch=row.pitch,anchor='feet',eye_height=1.62}end
 function host:command_state()return session.core.commands end
 function host:save_command_state(value,expected)return session:commit_commands(expected,value)end
 function host:checkpoint()
  self.checkpoints=self.checkpoints+1
  if self.cancel_at and self.checkpoints>=self.cancel_at then error('command-cancelled')end
  if self.yield_every and self.checkpoints%self.yield_every==0 then coroutine.yield('command-slice')end
 end
 function host:read_block(pos)return State.clone(self.cells[key(pos)]or {id='minecraft:air',properties={}})end
 function host:write_blocks(entries)
  if self.reject then return nil,'native-world-rejected'end
  for _,row in ipairs(entries)do assert(row.block.id:match('^minecraft:'),'unsupported-block-namespace')end
  self.writes=self.writes+1;self.last_changes=State.clone(entries)
  for _,row in ipairs(entries)do self.cells[key(row.pos)]=State.clone(row.block)end
  return #entries
 end
 function host:block_data(pos)local b=self.cells[key(pos)];return b and State.clone(b.data)or nil,'block-has-no-data'end
 function host:write_block_data(pos,value)
  if self.reject then return nil,'block-write-rejected'end
  local b=assert(self.cells[key(pos)]);b.data=State.clone(value);self.writes=self.writes+1;return 1
 end
 function host:items(fn,...)
  local ticket=session:checkout({});local containers,n=fn(ticket.data.containers,...)
  if containers then ticket.data.containers=containers;local saved,why=session:commit(ticket,ticket.data);assert(saved,why)end
  return n
 end
 function host:give(e,id,count)assert(e.player);return self:items(Inventory.give,id,count,session.generation+1,'test')end
 function host:clear_items(e,id,count)assert(e.player);return self:items(Inventory.clear,id,count)end
 function host:replace_item(e,slot,id,count)assert(e.player);return self:items(Inventory.replace,slot,id,count,session.generation+1,'test')end
 function host:message(kind,text)self.messages[#self.messages+1]={kind=kind,text=text};return true end
 function host:function_lines(id)return assert(self.functions[id],'function-not-found')end
 function host:dimension()return 'pbz:test'end
 function host:is_loaded()return true end
 function host:read_command_data(args,index,context)return require('rules.commands.data').read_target(self.engine,args,index,context)end
 function host:data_path_exists(data,path)return require('rules.commands.data').path_exists(self.engine,data,path)end
 host.engine=Engine.new(host);return host,host.engine
end
local function run_async(host,engine,text,context)
 local co=coroutine.create(function()return engine:run(text,context)end);local slices=0
 while true do
  local success,result=coroutine.resume(co);assert(success,result);slices=slices+1;assert(slices<2000,'unbounded-command-job')
  if coroutine.status(co)=='dead'then return result,slices end
  assert(result=='command-slice')
 end
end

test('quoted parser, SNBT and empty-world selector validation',function()
 local t=Syntax.tokens([[data merge storage test:a {text:"a,b c",list:[{v:1},{v:2}]}]])
 assert(#t==5 and Syntax.snbt(t[5]).list[2].v==2)
 assert(not pcall(Syntax.tokens,[[say "unfinished]]));assert(not pcall(Syntax.snbt,'{a:1,a:2}'))
 assert(Syntax.range('..5',-1)and Syntax.range('2..',8)and not Syntax.range('2..5',8))
 local c={pos=p(0,0,0)}
 for _,s in ipairs({'@e[distance=5..2]','@e[distance=-1..]','@e[distance=!1]','@e[level=1.5]',
  '@e[type=#minecraft:undead]','@e[predicate=test:x]','@e[scores={x=3..1}]','@e[limit=0]',
  '@e[type=cow,type=zombie]','@e[type=]','@e[nbt=[]]','@e[x=0,x=1]'})do assert(not pcall(Select.select,s,c,{}),s)end
 assert(#Select.select('@e[scores={}]',c,{})==0)
end)
test('MC and neutral PBZ selection, exclusions, boxes and wrapped rotation',function()
 local h,e=fixture();local c=h:context()
 assert(#e:select('@a',c)==1 and #e:select('@e',c)==4)
 assert(e:select('@e[type=pbz:bp_neutral_c]',c,true)[1].id=='native')
 assert(#e:select('@e[type=!minecraft:player,type=!minecraft:zombie]',c)==2)
 assert(e:select('@e[sort=furthest,limit=1]',c)[1].id=='cow')
 assert(#e:select('@e[dx=-3,dy=0,dz=0]',c)==2)
 assert(#e:select('@e[y_rotation=170..-170]',c)==2)
 assert(#e:select('@e[y_rotation=530..550]',c)==2)
 assert(e:select('@e[distance=2..3,x_rotation=5..15]',c)[1].id=='zombie')
 assert(#e:select('@e[name=!Zombie,name=!Cow,name=!Steve]',c)==1)
 local count=e:run('execute if entity @e[type=!minecraft:player]')
 assert(count.success and count.result==3 and count.success_count==1)
 assert(#e:select('@e[gamemode=!creative]',c)==1)
 h.entities.supports_level=false
 local valid,why=pcall(e.select,e,'@a[level=0]',c);assert(not valid and tostring(why):find('experience-system-unavailable',1,true))
 assert(#e:select('Dead',c)==0 and #e:select('@s',c)==1)
end)
test('metadata selectors and NBT arrays use full live projection',function()
 local h,e=fixture();ok(e:run('tag zombie add first'));ok(e:run('tag zombie add second'))
 ok(e:run('team add blue'));ok(e:run('team join blue zombie'))
 ok(e:run('scoreboard objectives add points dummy'));ok(e:run('scoreboard players set zombie points 7'))
 local c=h:context();assert(#e:select('@e[tag=first,team=blue,scores={points=5..9}]',c)==1)
 assert(h.reads==0);assert(#e:select('@e[nbt={Tags:["second","first"]}]',c)==1 and h.reads==#h.rows)
 assert(#e:select('@e[nbt={Tags:[]}]',c)==3)
 assert(#e:select('@e[tag=!]',c)==1 and #e:select('@e[tag=]',c)==3)
 assert(h.durable.disk_commits==0)
end)
test('teleport variants, local axes, anchors, rotations and strict tails',function()
 local h,e=fixture();ok(e:run('/tp 1 2 3 45 -30'));near(h.rows[1].pos.x,1.5);near(h.rows[1].pos.z,3.5);near(h.rows[1].yaw,45)
 ok(e:run('tp ~1 ~-2 ~3 ~10 ~'));near(h.rows[1].pos.x,2.5);near(h.rows[1].pos.y,0);near(h.rows[1].yaw,55)
 local c={executor='player',pos=p(0,64,0),yaw=90,pitch=0,anchor='eyes',eye_height=1.62}
 ok(e:run('tp ^1 ^2 ^3',c));near(h.rows[1].pos.x,-3);near(h.rows[1].pos.y,67.62);near(h.rows[1].pos.z,1)
 ok(e:run('tp ~ ~ ~ facing 10 64 0',h:context()))
 ok(e:run('tp native zombie'));near(h.rows[3].pos.x,h.rows[2].pos.x)
 local before=h.mutations
 for _,text in ipairs({'tp @s 1 2 3 4 5 extra','tp 1 2 3 facing entity zombie invalid',
  'tp 1 2 3 facing 0 0 0 extra','tp ^ ~ ^','tag @s list extra'})do bad(e:run(text));assert(h.mutations==before)end
end)
test('attribute scale and native operation failures propagate',function()
 local h,e=fixture();local r=ok(e:run('attribute native minecraft:movement_speed get 4'));assert(r.result==11)
 r=ok(e:run('attribute native minecraft:movement_speed base get 0'));assert(r.result==0)
 bad(e:run('attribute native minecraft:movement_speed base set'));assert(h.mutations==0)
 ok(e:run('attribute native minecraft:movement_speed base set 5'));assert(h.attribute==5)
 ok(e:run('damage native 12 minecraft:arrow by zombie'));assert(h.damage.source=='zombie'and h.damage.amount==12)
 h.reject=true;bad(e:run('kill native'),'native-death-pending');bad(e:run('tp native 1 2 3'),'native-teleport-rejected')
 bad(e:run('damage native 1'),'native-damage-rejected');bad(e:run('setblock 0 0 0 stone'),'native-world-rejected')
end)
test('summon/effect parameter forwarding rejects malformed requests first',function()
 local h,e=fixture();ok(e:run('summon minecraft:zombie 1 2 3 {Health:10,NoAI:1b}'))
 assert(h.spawn.type=='minecraft:zombie'and h.spawn.data.Health==10);near(h.spawn.pos.x,1.5)
 ok(e:run('effect give native minecraft:speed 12 3 true'));assert(h.effect[3]==240 and h.effect[4]==3 and h.effect[5])
 ok(e:run('effect clear native minecraft:speed'));assert(h.cleared[2]=='speed')
 local before=h.mutations;bad(e:run('summon zombie 1 2 3 []'));bad(e:run('effect give native speed 1 256'))
 assert(h.mutations==before)
end)
test('large world jobs yield and capacity/overflow fail before writes',function()
 local h,e=fixture();h.yield_every=128
 local r,slices=run_async(h,e,'fill 0 0 0 31 7 31 stone');assert(ok(r).result==8192 and slices>60 and h.writes==1)
 local writes=h.writes
 for _,text in ipairs({'fill 0 0 0 8192 0 0 stone','fill -30000000 -30000000 -30000000 30000000 30000000 30000000 stone',
  'clone 0 0 0 4096 0 0 10000 0 0'})do bad(run_async(h,e,text),'volume-exceeds-host-limit');assert(h.writes==writes)end
 h.yield_every=nil;ok(e:run('gamerule max_block_modifications 8'));bad(e:run('clone 0 0 0 8 0 0 100 0 0'),'volume-exceeds-host-limit')
end)
test('relative fill includes both endpoints and player cell',function()
 local h,e=fixture()
 local result=ok(e:run('/fill ~ ~ ~ ~10 ~1 ~10 minecraft:tnt'))
 assert(result.result==242 and #h.last_changes==242)
 assert(h:read_block(p(0,64,0)).id=='minecraft:tnt')
 assert(h:read_block(p(10,65,10)).id=='minecraft:tnt')
 assert(h:read_block(p(11,65,10)).id=='minecraft:air')
 local ctx={executor='player',pos=p(-.2,64.7,-.8),yaw=0,pitch=0,anchor='feet'}
 result=ok(e:run('fill ~ ~-1 ~ ~-2 ~-1 ~-2 minecraft:stone',ctx))
 assert(result.result==9 and h:read_block(p(-1,63,-1)).id=='minecraft:stone')
 assert(h:read_block(p(-3,63,-3)).id=='minecraft:stone')
end)
test('fill/clone filters, hollow interiors and overlap semantics',function()
 local h,e=fixture();ok(e:run('fill 0 0 0 2 2 2 stone hollow'));assert(h:read_block(p(1,1,1)).id=='minecraft:air')
 ok(e:run('setblock 9 0 0 command_block{Command:"say one"}'))
 ok(e:run('setblock 10 0 0 command_block{Command:"say two"}'))
 local r=ok(e:run('fill 9 0 0 10 0 0 dirt replace command_block{Command:"say two"}'));assert(r.result==1)
 assert(h:read_block(p(9,0,0)).id=='minecraft:command_block')
 bad(e:run('clone 0 0 0 2 2 2 1 0 0'),'clone-regions-overlap')
 ok(e:run('clone 9 0 0 10 0 0 10 0 0 replace move'))
 assert(h:read_block(p(9,0,0)).id=='minecraft:air'and h:read_block(p(10,0,0)).id=='minecraft:command_block')
 assert(h:read_block(p(11,0,0)).id=='minecraft:dirt')
end)
test('inventory unique ownership and memory-only give/replace transactions',function()
 local h,e=fixture();ok(e:run('give @s diamond_sword 2'));ok(e:run('give @s diamond_sword 2'));ok(e:run('give @s arrow 100'))
 local ids,n={},0;Slots.visit(h.session.core.containers,function(_,s)if s.instance_id then assert(not ids[s.instance_id]);ids[s.instance_id]=true;n=n+1 end end)
 assert(n==4);Slots.validate(h.session.core.containers,Items);assert(h.durable.disk_commits==0)
 ok(e:run('item replace entity @s weapon.offhand with shield'));assert(Slots.get(h.session.core.containers,'player/offhand').content_id=='pbzmc:shield')
 ok(e:run('item replace entity @s weapon.offhand with air'));assert(not Slots.get(h.session.core.containers,'player/offhand'))
 local before=Encode(h.session.core);bad(e:run('give @s diamond_sword 37'));bad(e:run('give @s pbz:slot_reference'))
 bad(e:run('item replace entity @s armor.head with stone'));assert(Encode(h.session.core)==before)
end)
test('inventory overflow is atomic and clear preserves native slot references',function()
 local h,e=fixture();local ticket=h.session:checkout({});local edit=Slots.edit(ticket.data.containers)
 edit:set('player/hotbar/1',Native.new('main',0));edit:set('cursor',Native.new('shaqi',1))
 ticket.data.containers=edit.data;assert(h.session:commit(ticket,ticket.data));ok(e:run('give @s arrow 100'))
 local core=h.session.core;local query=ok(e:run('clear @s arrow 0'));assert(query.result==100 and h.session.core==core)
 ok(e:run('clear @s arrow 30'));local remaining=ok(e:run('clear @s arrow 0'));assert(remaining.result==70)
 local before=Encode(h.session.core);bad(e:run('give @s stone 2304'),'inventory-full');assert(Encode(h.session.core)==before)
 bad(e:run('item replace entity @s hotbar.0 with air'),'cannot-delete-pbz-weapon-reference')
 ok(e:run('clear @s'));assert(Native.is(Slots.get(h.session.core.containers,'player/hotbar/1'))and Native.is(h.session.core.containers.cursor))
 Slots.validate(h.session.core.containers,Items);assert(h.durable.disk_commits==0)
end)
test('command metadata isolated, stale/invalid candidates fail, savepoint flush persists',function()
 local h,e=fixture();local s=h.session;local containers,buildings=s.core.containers,s.core.buildings
 local old=s.core.commands;ok(e:run('scoreboard objectives add x dummy'));assert(s.core.containers==containers and s.core.buildings==buildings)
 assert(not s:commit_commands(old,commands()));local candidate=State.clone(s.core.commands);candidate.bad=function()end
 local before=s.core;assert(not s:commit_commands(s.core.commands,candidate)and s.core==before)
 candidate=State.clone(s.core.commands);candidate.tags.player={hello=true};assert(s:commit_commands(s.core.commands,candidate))
 candidate.tags.player.hello=nil;assert(s.core.commands.tags.player.hello and h.durable.disk_commits==0)
 assert(s:flush());assert(h.durable.disk_commits==1 and h.durable.core.commands.tags.player.hello and not s.dirty)
end)
test('data paths/compounds commit once and failure is atomic',function()
 local h,e=fixture();ok(e:run('data merge storage test:a {list:[{n:1},{n:2}],text:"中文A"}'))
 ok(e:run('data modify storage test:a list[].n set value 3'))
 assert(ok(e:run('data get storage test:a list[-1].n')).result==3)
 local before=Encode(h.session.core.commands);bad(e:run('data modify storage test:a list[] append value 9'));assert(Encode(h.session.core.commands)==before)
 ok(e:run('data modify storage test:a list append value {n:4}'));ok(e:run('data remove storage test:a list[{n:3}]'))
 assert(#h.session.core.commands.storage['test:a'].list==1)
 bad(e:run('data merge entity @s {Health:1}'),'player-data-write-unavailable')
 ok(e:run('data merge entity native {Health:50}'));assert(h.rows[3].data.Health==50)
end)
test('execute forks/context, score storage and terminal conditions',function()
 local h,e=fixture();ok(e:run('scoreboard objectives add n dummy'))
 local r=ok(e:run('execute as @e[type=!minecraft:player] at @s run tag @s add selected'));assert(r.result==3 and r.success_count==3)
 assert(h.session.core.commands.tags.native.selected and h.session.core.commands.tags.cow.selected)
 ok(e:run('execute as native at @s positioned ~1 ~ ~ run summon cow ~ ~ ~'));near(h.spawn.pos.x,-2)
 ok(e:run('execute store result score result n run compute default integer -7'));assert(h.session.core.commands.scores.result.n==-7)
 bad(e:run('execute store success score rejected n run kill @e[type=minecraft:unknown]'));assert(h.session.core.commands.scores.rejected.n==0)
 local condition=ok(e:run('execute if entity @e[type=pbz:bp_neutral_c]'));assert(condition.result==1)
 bad(e:run('execute if entity @e[type=minecraft:unknown] run say absent'));assert(#h.messages==0)
end)
test('execution budgets survive nested failure and public handlers stay isolated',function()
 local h,e=fixture();assert(not e.handlers._literal and not e.handlers._path and not e.handlers.subset)
 h.functions['test:loop']={'function test:loop'};bad(e:run('execute run function test:loop'),'command-recursion-limit')
 assert(e.execution==nil);ok(e:run('say after recursion'))
 e.max_operations=12;local writes=h.writes
 bad(e:run('execute run fill 0 0 0 20 0 0 stone'),'command-execution-budget-exceeded');assert(h.writes==writes)
 e.max_operations=65536;h.cancel_at=h.checkpoints+5
 bad(e:run('execute run fill 0 0 0 20 0 0 stone'),'command-cancelled');assert(h.writes==writes)
end)
local function scheduled(host,engine,options)
 local records,queue={},{};local sch;local calls=0
 local adapter={get=function(pos)return records[key(pos)]end,
  execute=function(record,done)
   queue[#queue+1]={done=done,co=coroutine.create(function()
    return engine:run(record.properties.command,{pos=p(record.x+.5,record.z+.5,-record.y+.5),yaw=0,pitch=0,source='block'})
   end)};calls=calls+1;return true
  end,
  outcome=function(record,count,output)
   if host.outcome_reject then return false,'outcome-rejected'end
   record.properties.success_count=count;record.properties.last_output=output;return true
  end}
 sch=Scheduler.new(adapter,options)
 local function put(id,kind,x,command,extra)
  local props={facing='east',auto=kind=='chain_command_block',command=command,track_output=true}
  for k,v in pairs(extra or {})do props[k]=v end
  local record={id=id,content_id='pbzmc:'..kind,x=x,y=0,z=0,properties=props}
  records[key(record)]=record;sch:upsert(record);return record
 end
 local function pump(tick)
  for slices=1,2000 do
   sch:step(tick)
   local job=queue[1]
   if job then
    local success,result=coroutine.resume(job.co);assert(success,result)
    if coroutine.status(job.co)=='dead'then table.remove(queue,1);job.done(result)else assert(result=='command-slice')end
   end
   if not sch:pending_tick()and #queue==0 then return slices end
  end
  error('unbounded-command-block-work')
 end
 return sch,put,pump,records,function()return calls end,queue
end
test('impulse/conditional chains execute real commands and preserve async order',function()
 local h,e=fixture();ok(e:run('scoreboard objectives add n dummy'));h.yield_every=32
 local sch,put,pump,records,calls=scheduled(h,e,{budget=2})
 local root=put('root','command_block',0,'fill 0 0 0 127 0 0 stone')
 local chain=put('chain','chain_command_block',1,'scoreboard players add chain n 1',{conditional=true})
 sch:signal(root,true);sch:step(1);assert(sch:pending_tick()and calls()==1 and not h.session.core.commands.scores.chain)
 assert(pump(1)>1 and calls()==2 and h.session.core.commands.scores.chain.n==1)
 assert(root.properties.success_count==1 and chain.properties.success_count==1)
 pump(1);assert(calls()==2)
end)
test('repeating blocks execute once per logical tick, finite chains stop',function()
 local h,e=fixture();ok(e:run('scoreboard objectives add n dummy'))
 local sch,put,pump,records,calls=scheduled(h,e,{budget=1,max_chain=8})
 local root=put('repeat','repeating_command_block',0,'scoreboard players add root n 1',{auto=true})
 put('a','chain_command_block',1,'scoreboard players add a n 1')
 put('b','chain_command_block',2,'scoreboard players add b n 1',{facing='west'})
 pump(1);assert(h.session.core.commands.scores.root.n==1 and calls()==3)
 pump(1);assert(calls()==3);pump(2);assert(h.session.core.commands.scores.root.n==2 and calls()==6)
 sch:clear();pump(3);assert(calls()==6)
end)
test('conditional failure skips successor and outcome rejection stops the chain',function()
 local h,e=fixture();ok(e:run('scoreboard objectives add n dummy'))
 local sch,put,pump,records,calls=scheduled(h,e,{budget=4})
 local root=put('root','command_block',0,'kill @e[type=minecraft:missing]')
 put('guard','chain_command_block',1,'scoreboard players add bad n 1',{conditional=true})
 put('tail','chain_command_block',2,'scoreboard players add tail n 1')
 sch:signal(root,true);pump(1);assert(not h.session.core.commands.scores.bad and h.session.core.commands.scores.tail.n==1)
 h.outcome_reject=true;sch:signal(root,false);sch:signal(root,true);local before=calls();pump(2)
 assert(calls()==before and sch.last_error=='outcome-rejected')
end)
local function campaign_module()
 package.loaded.UEHelpers=package.loaded.UEHelpers or {}
 return require('host.pbz.campaign_inventory')
end
local function rollback_fixture(count)
 local h=fixture();local rows={}
 for i=1,count do
  local r={id='rollback-'..i,content_id='pbzmc:stone',world='test',x=i*100,y=0,z=0,yaw=0,properties={}}
  h.session.core.buildings[r.id]=r;rows[i]={after=State.clone(r)}
 end
 local campaign=campaign_module();local ensure=campaign.ensure
 campaign.ensure=function()return {store=h.session,world={name='World test'}}end
 local callback=campaign.command_rollback({});campaign.ensure=ensure
 return h,rows,callback
end
test('captured stale-world rollback CAS is bounded and preserves unrelated metadata',function()
 local h,rows,revert=rollback_fixture(260);local meta,containers=h.session.core.commands,h.session.core.containers
 local keep={id='keep',content_id='pbzmc:dirt',world='other',x=100,y=0,z=0,yaw=0,properties={}}
 h.session.core.buildings.keep=keep
 local accepted,n=revert(rows);assert(accepted and n==260 and h.session.commits==3)
 assert(h.session.core.buildings.keep==keep and h.session.core.commands==meta and h.session.core.containers==containers)
 assert(not h.session.core.buildings['rollback-1']and h.durable.disk_commits==0)
end)
test('rollback rejects stale records/occupied cells and restores core on later internal failure',function()
 local h,rows,revert=rollback_fixture(2);h.session.core.buildings['rollback-2'].content_id='pbzmc:dirt'
 local original=h.session.core;local accepted,why=revert(rows)
 assert(not accepted and why:find('record%-conflict')and h.session.core==original and h.session.commits==0)
 local removed={id='old',content_id='pbzmc:stone',world='test',x=100,y=0,z=0,yaw=0,properties={}}
 accepted,why=revert({{before=removed}});assert(not accepted and why:find('position%-conflict')and h.session.core==original)
 h,rows,revert=rollback_fixture(260);original=h.session.core
 local calls=0;local apply=require('storage.session_store').commit_buildings
 function h.session:commit_buildings(ticket,changes,grids)
  calls=calls+1;if calls==2 then return false,'injected-memory-rejection'end
  return apply(self,ticket,changes,grids)
 end
 accepted,why=revert(rows);assert(not accepted and why:find('injected%-memory%-rejection'))
 assert(h.session.core==original and h.session.generation>0 and h.session.core.buildings['rollback-260'])
 h.session.commit_buildings=nil;assert(revert(rows))
end)
test('native savepoint is fenced before any flush while a command journal is pending',function()
 local campaign=campaign_module();local active_index,old_active
 for index=1,100 do local name,value=debug.getupvalue(campaign.savepoint,index);if not name then break end
  if name=='active'then active_index=index;old_active=value;break end
 end
 assert(active_index,'savepoint-active-owner-not-found')
 local flushes,notices=0,0;local binding={};local owner={binding=binding,session={},profiles={},status_service={flush_memory=function()flushes=flushes+1 end}}
 debug.setupvalue(campaign.savepoint,active_index,owner)
 local current=campaign.current;campaign.current=function()return true end
 local old_commands,old_buildings=package.loaded['host.pbz.command_service'],package.loaded['host.pbz.building_service']
 local pending=true;local service={has_pending_mutations=function()return pending end,message=function()notices=notices+1 end}
 package.loaded['host.pbz.command_service']={get=function()return service end}
 local called,why=pcall(campaign.savepoint,'test');assert(not called and why:find('command%-world%-transaction%-pending')and flushes==0 and notices==1)
 -- Closing services are hidden by get(), but their build owner retains the fence.
 package.loaded['host.pbz.command_service']={get=function()end}
 package.loaded['host.pbz.building_service']={get=function()return {commands=service}end}
 called,why=pcall(campaign.savepoint,'test');assert(not called and flushes==0 and notices==2)
 pending=false;assert(campaign.savepoint('test')and flushes==1)
 campaign.current=current;debug.setupvalue(campaign.savepoint,active_index,old_active)
 package.loaded['host.pbz.command_service'],package.loaded['host.pbz.building_service']=old_commands,old_buildings
end)
test('custom bossbar lifecycle, actual player audience and execute store',function()
 local h,e=fixture();local function run(text)return ok(e:run(text))end
 assert(run('bossbar list').result==0)
 run('bossbar add demo "Hello"');bad(e:run('bossbar add demo "Again"'),'already-exists')
 local bars=h.session.core.commands.bossbars;assert(bars['minecraft:demo'].value==0 and bars['minecraft:demo'].max==100)
 run('bossbar set demo players @a');run('bossbar set demo color red');run('bossbar set demo style notched_10')
 assert(run('bossbar get demo players').result==1)
 bad(e:run('bossbar set demo players @e[type=minecraft:zombie]'),'target-must-be-player')
 bad(e:run('bossbar set demo color red'),'unchanged');bad(e:run('bossbar set demo max 0'),'invalid-number')
 run('scoreboard objectives add hp dummy');run('scoreboard players set target hp 50')
 run('execute store result bossbar demo value run scoreboard players get target hp')
 assert(run('bossbar get demo value').result==50)
 bad(e:run('execute store success bossbar demo value run execute if entity @e[type=minecraft:nonexistent]'))
 assert(run('bossbar get demo value').result==0)
 run('bossbar set demo players');assert(run('bossbar get demo players').result==0)
 run('bossbar set demo visible false');assert(run('bossbar get demo visible').result==0)
 assert(h.durable.disk_commits==0);assert(run('bossbar remove demo').result==0)
 bad(e:run('bossbar get demo value'),'unknown-bossbar')
end)
test('bossbar original sprite crop and bounded player-only display',function()
 local draw=require('presentation.command_bossbars').draw
 local skin={bossbars={red={background='red_bg',progress='red_fg'},notched_10={background='ticks_bg',progress='ticks_fg'}}}
 local assets={glyphs={A={path='A.png',advance=6,width=5,height=8}}}
 local b={name='A',color='red',style='notched_10',value=50,max=100,visible=true,players={player=true}}
 local rows=draw({demo=b},'player',assets,skin,{width=1000,height=600},2)
 assert(#rows==6 and rows[2].w==182 and rows[2].region.w==91 and rows[4].texture=='ticks_fg')
 assert(#draw({demo=b},'other',assets,skin,{width=1000,height=600},2)==0)
 b.value=-1;assert(#draw({demo=b},'player',assets,skin,{width=1000,height=600},2)==4)
 b.max=0;b.value=20;rows=draw({demo=b},'player',assets,skin,{width=1000,height=600},2);assert(rows[2].region.w==182)
 local many={};for i=1,64 do many[tostring(i)]=b end
 assert(#draw(many,'player',assets,skin,{width=1000,height=120},2)==6)
end)
test('version and game time report real host values and unavailable mappings fail explicitly',function()
 local h,e=fixture();function h:version()return 'PBZMC test / Minecraft rules 26.3'end
 function h:game_time()return 2147483648 end
 assert(ok(e:run('version')).message=='PBZMC test / Minecraft rules 26.3')
 assert(ok(e:run('time query gametime')).result==1)
 bad(e:run('time set day'),'time-clock-system-unavailable')
 for _,cmd in ipairs({'difficulty peaceful','spawnpoint @s','setworldspawn','defaultgamemode creative'})do
  bad(e:run(cmd),'command-unsupported-host-mapping')
 end
end)
print('PASS commands '..passed..' end-to-end scenarios (mock host, no PBZ runtime)')
''')
