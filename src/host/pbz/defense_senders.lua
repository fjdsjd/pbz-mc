-- Consult the current combat target and the owners of actual incoming hits.
-- There is no actor/mesh inventory, bone sampling or work per distant enemy.
local rules=require('rules.auto_defense')
local M={}
local function valid(o)return o and o.IsValid and o:IsValid()end

function M.new(pawn)
  local faction=StaticFindObject('/Script/SGameCombatSystem.Default__FactionUtils')
  local class=StaticFindObject('/Script/PBZDeflectSystem.DeflectComponent')
  local character=StaticFindObject('/Script/ProjectPBZ.PBZCharacter')
  if not valid(pawn) or not valid(faction) or not valid(class) or not valid(character)then return end
  local system=StaticFindObject('/Script/Engine.Default__KismetSystemLibrary')
  local types=require('host.pbz.build_world').object_types
  local capsule=pawn.CapsuleComponent
  if not valid(capsule)then return end
  local body={radius=capsule:GetScaledCapsuleRadius(),half=capsule:GetScaledCapsuleHalfHeight()}
  local actors={}
  local self={next_target=0,next_check=0,next_nearby=0}
  local no_override=FName('None')
  local function remember(actor,now)
    if not valid(actor) or actor:GetAddress()==pawn:GetAddress() then return end
    local oldest=1
    for i,a in ipairs(actors)do
      if valid(a.actor) and a.actor:GetAddress()==actor:GetAddress() then a.seen=now;return end
      if a.seen<actors[oldest].seen then oldest=i end
    end
    if faction:GetFactionRelation(pawn,actor)~=2 then return end
    local comp=actor:GetComponentByClass(class)
    if not valid(comp) then return end
    local entry={actor=actor,component=comp,frames=comp.SendFrames,seen=now}
    actors[#actors<4 and #actors+1 or oldest]=entry
  end
  function self:incoming(action,now)
    for _=1,5 do
      if not valid(action)then return end
      if action:IsA(character)then remember(action,now);return end
      action=action:GetOuter()
    end
  end
  function self:consider(queue,now)
    if now>=self.next_nearby then
      self.next_nearby=now+.35
      local nearby={};system:SphereOverlapActors(pawn,pawn:K2_GetActorLocation(),280,types,character,{pawn},nearby)
      for i=1,math.min(#nearby,4)do remember(nearby[i]:get(),now)end
    end
    if now>=self.next_target then
      self.next_target=now+.24
      local camera=pawn.NBCamera
      if valid(camera)then
        local lock=camera:GetCurrentLockComponent()
        if valid(lock)then remember(lock:GetOwner(),now)
        elseif valid(camera.LockOnTargetObject)then remember(camera.LockOnTargetObject:GetTargetActor(no_override),now)end
      end
    end
    if #actors==0 or now<self.next_check then return end
    self.next_check=now+.025
    local player
    for i=#actors,1,-1 do
      local a=actors[i]
      if now-a.seen>5 or not valid(a.actor) or not valid(a.component) then table.remove(actors,i)
      elseif #a.frames>0 then
        player=player or pawn:K2_GetActorLocation()
        local loc=a.actor:K2_GetActorLocation()
        local dx,dy,dz=player.X-loc.X,player.Y-loc.Y,player.Z-loc.Z
        if dx*dx+dy*dy<=320*320 and math.abs(dz)<=body.half+65 then
          local rot=a.actor:K2_GetActorRotation()
          a.frames:ForEach(function(k,v)
            local row=v:get()
            local left=row.HitGameTime-now
            if left < -math.min(.045,queue.step) or left>queue.lead or row.Paused or #row.Receivers~=0
                or valid(row.CurrentHitActor) then return end
            if #row.IgnoredActors>0 then
              for _,wrap in ipairs(row.IgnoredActors)do
                local actor=wrap:get()
                if valid(actor) and actor:GetAddress()==pawn:GetAddress() then return end
              end
            end
            if rules.in_sweep(dx,dy,dz,rot.Yaw+row.AttackDirection.Yaw,row.DeflectRadius,row.DeflectAngle,body) then
              rules.consider(queue,k:get(),row.HitGameTime,true,false,true)
            end
          end)
        end
      end
    end
  end
  return self
end
return M
