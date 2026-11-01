-- Original MC display -> local UE component transform. This is only the item
-- context transform; the hand/ground/GUI holder is a separate parent transform.
-- Input geometry is already centered. Never subtract (8,8,8) again here.
local frame=require('presentation.native_steve_pose')
local M={}
local contexts={thirdperson_righthand=true,thirdperson_lefthand=true,
  firstperson_righthand=true,firstperson_lefthand=true,head=true,gui=true,ground=true,fixed=true}
local function finite(v) return type(v)=='number' and v==v and math.abs(v)<math.huge end
local function vector(x,y,z) return {X=x,Y=y,Z=z} end
local function basis(x,y,z) return vector(z,-x,y) end
local function numbers(value,default,limit)
  value=value or default
  assert(type(value)=='table' and #value==3,'invalid-item-display-vector')
  local result={}
  for i=1,3 do
    assert(finite(value[i]),'nonfinite-item-display-value')
    result[i]=limit and math.max(-limit,math.min(limit,value[i])) or value[i]
  end
  return result
end
function M.solve(display,context,units)
  assert(contexts[context],'unsupported-item-display-context')
  assert(finite(units) and units>0 and units<1000,'invalid-item-model-scale')
  -- Parent/fallback resolution is already fixed in the versioned manifest.
  local entry=assert(display[context],'missing-resolved-item-display')
  local r=numbers(entry.rotation,{0,0,0})
  local t=numbers(entry.translation,{0,0,0},80)
  local s=numbers(entry.scale,{1,1,1},4)
  if context:sub(-8)=='lefthand' then t[1]=-t[1];r[2]=-r[2];r[3]=-r[3] end
  local cx,sx=math.cos(math.rad(r[1])),math.sin(math.rad(r[1]))
  local cy,sy=math.cos(math.rad(r[2])),math.sin(math.rad(r[2]))
  local cz,sz=math.cos(math.rad(r[3])),math.sin(math.rad(r[3]))
  local function rotated(x,y,z)
    -- JOML rotationXYZ = Rx * Ry * Rz: points are rotated Z, then Y, then X.
    x,y=x*cz-y*sz,x*sz+y*cz
    x,z=x*cy+z*sy,-x*sy+z*cy
    y,z=y*cx-z*sx,y*sx+z*cx
    return basis(x,y,z)
  end
  local axes=frame.frame(rotated(0,0,1),rotated(0,1,0))
  return {position=basis(t[1]*units,t[2]*units,t[3]*units),rotation=axes.rotation,
    scale=vector(s[3],s[1],s[2])}
end
return M
