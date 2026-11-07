-- Minecraft 26.3 command grammar. These handlers only parse/select; the
-- command service marshals every presentation operation to its native scope.
local syntax=require('rules.commands.syntax')
local M={}
local sources={master=true,music=true,record=true,weather=true,block=true,hostile=true,
 neutral=true,player=true,ambient=true,voice=true,ui=true}
local function targets(e,raw,c,players)
 local found=e:select(raw,c,false,players);assert(#found>0,players and 'no-players-found' or 'no-entities-found');return found
end
local function source(raw)assert(sources[raw],'invalid-sound-source:'..tostring(raw));return raw end
local function result(e,name,request)
 e:spend();local n,message=e:call(name,request)
 assert(type(n)=='number'and n>=0 and n%1==0,'invalid-presentation-result:'..name)
 return n,message,true
end
function M.playsound(e,a,c)
 assert(#a>=1 and #a<=9,'usage:playsound sound [source] [targets] [pos] [volume] [pitch] [minVolume]')
 local request={sound=syntax.id(a[1]),source=a[2]and source(a[2])or 'master',pos=c.pos,volume=1,pitch=1,min_volume=0}
 if a[4]then request.pos=syntax.position(a,4,c,true)end
 if a[7]then request.volume=syntax.number(a[7],0,3.4028234663852886e38)end
 if a[8]then request.pitch=syntax.number(a[8],0,2)end
 if a[9]then request.min_volume=syntax.number(a[9],0,1)end
 request.targets=targets(e,a[3]or '@s',c,true)
 return result(e,'play_sound',request)
end
function M.stopsound(e,a,c)
 assert(#a>=1 and #a<=3,'usage:stopsound targets [source|*] [sound]')
 local request={}
 if a[2]=='*'then assert(a[3],'stopsound-wildcard-requires-sound')
 elseif a[2]then request.source=source(a[2])end
 if a[3]then request.sound=syntax.id(a[3])end
 request.targets=targets(e,a[1],c,true)
 return result(e,'stop_sound',request)
end
function M.particle(e,a,c)
 assert(#a==1 or #a==4 or #a==9 or #a==10 or #a==11,
  'usage:particle name [pos] [delta speed count] [normal|force] [viewers]')
 local name,body=a[1]:match('^([a-z0-9_:./%-]+)(.*)$');assert(name,'invalid-particle-id')
 local request={name=syntax.id(name),pos=c.pos,delta={x=0,y=0,z=0},speed=0,count=0,force=false}
 if body~=''then
  assert(body:sub(1,1)=='{','particle-options-compound-required')
  request.options=syntax.snbt(body)
 end
 if a[2]then request.pos=syntax.position(a,2,c,true)end
 if a[5]then request.delta=syntax.position(a,5,c,false);request.speed=syntax.number(a[8],0,3.4028234663852886e38)
  request.count=syntax.number(a[9],0,2147483647,true)end
 if a[10]then assert(a[10]=='force'or a[10]=='normal','particle-mode-must-be-normal-or-force');request.force=a[10]=='force'end
 request.targets=targets(e,a[11]or '@a',c,true)
 return result(e,'particle',request)
end
local function duration(raw)
 if not raw then return 6 end
 local number,unit=raw:match('^([%d%.+%-]+)([dst]?)$');assert(number,'invalid-swing-duration')
 local value=syntax.number(number,0)*({d=24000,s=20,t=1,['']=1})[unit]
 -- Brigadier TimeArgument rounds the float to integral game ticks.
 value=math.floor(value+.5);assert(value>=1 and value<=2147483647,'swing-duration-out-of-range');return value
end
function M.swing(e,a,c)
 assert(#a<=4,'usage:swing [targets] [mainhand|offhand] [none|whack|stab] [duration]')
 local hand=a[2]or 'mainhand';assert(hand=='mainhand'or hand=='offhand','invalid-swing-hand')
 local animation=a[3]or 'whack';assert(animation=='none'or animation=='whack'or animation=='stab','invalid-swing-animation')
 return result(e,'swing',{targets=targets(e,a[1]or '@s',c),hand=hand,animation=animation,duration=duration(a[4])})
end
return M
