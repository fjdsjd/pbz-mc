-- Summons share their owner's allegiance. Distances and speeds are UE centimetres.
local M = {limit = 12, detection = 1600, leash = 2800}
local entries, by_egg = {}, {}
local function mob(name, attack, speed, radius, height, damage, interval, flies)
  local row = {name=name, egg='pbzmc:'..name..'_spawn_egg', attack=attack, speed=speed,
    radius=radius, height=height, damage=damage, interval=interval, flies=flies}
  entries[#entries+1]=row
  by_egg[row.egg]=row
end
mob('zombie','melee',235,30,195,3,1)
mob('husk','melee',235,30,195,3,1)
mob('drowned','trident',235,30,195,5,2)
mob('zombie_villager','melee',235,30,195,3,1)
mob('zombified_piglin','melee',260,30,195,5,1)
mob('skeleton','arrow',250,30,199,3,1.5)
mob('stray','arrow',250,30,199,3,1.5)
mob('bogged','arrow',235,30,199,3,2.5)
mob('parched','arrow',250,30,199,3,2.4)
mob('wither_skeleton','melee',255,35,240,5,1)
mob('zoglin','melee',300,66,140,6,1.35)
mob('zombie_horse','melee',400,68,160,4,1.3)
mob('skeleton_horse','melee',400,68,160,4,1.3)
mob('camel_husk','melee',310,82,238,5,1.5)
mob('zombie_nautilus','melee',255,48,98,3,1.25)
mob('phantom','melee',420,42,60,3,1.6,true)
mob('wither','skull',285,50,315,7,2,true)
function M.list() return entries end
function M.egg(id) return by_egg[id] end
return M
