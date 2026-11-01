local M={}
function M.emit(center,now,frames,random)
  random=random or math.random
  local out={}
  local function gaussian()
    return math.sqrt(-2*math.log(math.max(1e-9,random())))*math.cos(2*math.pi*random())
  end
  for _=1,32 do
    local shade=random()*.6+.4
    out[#out+1]={x=center.X,y=center.Y,z=center.Z+random()*200,vx=gaussian()*100,vy=gaussian()*100,
      start=now,life=(40+math.floor(random()*10))/20,size=10*(random()*.2+.5),
      r=shade*.9,g=shade*.3,b=shade,frame=math.min(frames-1,math.floor(random()*frames))}
  end
  return out
end
function M.mesh(particles,now,right,up,origin,frames)
  local part={positions={},normals={},uv={},colors={},triangles={}}
  local function linear(x)return x<=.04045 and x/12.92 or ((x+.055)/1.055)^2.4 end
  for _,p in ipairs(particles) do
    local f=math.max(0,math.min(1,(now-p.start)/p.life));local trajectory=1+f-2*f*f
    local size=p.size*(1-(1-f)^2);local x,y,z=p.x+p.vx*trajectory,p.y+p.vy*trajectory,p.z+100*(1-f)
    local base=#part.positions;local color={R=linear(p.r),G=linear(p.g),B=linear(p.b),A=1}
    for _,c in ipairs({{-1,-1,0,1},{1,-1,1,1},{1,1,1,0},{-1,1,0,0}}) do
      part.positions[#part.positions+1]={X=x-origin.X+right.X*c[1]*size+up.X*c[2]*size,
        Y=y-origin.Y+right.Y*c[1]*size+up.Y*c[2]*size,Z=z-origin.Z+right.Z*c[1]*size+up.Z*c[2]*size}
      part.normals[#part.normals+1]={X=0,Y=0,Z=1};part.uv[#part.uv+1]={X=(p.frame+c[3])/frames,Y=c[4]}
      part.colors[#part.colors+1]=color
    end
    for _,i in ipairs({0,1,2,0,2,3,2,1,0,3,2,0})do part.triangles[#part.triangles+1]=base+i end
  end
  return part
end
return M
