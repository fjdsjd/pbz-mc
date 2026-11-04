local directory=debug.getinfo(1,'S').source:sub(2):match('^(.*)[/\\]')
local function log(message) print('[PBZMC] '..message..'\n') end
if not PBZMC_HostCompatible then log('PBZMC-HOST: missing native bridge. Run Launch-PBZMC.cmd.');return end
local compatible,detail=PBZMC_HostCompatible()
if detail then log(detail) end
if not compatible then log('PBZMC stopped. Report PBZMC-HOST and UE4SS.log at https://github.com/fjdsjd/pbz-mc/issues.');return end
local ready=io.open(directory..'/pbzmc-assets/ready.json','rb')
if not ready then
  log('Resources are not prepared. Close the game and run Launch-PBZMC.cmd.')
  return
end
ready:close()
package.path=directory..'/pbzmc/?.lua;'..directory..'/pbzmc/vendor/?.lua;'..package.path
require('host.pbz.mod').start(log,directory)
