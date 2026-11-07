local defs=require('content.summon_mobs')
local rules=require('rules.mob_spawner')
local identity=require('host.pbz.object_identity')
local M={};M.__index=M
local block_id='pbzmc:spawner'

function M.new(build,acquire)
  return setmetatable({build=build,acquire=acquire,cages={},armed={},previews={},cursor=1,
    count=0,clock=0,spawned=0},M)
end

function M:hide(row)
  local p=row.preview
  if not p then return end
  if identity.matches(p.actor,p.id) then p.actor:K2_DestroyActor() end
  row.preview=nil;self.previews[row]=nil
end

function M:changed(changes)
  for _,change in ipairs(changes) do
    local old,block=change.before,change.after
    if (old and old.content_id==block_id) or (block and block.content_id==block_id) then
      local id=(block or old).id
      local row=self.cages[id]
      local egg=block and block.content_id==block_id and block.properties and block.properties.spawn_egg
      local def=egg and defs.egg(egg) or nil
      if row and (not block or block.content_id~=block_id or row.def~=def) then
        self:hide(row)
        if row.index then
          local last=self.armed[#self.armed]
          last.index=row.index;self.armed[row.index]=last;self.armed[#self.armed]=nil
        end
        self.cages[id]=nil;self.count=self.count-1;row=nil
      end
      if block and block.content_id==block_id then
        if not row then
          row={def=def,remaining=rules.initial,yaw=0}
          self.cages[id]=row;self.count=self.count+1
          if def then row.index=#self.armed+1;self.armed[row.index]=row end
        end
        row.block=block
      end
    end
  end
end

function M:use_egg(def,aim)
  if self.count==0 then return end
  local _,handle=self.build:target(aim)
  local row=handle and self.cages[handle.id]
  if not row then return end
  if row.def==def then return true,'success' end
  local block=row.block
  local after={};for k,v in pairs(block) do after[k]=v end
  after.properties=require('rules.block_properties').copy(block.properties) or {}
  after.properties.spawn_egg=def.egg
  local ok,why=self.build.session:batch({{before=block,after=after}})
  if not ok then self.build.log('spawner configuration failed: '..tostring(why));return false,'fail' end
  return true,'success'
end

function M:show(row,player,distance)
  if row.preview then
    if identity.matches(row.preview.actor,row.preview.id) then
      row.preview.actor:K2_SetActorRotation({Pitch=0,Yaw=row.yaw,Roll=0},false)
      if self.clock>=(row.emit_at or 0) then
        local tnt=require('host.pbz.tnt_service').get(self.build.binding)
        if tnt then tnt:visual(tnt.fx.spawner,tnt.fx,row.block) end
        row.emit_at=self.clock+.35
      end
      return
    end
    self:hide(row)
  end
  if self.visual_budget==0 or (row.retry_visual or 0)>self.clock then return end
  local count,furthest,far_distance=0,nil,0
  for other in pairs(self.previews) do
    count=count+1
    local d=rules.distance(other.block,player)
    if d>far_distance then furthest,far_distance=other,d end
  end
  if count>=6 then
    if distance+10000>=far_distance then return end
    self:hide(furthest)
  end
  self.visual_budget=0
  local group=self.acquire()
  local ok,result=pcall(group.world.models.preview,group.world.models,row.def,row.block)
  if ok then
    row.preview=result;self.previews[row]=true
  else
    if row.visual_error~=tostring(result) then self.build.log('spawner preview failed: '..tostring(result)) end
    row.visual_error=tostring(result);row.retry_visual=self.clock+10
  end
end

function M:advance(row,elapsed)
  row.remaining=math.max(0,row.remaining-elapsed)
  if row.remaining>0 or self.attempt_budget<=0 then return end
  local group=self.acquire()
  if #group.mobs>=defs.limit or rules.nearby(row.block,row.def,group.mobs)>=rules.nearby_limit then
    row.remaining=rules.delay(math.random);row.attempts=nil;row.success=nil;return
  end
  self.attempt_budget=self.attempt_budget-1
  row.attempts=(row.attempts or rules.attempts)-1
  local p=group.world:cage_position(row.def,row.block,group:ignored())
  if p and group:spawn(row.def,p) then
    self.spawned=self.spawned+1;row.success=true
    self.attempt_budget=0 -- spread native character construction across game ticks
  end
  if row.attempts==0 then
    row.remaining=row.success and rules.delay(math.random) or 1
    row.attempts=nil;row.success=nil
  end
end

function M:visit(row,player)
  local distance=rules.distance(row.block,player)
  if distance>rules.activation^2 then self:hide(row);row.seen=nil;return end
  local elapsed=self.clock-(row.seen or self.clock)
  row.seen=self.clock
  row.yaw=(row.yaw+elapsed*20000/(row.remaining*20+200))%360
  self:show(row,player,distance)
  self:advance(row,elapsed)
end

function M:tick(now)
  local n=#self.armed
  if n==0 or not self.acquire then self.last=nil;return end
  if self.last and now>=self.last and now-self.last<.1 then return end
  self.clock=self.clock+math.min(.25,math.max(0,now-(self.last or now)))
  self.last=now
  local player=self.build.binding.actor:K2_GetActorLocation()
  self.visual_budget=1;self.attempt_budget=2
  local first=(self.cursor-1)%n+1
  local checks=math.min(16,n)
  for offset=0,checks-1 do
    local row=self.armed[(first+offset-1)%n+1]
    if not row.retry or self.clock>=row.retry then
      local ok,err=pcall(self.visit,self,row,player)
      if not ok then
        local message=tostring(err)
        if row.error~=message then self.build.log('spawner '..row.block.id..' update failed: '..message) end
        row.error=message;row.retry=self.clock+2;row.seen=nil
      else
        row.error=nil;row.retry=nil
      end
    end
  end
  -- Rotate first priority even when every nearby cage fits in one batch.
  self.cursor=(first-1+(checks==n and 1 or checks))%n+1
end

function M:close()
  for row in pairs(self.previews) do self:hide(row) end
  self.cages={};self.armed={};self.count=0;self.last=nil
end
return M
