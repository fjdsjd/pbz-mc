-- Names come from PBZ's localized equipment rows, never an equipment-ID list.
-- Only the schema/API contract is fixed; returned names stay runtime data.
local identity=require('host.pbz.object_identity')
local M={};local checked={}
local specs={main={method='GetMainWeaponTableDataByIndex',row='/Script/ProjectPBZ.WeaponData',offset=40,values='main_weapons'},
  shaqi={method='GetShaqiWeaponTableDataByIndex',row='/Script/ProjectPBZ.ShaqiWeaponData',offset=48,values='shaqi_weapons'}}
local function getter(category)
  local spec=specs[category];local path='/Script/ProjectPBZ.PBZBackPackSubsystem:'..spec.method
  local fn=StaticFindObject(path)
  assert(fn and fn:IsValid(),'native-name-getter-unavailable')
  if checked[category] and identity.matches(fn,checked[category])then return fn end
  assert(fn:GetFullName()=='Function '..path and fn:GetFunctionFlags()==67240961,'native-name-getter-schema')
  local count=0;local row
  fn:ForEachProperty(function(p)
    count=count+1
    if count==1 then assert(p:GetFullName()=='IntProperty '..path..':Index' and p:GetOffset_Internal()==0)
    elseif count==2 then
      assert(p:GetFullName()=='StructProperty '..path..':ReturnValue' and p:GetOffset_Internal()==8)
      row=p:GetStruct();assert(row:GetFullName()=='ScriptStruct '..spec.row)
    else error('native-name-extra-parameter')end
  end);assert(count==2,'native-name-missing-parameter')
  local name
  row:ForEachProperty(function(p)
    if p:GetFName():ToString()=='WeaponName'then
      assert(p:GetFullName()=='StructProperty '..spec.row..':WeaponName' and p:GetOffset_Internal()==spec.offset)
      name=p:GetStruct();assert(name:GetFullName()=='ScriptStruct /Script/ProjectPBZ.FlowLocText')
    end
  end);assert(name,'native-name-field-unavailable')
  local expected={Namespace={'StrProperty',0},Key={'StrProperty',16},ValueCache={'TextProperty',32}};local seen=0
  name:ForEachProperty(function(p)
    local key=p:GetFName():ToString();local e=expected[key]
    assert(e and p:GetFullName()==e[1]..' /Script/ProjectPBZ.FlowLocText:'..key and p:GetOffset_Internal()==e[2])
    seen=seen+1
  end);assert(seen==3,'native-name-localization-schema')
  checked[category]=identity.capture(fn);return fn
end
function M.read(reader,snapshot)
  local signature=table.concat(snapshot.main_weapons,'\0')..'\1'..table.concat(snapshot.shaqi_weapons,'\0')
  local now=os.clock();local cache=reader.weapon_names_cache
  local owner=reader.subsystem;assert(identity.matches(owner,reader.subsystem_id),'native-name-owner-changed')
  if cache and cache.signature==signature and now<cache.until_time then return cache.names end
  local names={main={},shaqi={}}
  for category,spec in pairs(specs)do
    for i,id in ipairs(snapshot[spec.values])do
      local value=''
      if id~='' and id:lower()~='none'then
        local row=getter(category)(owner,i-1)
        value=row.WeaponName.ValueCache:ToString()
        assert(type(value)=='string' and #value<=2048,'native-name-invalid-text')
      end
      names[category][i]=value
    end
  end
  assert(identity.matches(owner,reader.subsystem_id),'native-name-owner-changed')
  reader.weapon_names_cache={signature=signature,until_time=now+1,names=names}
  return names
end
return M
