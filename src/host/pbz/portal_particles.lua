local M={}
function M.new(binding,pc)
  return require('host.pbz.sprite_particles').new(binding,pc,'portal',require('rules.portal_particles'))
end
return M
