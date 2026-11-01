-- Port of wukong-steve MinecraftPlacementGeometry.cs, 0.11.0
-- Commit 9f213556519dca4498fd46f02af6236ae121ecae.
-- PolyForm Noncommercial 1.0.0; see third_party/wukong-steve/{LICENSE,NOTICE}.
local M = {}
function M.capsule_overlaps(x,y,z,half_x,half_y,half_z,radius,half_height)
    local dx = math.max(0, math.abs(x)-half_x)
    local dy = math.max(0, math.abs(y)-half_y)
    local dz = math.max(0, math.abs(z)-half_z-math.max(0,half_height-radius))
    return dx*dx + dy*dy + dz*dz < radius*radius
end
function M.face_axis(x,y,z)
    if math.abs(z) >= math.max(math.abs(x),math.abs(y)) then return 2 end
    if math.abs(x) >= math.abs(y) then return 0 end
    return 1
end
return M
