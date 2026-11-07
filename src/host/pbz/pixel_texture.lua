-- Imported PNGs already have a GPU sampler. A Filter property write alone
-- leaves that sampler linear. Refresh our resource once before caching it.
local M={}
function M.configure(texture)
  assert(texture and texture:IsValid(),'pixel-texture-import-failed')
  local path=texture:GetFullName():match('^Texture2D (/Engine/Transient%.Texture2D_%d+)$')
  assert(path,'pixel-texture-not-owned-transient')
  assert(type(PBZMC_RefreshPixelTexture)=='function','pixel-texture-bridge-missing: reinstall the matching PBZMC native bridge')
  texture.Filter=0
  local ok,why=PBZMC_RefreshPixelTexture(path)
  assert(ok,why or 'pixel-texture-resource-refresh-failed')
  return texture
end
return M
