-- FireBlock + LavaFluid, Minecraft 26.3. Transient flames are not saved blocks.
-- Indexed scheduled events, bounded work; no whole-world/per-frame scan.
local data=require('content.fire_reference').blocks
local M={max_fires=32};local Network={};Network.__index=Network
local neighbors={{1,0,0,300},{-1,0,0,300},{0,0,-1,250},{0,0,1,250},{0,-1,0,300},{0,1,0,300}}
local function key(x,y,z)return x..','..y..','..z end
M.key=key
function M.fuel(cell)
 if not cell or (cell.properties or {}).waterlogged then return 0,0,false end
 local row=data[cell.content_id];if row then return row[1],row[2],row[3]end
 return 0,0,false
end
local function earlier(a,b)return a.due<b.due or a.due==b.due and a.serial<b.serial end
local function swap(n,a,b)local h=n.heap;h[a],h[b]=h[b],h[a];h[a].index=a;h[b].index=b end
local function up(n,i)while i>1 do local p=i//2;if not earlier(n.heap[i],n.heap[p])then break end;swap(n,i,p);i=p end end
local function down(n,i)
 local h=n.heap
 while i*2<=#h do local c=i*2;if c<#h and earlier(h[c+1],h[c])then c=c+1 end
  if not earlier(h[c],h[i])then break end;swap(n,c,i);i=c
 end
