-- Only pressure plates and unwaxed copper register for periodic work. Other
-- construction blocks sleep until a cell or a neighbour actually changes.
local blocks=require('content.blocks')
local D=require('rules.block_directions')
local M={}
local function copy(t)local r={};for k,v in pairs(t or {})do r[k]=v end;return r end
local stages={'','exposed_','weathered_','oxidized_'}
local function copper(id)
  local name=id:sub(7)
  if not name:find('copper',1,true) or name:sub(1,6)=='waxed_'then return end
  for i=4,1,-1 do
    local prefix=stages[i]
    if name:sub(1,#prefix)==prefix then
      local base=name:sub(#prefix+1);if base=='copper_block'then base='copper'end
      return i,base
    end
  end
end
local function at_stage(i,base)
  return 'pbzmc:'..(i==1 and base=='copper' and 'copper_block' or stages[i]..base)
end
function M.scrape(id)
  if id:sub(7,12)=='waxed_'then return 'pbzmc:'..id:sub(13)end
  local i,base=copper(id)
  if i and i>1 then return at_stage(i-1,base)end
  local name=id:sub(7)
  if name:sub(1,9)~='stripped_' and blocks.get('pbzmc:stripped_'..name)then return 'pbzmc:stripped_'..name end
end
function M.track(service,r,restore)
  local def=blocks.get(r.content_id)
  if restore and def.family=='button' and (r.properties or {}).powered then
    service.button_due=service.button_due or {};service.button_due[r.id]=0
  end
  local stage=copper(r.content_id)
  if def.family~='plate' and not (stage and stage<4)then return end
  local queue=service.construction_devices
  if not queue then queue={ids={},known={},i=1,next=0};service.construction_devices=queue end
  if not queue.known[r.id]then queue.known[r.id]=true;queue.ids[#queue.ids+1]=r.id end
end
local function occupiers(service,r)
  local owners={};local count=0;local world=service.world
  for _,v in ipairs(world:overlap_components({X=r.x,Y=r.y,Z=r.z-36},{x=43.7,y=43.7,z=12.5},{}))do
    local component=v.GetOwner and v or v:get()
    local owner=component:GetOwner()
    if owner and owner:IsValid()then
      local id=owner:GetFullName()
      if not owners[id] and not world.by_actor[id] then
        local pc=world.pawn_class or StaticFindObject('/Script/Engine.Pawn');world.pawn_class=pc
        local object=component:GetCollisionObjectType()
        if owner:IsA(pc) or (object==5 and r.content_id~='pbzmc:stone_pressure_plate' and r.content_id~='pbzmc:polished_blackstone_pressure_plate')then
          owners[id]=true;count=count+1
        end
      end
    end
  end
  return count
end
local function oxidize(service,r,stage,base)
  local same,older=0,0;local refused=false
  -- Only after an actual vanilla random-tick trial succeeds.
  service.session:visit_nearby({x=r.x,y=r.y,z=r.z},401,function(other)
    if other.id==r.id or math.abs(other.x-r.x)+math.abs(other.y-r.y)+math.abs(other.z-r.z)>400.01 then return end
    local age=copper(other.content_id)
    if age then
      if age<stage then refused=true elseif age==stage then same=same+1 else older=older+1 end
    end
  end)
  if refused or math.random()>((older+1)/(older+same+1))^2*(stage==1 and .75 or 1)then return end
  local after=copy(r);after.content_id=at_stage(stage+1,base)
  if blocks.get(after.content_id)then
    local changes={{before=r,after=after}}
    if blocks.get(r.content_id).family=='door' then
      local pair=service:pair(r);if not pair then return end
      local second=copy(pair);second.content_id=after.content_id;changes[#changes+1]={before=pair,after=second}
    end
    service:commit(changes,nil,true)
  end
end
function M.tick(s,now)
  local q=s.construction_devices
  if not q or now<q.next or #q.ids==0 then return end
  q.next=now+.1
  for _=1,math.min(4,#q.ids)do
    if #q.ids==0 then break end
    if q.i>#q.ids then q.i=1 end
    local id=q.ids[q.i];local r=s.session.data.buildings[id]
    local def=r and blocks.get(r.content_id);local stage,base
    if r then stage,base=copper(r.content_id)end
    if not def or def.family~='plate' and not(stage and stage<4)then
      q.known[id]=nil;q.ids[q.i]=q.ids[#q.ids];q.ids[#q.ids]=nil
    else
      q.i=q.i+1
      local h=s.session.handles[id]
      if h and h.active then
        local p=s.world.pawn:K2_GetActorLocation()
        if (r.x-p.X)^2+(r.y-p.Y)^2+(r.z-p.Z)^2<6400^2 then
          if def.family=='plate' then
            local n=occupiers(s,r);local nextp=copy(r.properties or def.defaults)
            if nextp.power~=nil then nextp.power=math.min(15,math.ceil(n/(r.content_id=='pbzmc:heavy_weighted_pressure_plate' and 10 or 1)))
            else nextp.powered=n>0 end
            if not require('rules.block_properties').equal(nextp,r.properties) then
              local after=copy(r);after.properties=nextp;s:commit({{before=r,after=after}},nil,true)
            end
          elseif (r.properties or {}).half~='upper' and math.random()<1-(1-3/4096*.05688889)^(2*math.max(1,#q.ids/4)) then
            oxidize(s,r,stage,base)
          end
        end
      end
    end
  end
end
function M.powder(s,r,p)
  local down=D.step(p,'down');local bottom=s:read(down.x,down.y,down.z)
  local solid=r.content_id:gsub('_powder$','');local after=copy(r)
  for _,d in ipairs(D.order)do
    local n=D.step(p,d);local other=s.index[D.key(n.x,n.y,n.z)]
    if other and (other.content_id=='pbzmc:water' or (other.properties or {}).waterlogged)then
      after.content_id=solid;return s:commit({{before=r,after=after}},nil,true)
    end
  end
  if bottom and bottom.pending then s.supports[r.id]=true;return end
  if not bottom then after.z=after.z-100;return s:commit({{before=r,after=after}},nil,true)end
end
return M
