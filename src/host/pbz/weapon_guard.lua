-- The dragon-pillar challenger uses PBZ's Shachi break window. Choose one
-- damage channel at contact, including for arrows already in flight.
local valid=require('host.pbz.appearance').valid
local M={}
local class_name='BP_Monster_MoTian_LongZhu_01'
local challenger='/PBZCombatAsset/ActorData/Mobs/067_MoTian/'..class_name..'.'..class_name..'_C'
local break_tag

local function challenger_class(cache,class)
  local name=class:GetFullName()
  if cache[name]~=nil then return cache[name] end
  local ancestor=class
  while valid(ancestor) do
    local path=ancestor:GetFullName():match('^[^ ]+ (.+)$')
    if path==challenger then
      cache[name]=true
      return true
    end
    ancestor=ancestor:GetSuperStruct()
  end
  cache[name]=false
  return false
end

local function finite(value)
  return type(value)=='number' and value==value and math.abs(value)<math.huge
end

function M.prepare(cache,target,pawn,request,amount)
  if not challenger_class(cache,target:GetClass()) then return end
  local attrs=target.AttributeSetBase
  local current,maximum,minimum=attrs.Shachi.CurrentValue,attrs.Shachi_Max.CurrentValue,attrs.Shachi_Min.CurrentValue
  assert(finite(current) and finite(maximum) and finite(minimum),'mc-shachi-attribute-invalid')
  if maximum<=minimum or current<=minimum then return current end
  -- The meter may already be refilling during PBZ's punish window.
  local death=target['Death Component']
  local state=valid(death) and death['Actor State Component']
  if valid(state) then
    break_tag=break_tag or {TagName=FName('CharacterState.Stand.Break')}
    if state:InExactState(break_tag) then return current end
  end
  local hp_max=attrs.Health_Max.CurrentValue
  assert(finite(hp_max) and hp_max>0 and finite(amount) and amount>0,'mc-shachi-hit-scale-invalid')
  local attack=pawn.AttributeSetBase.ShachiAttack.CurrentValue
  assert(finite(attack) and attack>0,'mc-shachi-attack-snapshot-invalid')
  request.phase='shachi'
  local points=(maximum-minimum)*math.min(1,amount/hp_max)
  request.coefficient=math.min(1000,points/attack)
  return current
end

function M.observe(report,before,target)
  if before==nil then return end
  report.native_shachi_before=before
  if valid(target) and valid(target.AttributeSetBase) then
    local after=target.AttributeSetBase.Shachi.CurrentValue
    if finite(after) then
      report.native_shachi_after=after
      report.native_shachi_delta=before-after
      report.native_shachi_hit=report.dispatched and not report.blocked and before>after
    end
  end
end
return M