end
function Network:cancel(e)
 if not e or not e.index then return end
 local h=self.heap;local i=e.index;local tail=h[#h];h[#h]=nil;e.index=nil
 if i<=#h then h[i]=tail;tail.index=i;up(self,i);down(self,tail.index)end
end
function Network:schedule(e,due)
 self:cancel(e);self.serial=self.serial+1;e.serial=self.serial;e.due=due;e.index=#self.heap+1
 self.heap[e.index]=e;up(self,e.index)
end
function Network:rand(n)return self.random(n)end
function Network:read(x,y,z)self.reads=self.reads+1;return self.adapter.read(x,y,z)end
function Network:neighbors(x,y,z,lava)
 local best,pending=0,false
 for _,d in ipairs(neighbors)do
  local c=self:read(x+d[1],y+d[2],z+d[3]);local a,_,l=M.fuel(c)
  if c and c.pending then pending=true end
  best=math.max(best,lava and (l and 1 or 0)or a)
 end
 return best,pending
end
function Network:forget(k)
 local e=self.fires[k];if not e then return end
 self:cancel(e);self.fires[k]=nil;self.count=self.count-1
end
function Network:extinguish(e,reason)
 if self.adapter.extinguish(e.handle,reason)~=false then self:forget(e.key);return true end
 self:schedule(e,self.tick+5);return false
end
function Network:ignite(x,y,z,options)
 options=options or {};local k=key(x,y,z)
 if self.fires[k]then return true,'existing',self.fires[k]end
 if self.count>=self.max_fires then self.limited=self.limited+1;return false,'fire-budget'end
 local cell=self:read(x,y,z)
 -- A directly traced native surface can share the global cell with native
 -- terrain. Only that proven surface may override its terrain occupancy.
 if cell and not (options.surface and cell.native_terrain)then return false,'occupied'end
 local odds,pending=self:neighbors(x,y,z,false);local below=self:read(x,y,z-1)
 if odds==0 and not options.surface and not self.adapter.sturdy(below)then return false,pending and 'pending' or 'unsupported'end
 local e={kind='fire',key=k,x=x,y=y,z=z,age=options.age or 0,surface=options.surface}
 local ok,handle=self.adapter.ignite(e,odds>0 and 60 or 8,options.position)
 if not ok then return false,handle end
 e.handle=handle;self.fires[k]=e;self.count=self.count+1;self.created=self.created+1
 self:schedule(e,self.tick+30+self:rand(10));return true,'created',e
end
function Network:lava_delay()
 -- randomTickSpeed=3 among 4096 cells: geometric wait, not a lava scan.
 local u=(self:rand(1048576)+.5)/1048576
 return math.max(1,math.ceil(math.log(1-u)/math.log(1-3/4096)))
end
function Network:track_lava(x,y,z,cell)
 local k=key(x,y,z);local old=self.lava[k]
 if cell and cell.content_id=='pbzmc:lava'then
  if not old and self.lava_count<512 then
   old={kind='lava',key=k,x=x,y=y,z=z};self.lava[k]=old;self.lava_count=self.lava_count+1
   self:schedule(old,self.tick+self:lava_delay())
  end
 elseif old then self:cancel(old);self.lava[k]=nil;self.lava_count=self.lava_count-1 end
end
function Network:changed(x,y,z)
 local cell=self:read(x,y,z);self:track_lava(x,y,z,cell)
 local e=self.fires[key(x,y,z)]
 if e and cell and not (e.surface and cell.native_terrain)then self:extinguish(e,'covered')end
 -- Support removal is local. Do not advance a fire's burn clock on every
 -- observer pulse or repeatedly refresh its lifetime with the flint held.
 for _,d in ipairs(neighbors)do
  e=self.fires[key(x+d[1],y+d[2],z+d[3])]
  if e and not cell and not e.surface then
   local odds,pending=self:neighbors(e.x,e.y,e.z,false)
   if odds==0 and not pending and not self.adapter.sturdy(self:read(e.x,e.y,e.z-1))then self:extinguish(e,'support-removed')end
  end
 end
end
function Network:fire_tick(e)
 local occupied=self:read(e.x,e.y,e.z)
 if occupied and not (e.surface and occupied.native_terrain)then
  if occupied.pending then self:schedule(e,self.tick+5);return end
  self:extinguish(e,'covered');return
 end
 local fuel,pending=self:neighbors(e.x,e.y,e.z,false);local below=self:read(e.x,e.y,e.z-1)
 local old_age=e.age;e.age=math.min(15,e.age+self:rand(3)//2)
 if fuel==0 then
  if not pending and not (below and below.pending)and not e.surface and not self.adapter.sturdy(below)then self:extinguish(e,'unsupported');return end
  if old_age>3 then self:extinguish(e,'aged');return end
 elseif old_age==15 and self:rand(4)==0 and M.fuel(below)==0 then self:extinguish(e,'aged');return end
 if fuel>0 then
  -- First compute six local burn decisions, then publish one host transaction.
  local burns={}
  for _,d in ipairs(neighbors)do
   local x,y,z=e.x+d[1],e.y+d[2],e.z+d[3];local c=self:read(x,y,z);local _,odds=M.fuel(c)
   if odds>0 and self:rand(d[4])<odds then
    burns[#burns+1]={x=x,y=y,z=z,cell=c,replace=self:rand(old_age+10)<5,age=math.min(15,old_age+self:rand(5)//4)}
   end
  end
  if #burns>0 then self.adapter.burn(burns)end
  -- Original 3 x 3 x 6 neighbourhood, upward spread up to four cells.
  -- Only local indexed reads; pending native cells stay closed.
  for dx=-1,1 do for dy=-1,1 do for dz=-1,4 do
   if dx~=0 or dy~=0 or dz~=0 then
    local x,y,z=e.x+dx,e.y+dy,e.z+dz;local k=key(x,y,z)
    if not self.fires[k]and not self:read(x,y,z)then
     local odds=self:neighbors(x,y,z,false)
     odds=math.floor((odds+40+7*self.difficulty)/(old_age+30))*(odds>0 and 1 or 0)
     if odds>0 and self:rand(100+math.max(0,dz-1)*100)<=odds then
      self:ignite(x,y,z,{age=math.min(15,old_age+self:rand(5)//4)})
     end
    end
   end
  end end end
 end
 if self.fires[e.key]==e then self:schedule(e,self.tick+30+self:rand(10))end
end
function Network:lava_tick(e)
 local c=self:read(e.x,e.y,e.z)
 if not c or c.content_id~='pbzmc:lava'then self:track_lava(e.x,e.y,e.z,c);return end
 local passes=self:rand(3)
 if passes>0 then
  local x,y,z=e.x,e.y,e.z
  for _=1,passes do
   x,y,z=x+self:rand(3)-1,y+self:rand(3)-1,z+1;c=self:read(x,y,z)
   if not c then
    if self:neighbors(x,y,z,true)>0 then self:ignite(x,y,z);break end
   elseif c.pending or self.adapter.blocks_lava(c)then break end
  end
 else
  for _=1,3 do
   local x,y=e.x+self:rand(3)-1,e.y+self:rand(3)-1
   local _,_,flammable=M.fuel(self:read(x,y,e.z))
   if flammable and not self:read(x,y,e.z+1)then self:ignite(x,y,e.z+1)end
  end
 end
 self:schedule(e,self.tick+self:lava_delay())
end
function Network:advance(tick,budget)
 assert(tick>=self.tick,'fire-time-reversed');self.tick=tick
 local done=0;local reads=self.reads
 while done<(budget or 2)and self.heap[1]and self.heap[1].due<=tick do
  local e=self.heap[1];self:cancel(e);done=done+1
  if e.kind=='fire'then self:fire_tick(e)else self:lava_tick(e)end
 end
 return {events=done,reads=self.reads-reads,pending=#self.heap,fires=self.count,lava=self.lava_count}
end
function M.new(adapter,options)
 options=options or {}
 return setmetatable({adapter=adapter,random=options.random or function(n)return math.random(0,n-1)end,
  difficulty=options.difficulty or 2,max_fires=options.max_fires or M.max_fires,
  heap={},fires={},lava={},count=0,lava_count=0,tick=0,serial=0,created=0,limited=0,reads=0},Network)
end
return M
