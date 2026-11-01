-- One catalogue choice creates one unique finite equipment instance. Nothing
-- is equipped, overwritten, consumed or persisted until the caller commits.
local state=require('storage.state')
local slots=require('rules.container_slots')
local armor=require('content.armor')
local tools=require('content.tools')
local definitions=require('content.items')
local M={};local ids,available={},{}
for _,definition in ipairs(armor.catalogue())do ids[#ids+1]=definition.id end
for _,definition in ipairs(tools.catalogue())do ids[#ids+1]=definition.id end
for _,id in ipairs(require('content.combat_profiles').catalogue('sword'))do ids[#ids+1]=id end
for _,id in ipairs(require('content.catalogue_groups').equipment)do ids[#ids+1]=id end
for _,id in ipairs(ids)do
  local definition=assert(definitions.get(id),'equipment-catalogue-definition-required:'..id)
  assert(not available[id] and definition.instance and definition.stack_limit==1,'equipment-catalogue-invalid:'..id)
  available[id]=true
end
function M.list()return ids end
function M.entries()return ids end
function M.available(id)return available[id]==true end
function M.take(core,id,campaign_id,address,options)
  assert(M.available(id),'equipment-catalogue-content-unavailable')
  assert(type(campaign_id)=='string' and #campaign_id>0 and #campaign_id<=128
    and not campaign_id:find('\0',1,true),'equipment-catalogue-scope-invalid')
  address=address or 'cursor';local area=slots.address(address)
  assert(area=='cursor' or area=='main' or area=='hotbar','equipment-catalogue-target-invalid')
  if slots.get(core.containers,address)then return core,'catalogue-target-occupied' end
  options=options or {}
  assert(options.instance_exists==nil or type(options.instance_exists)=='function','equipment-catalogue-instance-check-invalid')
  local sequence=core.equipment_catalogue_seq or 0
  assert(type(sequence)=='number' and sequence==sequence and sequence%1==0 and sequence>=0 and sequence<2^53,
    'equipment-catalogue-sequence-invalid')
  local owned={}
  slots.visit(core.containers,function(_,stack)if stack.instance_id then owned[stack.instance_id]=true end end)
  for _,record in pairs(core.world_items or {})do
    if record.stack and record.stack.instance_id then owned[record.stack.instance_id]=true end
  end
  local instance_id
  for _=1,1024 do
    sequence=sequence+1
    if sequence>=2^53 then return core,'catalogue-instance-sequence-exhausted' end
    local proposed='equipment-catalogue/'..campaign_id..'/'..string.format('%.0f',sequence)
    if not owned[proposed] and not (options.instance_exists and options.instance_exists(proposed))then instance_id=proposed;break end
  end
  if not instance_id then return core,'catalogue-instance-search-exhausted' end
  local draft=slots.edit(core.containers)
  draft:set(address,{content_id=id,count=1,instance_id=instance_id,metadata=state.object()})
  slots.validate(draft.data,definitions)
  local candidate=state.object();for key,value in pairs(core)do candidate[key]=value end
  candidate.containers=draft.data;candidate.equipment_catalogue_seq=sequence
  return candidate,{content_id=id,address=address,instance_id=instance_id,sequence=sequence}
end
return M
