-- Lease only the verified player bars. Boss, potion, subtitles, tutorial and
-- lock-on widgets are never traversed/hidden. Restore on failure or cinematic.
local identity=require('host.pbz.object_identity')
local valid=require('host.pbz.appearance').valid
local M={};M.__index=M
function M.new(binding)return setmetatable({binding=binding,entries={}},M)end
function M:apply(now)
 if not self.next_scan or now>=self.next_scan then
  self.next_scan=now+1
  for _,owner in ipairs(FindAllOf('WB_PlayerHPBar_V1_C') or {}) do
   if valid(owner) and owner:GetFullName():find('/Engine/Transient.',1,true) and
      identity.matches(owner:GetWorld(),self.binding.world_id) then
    for _,name in ipairs({'AnimHPBar_1','Image_HpBG','AnimBreakmeterBar','Image_ShaChiBarBG','Image_ShaChiBarRedGlow',
      'NS_UI_ShaChiBar_Full_002','NS_UI_ShaChiBar_Full_001','NS_UI_ShaChiBar_Break_001'}) do
     local object=owner[name]
     if valid(object) and object:IsA(StaticFindObject('/Script/UMG.Widget')) then
      local id=identity.capture(object)
      if not self.entries[id.address] then self.entries[id.address]={object=object,id=id,previous=object:GetVisibility()} end
     end
    end
   end
  end
 end
 for key,e in pairs(self.entries) do
  if not identity.matches(e.object,e.id) then self.entries[key]=nil
  else local visibility=e.object:GetVisibility()
   if visibility~=1 then e.previous=visibility;e.object:SetVisibility(1) end
  end
 end
end
function M:release()
 for _,e in pairs(self.entries) do
  if identity.matches(e.object,e.id) and e.object:GetVisibility()==1 then e.object:SetVisibility(e.previous) end
 end
 self.entries={};self.next_scan=nil
end
return M
