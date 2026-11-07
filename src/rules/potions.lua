-- Numeric rules from vanilla 26.3. World units are centimetres, effects 20 Hz.
local reference=require('content.potion_reference')
local M={reference=reference,forms={'potion','splash_potion','lingering_potion'},limit=16,cloud_limit=16}
local entries={}
for name,potion in pairs(reference.potions)do
 for _,form in ipairs(M.forms)do
  local id='pbzmc:'..form..'_'..name
  entries[id]={id=id,name=name,form=form,color=potion.color,effects=potion.effects,label=potion.names[form],
   -- Luck affects vanilla fishing/loot tables, neither of which PBZMC owns.
   available=name~='luck'and name~='wind_charged'and name~='weaving'and name~='oozing'and name~='infested'}
 end
end
function M.get(id)return entries[id]end
function M.all()return entries end
function M.instant(id,amplifier,scale,undead)
 local heal=(id=='instant_damage')==undead
 local value=math.floor((heal and 4 or 6)*2^math.min(amplifier,20)*(scale or 1)+.5)
 return heal and value or -value
end
function M.immune(id,name)
 local undead={zombie=true,husk=true,drowned=true,zombie_villager=true,zombified_piglin=true,
  skeleton=true,stray=true,bogged=true,wither_skeleton=true,wither=true,phantom=true,
  zombie_horse=true,skeleton_horse=true,zoglin=true}
 if (id=='regeneration'or id=='poison')and undead[name]then return true end
 if id=='poison'and (name=='spider'or name=='cave_spider')then return true end
 if id=='wither'and (name=='wither'or name=='wither_skeleton')then return true end
 if id=='weakness'and name=='parched'then return true end
 return false
end
function M.undead(name)return M.immune('regeneration',name)end
function M.splash(distance)return math.max(0,1-distance/400)end
function M.scaled(effect,scale)
 return math.floor(effect.ticks*scale+.5)
end
function M.cloud()
 return {age=0,radius=300,wait=10,duration=600,victims={}}
end
function M.cloud_tick(c)
 c.age=c.age+1
 if c.age>=c.wait then c.radius=c.radius-.5 end
 return c.age<c.wait+c.duration and c.radius>=50,c.age>=c.wait and c.age%5==0
end
function M.cloud_hit(c,id)
 if c.victims[id]and c.age<c.victims[id]then return false end
 c.victims[id]=c.age+20;c.radius=c.radius-50;return true
end
return M
