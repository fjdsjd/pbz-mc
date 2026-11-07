-- Contact payloads from vanilla 26.3 mob/projectile classes (normal difficulty).
-- PBZMC companions never deliberately inflict harmful effects on their owner.
local M={}
local contact={cave_spider={'poison',140},bee={'poison',200},pufferfish={'poison',180},
 wither_skeleton={'wither',200},stray={'slowness',600},bogged={'poison',100},
 parched={'weakness',600},shulker={'levitation',200},wither={'wither',200,1}}
function M.contact(name)return contact[name]end
function M.witch(distance,health,effects,random)
 if distance>=800 and not effects.slowness then return 'slowness'end
 if health>=8 and not effects.poison then return 'poison'end
 if distance<=300 and not effects.weakness and random()<.25 then return 'weakness'end
 return 'harming'
end
M.aura={elder_guardian={id='mining_fatigue',ticks=6000,amplifier=2,interval=60,radius=5000},
 warden={id='darkness',ticks=260,amplifier=0,interval=6,radius=2000}}
return M
