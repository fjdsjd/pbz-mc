local rules=require('rules.auto_defense')
local M={}
local function valid(o)return o and o.IsValid and o:IsValid()end
function M.new(pawn)
  if not valid(pawn) or not valid(pawn.CapsuleComponent)then return end
  local actor_class=StaticFindObject('/Script/Engine.Actor')
  local bullet_class=StaticFindObject('/Script/SGameCombatSystem.BulletActorBase')
  local bullet_interface=StaticFindObject('/Script/SGameCombatSystem.BulletInterface')
  local owner_of=StaticFindObject('/Script/SGameCombatSystem.BulletInterface:GetOwnerAvatar')
  local lib=StaticFindObject('/Script/Engine.Default__KismetSystemLibrary')
  local faction=StaticFindObject('/Script/SGameCombatSystem.Default__FactionUtils')
  if not valid(actor_class) or not valid(bullet_interface) or not valid(owner_of) or not valid(lib) or not valid(faction)then return end
  local body={half=pawn.CapsuleComponent:GetScaledCapsuleHalfHeight(),radius=pawn.CapsuleComponent:GetScaledCapsuleRadius()}
  local tracked={}
  local self={}
  local types=require('host.pbz.build_world').object_types
  function self:add(o,now,known)
    if not valid(o) or not o:IsA(actor_class) then return end
    if not (valid(bullet_class)and o:IsA(bullet_class))
      and not lib:DoesImplementInterface(o,bullet_interface) then return end
    -- UE can pool and relaunch the same actor. A newly received strike takes
    -- ownership of timing as soon as PBZ reports contact.
    local id=o:GetAddress()
    for _,b in ipairs(tracked)do
      if b.id==id and valid(b.o) then
        if known then b.armed=true end
        return
      end
    end
    if not known and o:GetWorld():GetAddress()~=pawn:GetWorld():GetAddress() then return end
    if #tracked>=24 then table.remove(tracked,1) end
    tracked[#tracked+1]={o=o,id=id,expires=now+2.5,armed=known}
  end
  function self:incoming(now,lead)
    if valid(bullet_class) and (not self.query_at or now>=self.query_at)then
      self.query_at=now+.25
      -- Pooled projectiles need not run BeginPlay on their next launch.
      local nearby={};lib:SphereOverlapActors(pawn,pawn:K2_GetActorLocation(),720,types,bullet_class,{pawn},nearby)
      for i=1,math.min(#nearby,8)do self:add(nearby[i]:get(),now,false)end
    end
    if #tracked==0 or self.sample and now-self.sample<.025 then return end
    self.sample=now
    local player=pawn:K2_GetActorLocation()
    local motion=pawn:GetVelocity()
    local best
    for i=#tracked,1,-1 do
      local b=tracked[i]
      if not valid(b.o) or now>=b.expires then table.remove(tracked,i)
      else
        local loc=b.o:K2_GetActorLocation()
        local x,y,z=loc.X,loc.Y,loc.Z
        local vx,vy,vz
        if b.t then
          local dt=now-b.t
          local dx,dy,dz=x-b.x,y-b.y,z-b.z
          local travel=dx*dx+dy*dy+dz*dz
          if dt>0 and dt<=.35 and travel>4 and travel<1800^2 then
            vx,vy,vz=dx/dt,dy/dt,dz/dt;b.idle=nil
          elseif travel>=1800^2 or dt>.35 then b.armed=false
          else b.idle=b.idle or now;if now-b.idle>.12 then b.armed=false end end
        else
          local velocity=b.o:GetVelocity()
          vx,vy,vz=velocity.X,velocity.Y,velocity.Z
        end
        if vx and not b.armed then
          local eta=rules.projectile_eta(x-player.X,y-player.Y,z-player.Z,vx-motion.X,vy-motion.Y,vz-motion.Z,body,lead)
          if eta then
            local owner=owner_of(b.o)
            if valid(owner) and owner:GetAddress()~=pawn:GetAddress() and faction:GetFactionRelation(pawn,owner)==2 then
              b.armed=true;best=math.min(best or eta,eta)
            end
          end
        end
        b.x,b.y,b.z,b.t=x,y,z,now
      end
    end
    return best
  end
  return self
end
return M
