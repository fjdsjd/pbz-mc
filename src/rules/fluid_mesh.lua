-- Original MC fluid surfaces, expressed as at most six quads in PBZ cm.
-- No UObjects or world access beyond the caller's bounded neighbor callback.
local Fluid=require('rules.fluid_network')
local M={}
local EMPTY={}
local dirs={{name='north',x=0,z=-1},{name='south',x=0,z=1},{name='west',x=-1,z=0},{name='east',x=1,z=0}}
local function linear(v)return v<=0.04045 and v/12.92 or ((v+0.055)/1.055)^2.4 end
local function new_part()return {positions={},normals={},triangles={},colors={},uv={},base_uv={},face_names={}}end
local function add(part,name,points,uv,color,normal)
  local base=#part.positions;part.face_names[#part.face_names+1]=name
  for i,p in ipairs(points)do
    -- MC (x,y,z) -> PBZ (x,-z,y); input uses a unit cell with center .5.
    part.positions[#part.positions+1]={X=(p[1]-.5)*100,Y=-(p[3]-.5)*100,Z=(p[2]-.5)*100}
    part.normals[#part.normals+1]={X=normal[1],Y=-normal[3],Z=normal[2]}
    part.colors[#part.colors+1]=color;part.base_uv[#part.base_uv+1]={X=uv[i][1],Y=uv[i][2]}
    part.uv[#part.uv+1]={X=uv[i][1],Y=uv[i][2]}
  end
  for _,n in ipairs({0,1,2,0,2,3})do part.triangles[#part.triangles+1]=base+n end
end
function M.timeline(texture)
  assert(type(texture)=='table'and texture.frame_count>=1 and texture.frame_count<=256,'fluid-strip-frame-count')
  local out={ends={},frames={},cycle=0,frame_count=texture.frame_count}
  for _,entry in ipairs(assert(texture.sequence,'fluid-frame-sequence'))do
    assert(entry.index>=0 and entry.index<texture.frame_count and entry.index==math.floor(entry.index),'fluid-frame-index')
    assert(entry.ticks>=1 and entry.ticks==math.floor(entry.ticks),'fluid-frame-duration')
    out.cycle=out.cycle+entry.ticks;out.ends[#out.ends+1]=out.cycle;out.frames[#out.frames+1]=entry.index
  end
  assert(out.cycle>0 and out.cycle==texture.cycle_ticks,'fluid-frame-cycle')
  return out
end
function M.frame(timeline,tick)
  local at=math.max(0,math.floor(tick))%timeline.cycle;local lo,hi=1,#timeline.ends
  while lo<hi do local mid=math.floor((lo+hi)/2);if at<timeline.ends[mid]then hi=mid else lo=mid+1 end end
  return timeline.frames[lo]
end
function M.animate(part,frame,frame_count)
  assert(frame>=0 and frame<frame_count,'fluid-frame-index')
  for i,uv in ipairs(part.base_uv)do part.uv[i].X=uv.X;part.uv[i].Y=(frame+uv.Y)/frame_count end
end
function M.build(cell,readNeighbor,options)
  options=options or {};local id=assert(Fluid.kind(cell),'fluid-cell-required')
  local cache={['0,0,0']=cell};local reads=0;local keys={}
  local function sample(x,y,z)
    -- Internal axes here are MC; adapter axes are PBZ grid offsets.
    local k=x..','..y..','..z;local old=cache[k]
    if old~=nil then return old~=EMPTY and old or nil end
    local value=readNeighbor(x,-z,y);reads=reads+1;cache[k]=value or EMPTY;keys[#keys+1]=k
    return value
  end
  local function solid(value)
    if not value or Fluid.kind(value)then return false end
    if options.is_solid then return options.is_solid(value)==true end
    return value.full_cube==true or value.solid==true
  end
  local function height(x,y,z)
    local value=sample(x,y,z)
    if Fluid.kind(value)==id then return Fluid.height(value,sample(x,y+1,z))end
    return solid(value)and -1 or 0
  end
  local function occluded(value,dx,dy,dz,h)
    if options.occludes then return options.occludes(value,dx,-dz,dy,h)==true end
    return solid(value)and (dy~=1 or h>=1)
  end
  local center=height(0,0,0);local h={}
  local function average(dx,dz)
    if center>=1 then return 1 end
    local a,b=height(dx,0,0),height(0,0,dz)
    if a>=1 or b>=1 then return 1 end
    local total,weight=0,0
    local function accumulate(v)
      if v>=0.8 then total=total+v*10;weight=weight+10
      elseif v>=0 then total=total+v;weight=weight+1 end
    end
    if a>0 or b>0 then local corner=height(dx,0,dz);if corner>=1 then return 1 end;accumulate(corner)end
    accumulate(center);accumulate(a);accumulate(b)
    return total/weight
  end
  h.nw=average(-1,-1);h.sw=average(-1,1);h.se=average(1,1);h.ne=average(1,-1)
  local top=sample(0,1,0);local below=sample(0,-1,0)
  local up=Fluid.kind(top)~=id and not occluded(top,0,1,0,math.min(h.nw,h.sw,h.se,h.ne))
  local down=Fluid.kind(below)~=id and not occluded(below,0,-1,0,8/9)
  local bottom=down and 0.001 or 0
  if up then for key,value in pairs(h)do h[key]=math.max(bottom,value-.001)end end
  local rgb=options.tint_rgb or {255,255,255};local alpha=options.vertex_alpha or 1
  local function color(shade)return {R=linear(rgb[1]/255*shade),G=linear(rgb[2]/255*shade),B=linear(rgb[3]/255*shade),A=alpha}end
  local parts={still=new_part(),flow=new_part()};local flow_x,flow_z=0,0
  local own=(8-Fluid.level(cell))/9
  for _,d in ipairs(dirs)do
    local value=sample(d.x,0,d.z);local kind=Fluid.kind(value)
    if not kind or kind==id then
      local nh=kind==id and (8-Fluid.level(value))/9 or 0;local delta=0
      if nh>0 then delta=own-nh
      elseif not solid(value)then
        local lower=sample(d.x,-1,d.z)
        if Fluid.kind(lower)==id then delta=own-((8-Fluid.level(lower))/9-8/9)end
      end
      flow_x=flow_x+d.x*delta;flow_z=flow_z+d.z*delta
    end
  end
  if up then
    local uv={{0,0},{0,1},{1,1},{1,0}};local role='still'
    if math.abs(flow_x)>1e-9 or math.abs(flow_z)>1e-9 then
      role='flow';local angle=math.atan(flow_z,flow_x)-math.pi/2
      local s,c=math.sin(angle)*.25,math.cos(angle)*.25
      uv={{.5-c-s,.5-c+s},{.5-c+s,.5+c+s},{.5+c+s,.5+c-s},{.5+c-s,.5-c-s}}
    end
    add(parts[role],'up',{{0,h.nw,0},{0,h.sw,1},{1,h.se,1},{1,h.ne,0}},uv,color(1),{0,1,0})
  end
  if down then add(parts.still,'down',{{0,bottom,0},{1,bottom,0},{1,bottom,1},{0,bottom,1}},
    {{0,0},{1,0},{1,1},{0,1}},color(.5),{0,-1,0})end
  local sides={
    north={h.nw,h.ne,0,.001,1,.001},south={h.se,h.sw,1,.999,0,.999},
    west={h.sw,h.nw,.001,1,.001,0},east={h.ne,h.se,.999,0,.999,1}}
  for _,d in ipairs(dirs)do
    local value=sample(d.x,0,d.z);local s=sides[d.name]
    if Fluid.kind(value)~=id and not occluded(value,d.x,0,d.z,math.max(s[1],s[2]))then
      add(parts.flow,d.name,{{s[3],s[1],s[4]},{s[5],s[2],s[6]},{s[5],bottom,s[6]},{s[3],bottom,s[4]}},
        {{0,(1-s[1])*.5},{.5,(1-s[2])*.5},{.5,.5},{0,.5}},color(d.z~=0 and .8 or .6),{d.x,0,d.z})
    end
  end
  local faces=#parts.still.face_names+#parts.flow.face_names
  assert(faces<=6 and #parts.still.positions+#parts.flow.positions==faces*4,'fluid-quad-budget')
  return {sections=parts,faces=faces,heights=h,reads=reads,flow_x=flow_x,flow_z=flow_z}
end
return M
