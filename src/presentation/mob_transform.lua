-- Bedrock axes -> the same UE basis used by mesh_bundle.decode. Preserve the
-- entire rotation, rather than assigning one source axis to one UE Euler angle.
local M={}
local rad=math.pi/360
local function multiply(a,b)
 return {a[4]*b[1]+a[1]*b[4]+a[2]*b[3]-a[3]*b[2],
 a[4]*b[2]-a[1]*b[3]+a[2]*b[4]+a[3]*b[1],a[4]*b[3]+a[1]*b[2]-a[2]*b[1]+a[3]*b[4],
 a[4]*b[4]-a[1]*b[1]-a[2]*b[2]-a[3]*b[3]}
end
local function quaternion(r)
 local x,y,z=-r[1]*rad,r[2]*rad,-r[3]*rad
 local sx,cx,sy,cy,sz,cz=math.sin(x),math.cos(x),math.sin(y),math.cos(y),math.sin(z),math.cos(z)
 return {sx*cy*cz-cx*sy*sz,cx*sy*cz+sx*cy*sz,cx*cy*sz-sx*sy*cz,cx*cy*cz+sx*sy*sz}
end
local function local_rotation(pose)
 local q=quaternion(pose.rotation)
 for _,row in ipairs(pose.ordered or {})do local r={0,0,0};r[row[1]]=row[2];q=multiply(q,quaternion(r))end
 return q
end
function M.rotation(pose,poses,rig,name)
 local q=local_rotation(pose)
 if pose.entity_rotation and poses then
   local parent=rig[name].parent;local inherited={0,0,0,1}
   while parent and poses[parent]do
     local p=poses[parent];inherited=multiply(local_rotation(p),inherited)
     if p.entity_rotation then break end
     parent=rig[parent].parent
   end
   q=multiply({-inherited[1],-inherited[2],-inherited[3],inherited[4]},q)
 end
 local x,y,z,w=-q[3],-q[1],q[2],q[4]
 return {Pitch=math.deg(math.asin(math.max(-1,math.min(1,2*(z*x-w*y))))),
   Yaw=math.deg(math.atan(2*(w*z+x*y),1-2*(y*y+z*z))),
   Roll=math.deg(math.atan(-2*(w*x+y*z),1-2*(x*x+y*y)))}
end
function M.position(p,parent,units,offset)
 parent=parent or {0,0,0}
 return {X=-(p[3]-parent[3])*units,Y=-(p[1]-parent[1])*units,Z=(p[2]-parent[2])*units+(offset or 0)}
end
return M
