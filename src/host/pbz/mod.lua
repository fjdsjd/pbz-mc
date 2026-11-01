-- Production entry. Input, original-resource UI and persistence start with the
-- mod. Development tooling lives outside the distributable runtime.
local M={}
function M.start(log,directory)
  log('PBZ x Minecraft runtime started; permanent Steve and persistent inventory')
  require('host.pbz.appearance_lifecycle').start(log,directory..'/pbzmc-assets')
  require('host.pbz.first_person_camera').start(log)
  require('host.pbz.item_interface').start(log,directory)
end
return M
