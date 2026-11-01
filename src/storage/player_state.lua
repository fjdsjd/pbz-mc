-- One ownership domain: fixed inventory, loaded ender pages, buildings and drops.
-- Unloaded pages are held by player_store's manifest, never treated as empty.
local state=require('storage.state')
local containers=require('rules.container_slots')
local world_items=require('rules.world_items')
local vehicles=require('rules.vehicle_state')
local M={}
function M.empty()
  return state.object({schema=1,containers=containers.empty(),
    buildings=state.object(),world_items=state.object()})
end
function M.validate(data,definitions)
  assert(type(data)=='table' and data.schema==1,'unsupported-player-schema')
  assert(data.game_mode==nil or require('rules.game_mode').valid(data.game_mode),'invalid-game-mode')
  state.validate_buildings(data.buildings)
  state.validate_building_grids(data.building_grids)
  vehicles.validate(data.vehicles)
  if data.mc_status then require('rules.status_effects').validate(data.mc_status) end
  world_items.validate_state(data,definitions)
  return true
end
return M
