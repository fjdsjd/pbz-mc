-- Gameplay policy is stored in the existing player core, never a new inventory
-- profile. PBZ's project-specific infinite building/no durability rules remain.
local M={names={'creative','survival'}}
function M.valid(mode)return mode=='creative' or mode=='survival'end
function M.get(core)return core and core.game_mode or 'survival'end
function M.creative(core)return M.get(core)=='creative'end
function M.action(core,profile)return M.creative(core) and 'creative' or (profile or 'free')end
function M.change(core,mode)
 assert(M.valid(mode),'unsupported-game-mode')
 if M.get(core)==mode then return core end
 local next=require('storage.state').object();for k,v in pairs(core)do next[k]=v end
 next.game_mode=mode;return next
end
return M
