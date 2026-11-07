-- Host adapter for local vanilla burning. Only owned MC blocks are fuel;
-- native scenery is support/occlusion, never a demolition target.
local Rules=require('rules.fire_network')
local Blocks=require('content.blocks')
local D=require('rules.block_directions')
local M={};M.__index=M
function M.new(service)
 local self=setmetatable({service=service,mechanisms=service.build.mechanisms,pending={},after={},burned=0,primed=0},M)
 if not self.mechanisms then return self end
 self.network=Rules.new({
  read=function(x,y,z)return self.mechanisms:read(x,y,z)end,
  sturdy=function(cell)
   if not cell or cell.pending then return false end
   if cell.native_terrain then return true end
   local d=Blocks.get(cell.content_id)
   return d and (d.full_cube or d.family=='slab'and (cell.properties or {}).type~='bottom')or false
  end,
  blocks_lava=function(cell)
   if cell.native_terrain then return true end
   -- The source block tag is registry data, not material-name guessing.
   return require('content.fire_reference').lava_blockers[cell.content_id]==true
  end,
  ignite=function(e,lifetime,p)
   p=p or self.mechanisms:position(e.x,e.y,e.z)
   local ok,id=service:add_fire(p,lifetime,e.key)
   return ok,id
  end,
  extinguish=function(id,why)return service:remove_fire(id,why)end,
  burn=function(rows)
   for _,row in ipairs(rows)do
    local id=row.cell.id
    if id and not self.pending[id]then self.pending[id]=row end
   end
  end,
 })
 -- One scene-bind seed, not a render-frame search. Subsequent additions and
 -- removals arrive from the existing memory transaction notifications.
 for _,r in pairs(self.mechanisms.index)do
  if r.content_id=='pbzmc:lava'then local p=self.mechanisms:cell(r);self.network:track_lava(p.x,p.y,p.z,r)end
 end
 return self
end
function M:changed(changes)
 if not self.network then return end
 local seen={}
 for _,row in ipairs(changes)do
  for _,r in pairs({row.before,row.after})do
   local p=self.mechanisms:cell(r);local k=D.key(p.x,p.y,p.z)
   if not seen[k]then self.network:changed(p.x,p.y,p.z);seen[k]=true end
  end
 end
 if next(self.network.lava)or next(self.network.fires)or next(self.pending)then self.service:wake()end
end
function M:ignite(point,surface)
 local p=self.mechanisms:cell(point)
 return self.network:ignite(p.x,p.y,p.z,{surface=surface,position=point})
end
function M:drain()
 local s=self.service;local session=s.build.session
 if session.quarantined or session.busy or not next(self.pending)then return end
 local ids,rows={},{};local attempts=0
 for id,row in pairs(self.pending)do
  local r=session.data.buildings[id]
  local _,odds=Rules.fuel(r)
  if not r or odds==0 or r.content_id~=row.cell.content_id or r.x~=row.cell.x or r.y~=row.cell.y or r.z~=row.cell.z then self.pending[id]=nil
  elseif r.content_id=='pbzmc:tnt'then
   if attempts<1 then
    attempts=attempts+1;local ok,why=s:prime(id,4)
    if ok then self.pending[id]=nil;self.primed=self.primed+1 else self.error=why end
   end
  elseif #ids<8 then ids[#ids+1]=id;rows[id]=row end
 end
 if #ids==0 or session.quarantined or session.busy then return end
 table.sort(ids)
 local ok,why=s.build.store:environmental(function()
  return require('rules.remove_buildings')(session,ids,s.build.world,s.build.store,true)
 end)
 if not ok then self.error=why;return end
 self.burned=self.burned+#ids
 for _,id in ipairs(ids)do
  local row=rows[id];self.pending[id]=nil
  if row.replace then row.tries=0;self.after[Rules.key(row.x,row.y,row.z)]=row end
 end
 if s.build.mining and not session.data.buildings[s.build.mining]then s.build:cancel()end
end
function M:tick(dt)
 if not self.network then return end
 self.time=(self.time or 0)+dt
 self.work=self.network:advance(math.floor(self.time*20+1e-7),2)
 self:drain()
 local attempts=0
 for key,row in pairs(self.after)do
  if attempts>=2 then break end;attempts=attempts+1
  local ok,why=self.network:ignite(row.x,row.y,row.z,{age=row.age})
  row.tries=row.tries+1
  if ok or why~='occupied'and why~='pending' or row.tries>=60 then self.after[key]=nil end
 end
end
function M:has_work()return self.network and (#self.network.heap>0 or next(self.pending)or next(self.after))end
function M:state()
 local n=self.network
 return {fires=n and n.count or 0,lava=n and n.lava_count or 0,scheduled=n and #n.heap or 0,
  burned=self.burned,primed=self.primed,work=self.work,error=self.error,limited=n and n.limited or 0}
end
return M
