-- Reversible presentation leases; no material replacement or per-frame search.
local valid=require('host.pbz.appearance').valid
local identity=require('host.pbz.object_identity')
local M={}
local transform={Rotation={X=0,Y=0,Z=0,W=1},Translation={X=0,Y=0,Z=0},Scale3D={X=1,Y=1,Z=1}}
function M.update(owner,s)
 local h=s.handle;local invisible=s.values.invisibility~=nil
 if s.invisible~=invisible then
  if invisible then s.hidden_before=h.actor.bHidden;h.actor:SetActorHiddenInGame(true)
  elseif s.invisible and h.actor.bHidden then h.actor:SetActorHiddenInGame(s.hidden_before==true)end
  s.invisible=invisible
 end
 if not h.player then return end
 owner.binding.mc_effect_invisible=invisible
 local vision=s.values.night_vision and 'light'or s.values.blindness and 'blind'or s.values.darkness and 'dark'
 if vision~=s.vision then
  if not vision then
   if identity.matches(s.post,s.post_id)then s.post:K2_DestroyComponent(h.actor)end;s.post=nil;s.post_id=nil
  else
   if not identity.matches(s.post,s.post_id)then
    s.post=h.actor:AddComponentByClass(StaticFindObject('/Script/Engine.PostProcessComponent'),false,transform,false)
    assert(valid(s.post),'effect-vision-component');s.post_id=identity.capture(s.post)
    s.post.bUnbound=true;s.post.Priority=100;s.post.BlendWeight=1
   end
   local settings=s.post.Settings
   settings.bOverride_AutoExposureBias=true;settings.AutoExposureBias=vision=='light'and 3 or -4
   settings.bOverride_VignetteIntensity=true;settings.VignetteIntensity=vision=='light'and 0 or 1
   s.post.Settings=settings
  end
  s.vision=vision
 end
end
return M
