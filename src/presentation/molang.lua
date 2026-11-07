-- Compiles validated Molang expression trees once; no load(), text evaluation,
-- UObject access or filesystem work occurs while evaluating an animation.
local M={}
local function truth(x)return x~=nil and x~=false and x~=0 end
local function num(x)return type(x)=='number'and x or x==true and 1 or 0 end
local function clamp(x,a,b)return math.max(a,math.min(b,x))end
local function wrap(x)return (x+180)%360-180 end
local functions={
 ['math.sin']=function(x)return math.sin(math.rad(x))end,
 ['math.cos']=function(x)return math.cos(math.rad(x))end,
 ['math.abs']=math.abs,['math.min']=math.min,['math.max']=math.max,
 ['math.floor']=math.floor,['math.round']=function(x)return math.floor(x+.5)end,
 ['math.sqrt']=function(x)return math.sqrt(math.max(0,x))end,
 ['math.pow']=function(a,b)return a<0 and b%1~=0 and 0 or a^b end,
 ['math.mod']=function(a,b)return b~=0 and a%b or 0 end,
 ['math.clamp']=clamp,['math.min_angle']=wrap,
 ['math.lerp']=function(a,b,t)return a+(b-a)*t end,
 ['math.lerprotate']=function(a,b,t)return a+wrap(b-a)*t end,
 ['math.inverse_lerp']=function(a,b,x)return b~=a and (x-a)/(b-a)or 0 end,
 ['math.random']=function(a,b)return a+(b-a)*math.random()end,
 ['math.ease_in_circ']=function(a,b,t)t=clamp(t,0,1);return a+(b-a)*(1-math.sqrt(1-t*t))end,
 ['math.ease_out_circ']=function(a,b,t)t=clamp(t,0,1)-1;return a+(b-a)*math.sqrt(1-t*t)end,
 ['math.ease_in_out_elastic']=function(a,b,t)
   if t<=0 then return a elseif t>=1 then return b end
   local s=math.sin((20*t-11.125)*2*math.pi/4.5)
   return a+(b-a)*(t<.5 and -2^(20*t-10)*s/2 or 2^(-20*t+10)*s/2+1)
 end,
}
local binary={['+']=function(a,b)return num(a)+num(b)end,['-']=function(a,b)return num(a)-num(b)end,
 ['*']=function(a,b)return num(a)*num(b)end,['/']=function(a,b)return num(b)~=0 and num(a)/num(b)or 0 end,
 ['%']=function(a,b)return num(b)~=0 and num(a)%num(b)or 0 end,
 ['==']=function(a,b)return a==b and 1 or 0 end,['!=']=function(a,b)return a~=b and 1 or 0 end,
 ['<']=function(a,b)return num(a)<num(b)and 1 or 0 end,['<=']=function(a,b)return num(a)<=num(b)and 1 or 0 end,
 ['>']=function(a,b)return num(a)>num(b)and 1 or 0 end,['>=']=function(a,b)return num(a)>=num(b)and 1 or 0 end}
local compile
compile=function(node)
 if type(node)~='table'then return function()return node end end
 local op=node[1]
 if op=='str'then return function()return node[2]end end
 if op=='get'then
   local key=node[2]
   if key=='this'then return function(c)return c.this or 0 end end
   if key=='math.pi'then return function()return math.pi end end
   if key=='true'or key=='false'then return function()return key=='true'and 1 or 0 end end
   if key:sub(1,6)=='query.'then local k=key:sub(7);return function(c)return c.query(k)end end
   return function(c)return c.vars[key]or 0 end
 end
 if op=='set'then local key,f=node[2],compile(node[3]);return function(c)local v=f(c);c.vars[key]=v;return v end end
 if op=='return'then local f=compile(node[2]);return function(c)return f(c),true end end
 if op=='seq'then
   local fs={};for i=2,#node do fs[#fs+1]=compile(node[i])end
   return function(c)local v;for _,f in ipairs(fs)do local stop;v,stop=f(c);if stop then return v,stop end end;return v or 0 end
 end
 if op=='if'then local a,b,d=compile(node[2]),compile(node[3]),compile(node[4]);return function(c)if truth(a(c))then return b(c)else return d(c)end end end
 if op=='unary'then local f=compile(node[3]);local sign=node[2];return function(c)local n=f(c);return sign=='!'and (truth(n)and 0 or 1)or sign=='-'and -num(n)or num(n)end end
 if op=='call'then
   local name=node[2];local fs={};for i=3,#node do fs[#fs+1]=compile(node[i])end
   local f=functions[name]
   assert(f or name:sub(1,6)=='query.','unsupported-molang-function:'..name)
   return function(c)
     local a,b,d,e=fs[1]and fs[1](c),fs[2]and fs[2](c),fs[3]and fs[3](c),fs[4]and fs[4](c)
     if f then
       if #fs==1 then return f(a)elseif #fs==2 then return f(a,b)elseif #fs==3 then return f(a,b,d)else return f(a,b,d,e)end
     end
     return c.query(name:sub(7),a,b,d,e)
   end
 end
 if op=='&&'or op=='||'then local a,b=compile(node[2]),compile(node[3]);return function(c)
   if op=='&&'then return truth(a(c))and (truth(b(c))and 1 or 0)or 0 end
   return truth(a(c))and 1 or (truth(b(c))and 1 or 0)
 end end
 if op=='??'then
   local a,b=compile(node[2]),compile(node[3]);local key=type(node[2])=='table'and node[2][1]=='get'and node[2][2]
   return function(c)if key and c.vars[key]==nil then return b(c)end;return a(c)end
 end
 local f=assert(binary[op],'unsupported-molang-op:'..tostring(op));local a,b=compile(node[2]),compile(node[3])
 return function(c)return f(a(c),b(c))end
end
M.compile=compile;M.truth=truth;M.num=num
return M
