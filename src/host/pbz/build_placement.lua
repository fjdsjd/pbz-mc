-- Production placement entry, shared by normal input and developer observation.
local registry=require('content.blocks')
local grid=require('rules.build_grid')
local geometry=require('rules.placement_geometry')
local M={}
function M.target(self,aim,ignore_boats)
  if not self.store:current() or not self.world:is_current() then return end
  local start,direction=aim()
  local finish={X=start.X+direction.X*500,Y=start.Y+direction.Y*500,Z=start.Z+direction.Z*500}
  local ignored
  if ignore_boats then
    local boats=require('host.pbz.boat_service').get(self.binding)
    if boats then
      ignored={}
      for _,boat in pairs(boats.boats)do
        if not boat.retired and not boat.state.destroyed then ignored[#ignored+1]=boat.handle.actor end
      end
    end
  end
  local hit,result=self.world:line_trace(start,finish,ignored)
  if hit then return result,self.world:hit_handle(result) end
end
function M.position(service,hit,handle)
  if handle then
    local record=service.session.data.buildings[handle.id]
    return grid.adjacent(record,hit.ImpactNormal,service.session.grid or record)
  end
  return grid.native_surface(hit.ImpactPoint,hit.ImpactNormal,service.session.grid)
end
function M.place(self,id,aim)
  local began=os.clock()
  local definition=registry.get(id)
  if not definition or not definition.available then return false,'fail' end
  if definition.utility and self.mechanisms then return self.mechanisms:scoop(aim)end
  local hit,handle=self:target(aim,definition.fluid~=nil)
  if not hit then self.last_rejection='no-surface-in-reach';return false,'pass' end
  local owner=self.world:hit_actor(hit)
  if owner and owner:IsValid() and owner:IsA(StaticFindObject('/Script/Engine.Pawn')) then
    self.last_rejection='character-is-not-building-support';return false,'pass'
  end
  local position=M.position(self,hit,handle)
  if definition.fluid=='water' and handle and self.mechanisms then
    local r=self.session.data.buildings[handle.id];local props=r and (r.properties or registry.get(r.content_id).defaults)
    if props and props.waterlogged==false and props.type~='double' then
      local after={};for k,v in pairs(r)do after[k]=v end
      after.properties={};for k,v in pairs(props)do after.properties[k]=v end;after.properties.waterlogged=true
      local ok=self.mechanisms:commit({{before=r,after=after}})
      if ok then self.mechanisms:sound('bucket_empty',after)end
      return ok,ok and 'success' or 'fail'
    end
  end
  if definition.family=='slab' and self.mechanisms then
    local hit_record=handle and self.session.data.buildings[handle.id]
    local other=self.mechanisms:read_world(position.x,position.y,position.z)
    local rule=require('rules.construction')
    local target=rule.can_merge(hit_record,id,hit.ImpactNormal) and hit_record or
      (other and other.content_id==id and (other.properties or {}).type~='double' and other)
    if target then
      local next_record={};for k,v in pairs(target)do next_record[k]=v end
      next_record.properties={type='double',waterlogged=false}
      if not self.world:can_place(next_record,{[target.id]=true})then return false,'fail'end
      local ok=self.mechanisms:commit({{before=target,after=next_record}})
      if ok then self.audio:play('place',next_record,require('host.pbz.local_player').controller())end
      return ok,ok and 'success' or 'fail'
    end
  end
  -- Thin devices, doors and poured fluids sit above native supports. Full
  -- blocks retain the user's terrain-intersection layer.
  local normal=hit.ImpactNormal
  local face_axis=definition.mechanism=='torch' and not handle and geometry.face_axis(normal.X,normal.Y,normal.Z)
  if face_axis and face_axis~=2 then
    local axis=face_axis==0 and 'x' or 'y'
    local impact=face_axis==0 and hit.ImpactPoint.X or hit.ImpactPoint.Y
    local sign=(face_axis==0 and normal.X or normal.Y)<0 and -1 or 1
    local inside=sign*impact+50
    position[axis]=sign*(self.session.grid and grid.above(inside,sign*self.session.grid[axis]) or inside)
    local inset=math.floor(sign*position[axis]-inside+.5)
    if inset>0 then position.wall_inset=inset end
  elseif (definition.mechanism or definition.construction) and not definition.full_cube and not handle and normal.Z>.5 then
    if not self.session.grid then position.z=hit.ImpactPoint.Z+50
    elseif position.z-50<hit.ImpactPoint.Z-.5 then position.z=position.z+math.ceil((hit.ImpactPoint.Z+50-position.z)/100-1e-6)*100 end
  end
  if definition.axis then position.properties={axis=require('rules.block_properties').axis(hit.ImpactNormal)} end
  if definition.construction then
    local _,direction=aim();position.properties=require('rules.construction').placement(definition,position,hit,direction)
  end
  local transaction_started=os.clock()
  local ok,why
  if definition.mechanism and self.mechanisms then ok,why=self.mechanisms:place(definition,position,hit,aim)
  elseif self.mechanisms and self.mechanisms:read_world(position.x,position.y,position.z)then
    -- Fluid has no solid collision, but still owns its cell. Replace that
    -- record in the same batch so water cannot keep flowing through a new
    -- cube (or survive invisibly beneath it). A failed placement keeps water.
    local found=self.mechanisms:read_world(position.x,position.y,position.z)
    local before=self.session.data.buildings[found.id]
    local previous=before and registry.get(before.content_id)
    if previous and previous.fluid then
      if position.properties and position.properties.waterlogged~=nil then position.properties.waterlogged=previous.fluid=='water' end
      if definition.family=='powder' and previous.fluid=='water' then definition=registry.get(id:gsub('_powder$','')) end
      local after={id=before.id,content_id=definition.id,world=self.session.world,
        x=position.x,y=position.y,z=position.z,yaw=position.yaw or 0,properties=position.properties}
      ok,why=self.mechanisms:commit({{before=before,after=after}})
      if ok then why=after.id end
    else ok,why=false,'grid-occupied'end
  else ok,why=self.session:place(definition.id,position)end
  self.last_place_ms=(os.clock()-began)*1000
  self.last_transaction_ms=(os.clock()-transaction_started)*1000
  self.place_samples=self.place_samples or {}
  if ok then
    self.place_samples[#self.place_samples+1]=self.last_place_ms
    if #self.place_samples>32 then table.remove(self.place_samples,1) end
  end
  self.last_rejection=not ok and why or nil
  if ok then
    self.placed=self.placed+1;self.last_id=why
    local check=self.world.last_placement_check or {}
    self.log('building placed '..id..' '..why..' terrain-overlaps='..tostring(check.terrain or 0))
    if not definition.fluid then
      if definition.mechanism and not (definition.construction or definition.construction_sound) then self.mechanisms:sound((definition.sound_group or 'stone')..'_place',self.session.data.buildings[why])
      else self.audio:play('place',self.session.data.buildings[why],require('host.pbz.local_player').controller())end
    end
  end
  return ok,ok and 'success' or 'fail'
end
return M
