-- Ported from wukong-steve 0.11.0, commit 9f213556519dca4498fd46f02af6236ae121ecae.
-- MinecraftCombat.cs, MinecraftWeapons.cs, AdventureItems.cs and ModernWeaponCombat.cs.
-- PolyForm Noncommercial 1.0.0; required notices: third_party/wukong-steve/NOTICE.
-- Named content IDs only. These profiles do not mutate PBZ combat attributes.
local items=require('content.items')
local tools=require('content.tools')
local M={}
local profiles,by_kind={},{}
local materials={'wooden','stone','copper','iron','golden','diamond','netherite'}
local sword_attack={30,39,50.7,65.91,44,85.683,111.3879}
local spear_attack={31,40.3,52.39,68.107,46,88.5391,115.10083}
local spear_data={
  {.65,.7,.75,5,14,10,15,1}, {.75,.82,.7,4.5,10,9,13.75,2},
  {.85,.82,.65,4,9,8.25,12.5,2}, {.95,.95,.6,2.5,8,6.75,11.25,3},
  {.95,.7,.7,3.5,10,8.5,13.75,1}, {1.05,1.075,.5,3,7.5,6.5,10,4},
  {1.15,1.2,.4,2.5,7,5.5,8.75,5},
}
local function add(id,profile)
  assert(items.get(id) and not profiles[id],'combat-profile-content-mismatch:'..id)
  profile.content_id=id;profiles[id]=profile
  by_kind[profile.kind]=by_kind[profile.kind] or {}
  by_kind[profile.kind][#by_kind[profile.kind]+1]=id
end
for index,material in ipairs(materials) do
  add('pbzmc:'..material..'_sword',{kind='sword',attack_speed=1.6,free_melee_damage=7,
    adventure_attack=sword_attack[index],can_sweep=true})
  local pick=tools.get('pbzmc:'..material..'_pickaxe')
  add(pick.id,{kind='pickaxe',attack_speed=1.2,free_melee_damage=pick.attack_damage,
    adventure_attack=18+8*(index-1),can_sweep=false,source_version='26.3',adventure_policy='pinned-pickaxe-progression'})
  -- PBZ extension policy: preserve the baseline same-material sword's adventure
  -- scaling per free-mode damage point. This progression is not a vanilla value.
  for _,kind in ipairs({'axe','shovel'})do
    local tool=tools.get('pbzmc:'..material..'_'..kind)
    add(tool.id,{kind=kind,attack_speed=tool.attack_speed,
      free_melee_damage=tool.attack_damage,adventure_attack=sword_attack[index]*tool.attack_damage/7,
      can_sweep=false,source_version='26.3',adventure_policy='same-material-sword-per-point'})
  end
  local row=spear_data[index]
  local stats={jab=row[1],multiplier=row[2],delay=row[3],dismount=row[4],min_dismount=row[5],
    knockback=row[6],damage_seconds=row[7],base_damage=row[8]}
  local function spear(suffix,lunge)
    add('pbzmc:'..material..'_spear'..suffix,{kind='spear',attack_speed=1/stats.jab,
      free_melee_damage=stats.base_damage,adventure_attack=spear_attack[index],can_sweep=false,
      spear=stats,lunge=lunge})
  end
  spear('',0);spear('_lunge_iii',3)
  if material=='netherite' then spear('_lunge_i',1);spear('_lunge_ii',2) end
end
for _,row in ipairs({{'',0,0,0},{'_density',5,0,0},{'_breach',0,4,0},
  {'_wind_i',0,0,1},{'_wind_ii',0,0,2},{'_wind_iii',0,0,3},
  {'_density_wind',5,0,3},{'_breach_wind',0,4,3}}) do
  add('pbzmc:mace'..row[1],{kind='mace',attack_speed=.6,free_melee_damage=6,
    adventure_attack=82,can_sweep=false,density=row[2],breach=row[3],wind_burst=row[4]})
end
add('pbzmc:trident',{kind='trident',attack_speed=1.1,free_melee_damage=9,adventure_attack=88,can_sweep=false})
add('pbzmc:bow',{kind='bow',attack_speed=4,free_melee_damage=1,adventure_attack=64,can_sweep=false})
local empty={kind='hand',attack_speed=4,free_melee_damage=1,adventure_attack=8,can_sweep=false}
-- Stable registration order; consumers explicitly choose implemented families.
function M.catalogue(kind)return by_kind[kind] or {}end
function M.get(id)
  if id==nil then return empty end
  local definition=items.get(id);assert(definition,'unknown-combat-item:'..tostring(id))
  if profiles[id] then return profiles[id] end
  -- User-added tools require their own verified profiles, never sword or hand defaults.
  assert(definition.tool_kind~='axe' and definition.tool_kind~='shovel','tool-combat-profile-unavailable:'..id)
  return empty
end
return M
