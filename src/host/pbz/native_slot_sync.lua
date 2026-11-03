-- Low-frequency reconciliation of live PBZ equipment slots into the shared
-- in-memory inventory. It neither equips weapons nor writes a save/checkpoint.
local identity=require('host.pbz.object_identity')
local native=require('rules.native_slot_reference')
local slots=require('rules.container_slots')
local M={}
function M.poll(session,binding)
  if session.session.opened or session.session.busy or session.restart_frozen or binding.mc_native_selection_pending then return false end
  local game=StaticFindObject('/Script/Engine.Default__GameplayStatics')
  local now=game:GetTimeSeconds(binding.actor)
  local cache=session.native_slot_sync
  if not cache then cache={next_time=0,reads=0,commits=0};session.native_slot_sync=cache end
  if now<cache.next_time then return false end
  cache.next_time=now+1
  local ok,changed=pcall(function()
    local camera=require('host.pbz.first_person_camera').get()
    if camera and camera:native_takeover() then return false end
    local pc=require('host.pbz.local_player').controller()
    assert(pc and pc:IsValid() and pc:IsLocalPlayerController()
      and identity.matches(pc.Pawn,binding.actor_id),'slot-sync-local-player')
    if cache.reader and not identity.matches(pc,cache.controller_id) then cache.reader:close();cache.reader=nil end
    if not cache.reader then
      cache.reader=assert(require('host.pbz.native_equipment').new(binding,pc,session.epoch))
      cache.controller_id=identity.capture(pc)
    end
    local snapshot,why=cache.reader:read(session.epoch);assert(snapshot,why)
    local runtime;runtime,why=cache.reader:read_runtime(session.epoch,{selection=true});assert(runtime,why)
    local main=runtime.slots['Weapon.Slot.Main']
    assert(main and main.count==#snapshot.main_weapons,'slot-sync-transition-count')
    if runtime.in_weapon_transition or main.with_pending_differs then return false end
    cache.reads=cache.reads+1;cache.snapshot=snapshot
    local names=snapshot.weapon_names or {}
    local signature=table.concat(snapshot.main_weapons,'\0')..'\1'..table.concat(snapshot.shaqi_weapons,'\0')
      ..'\2'..table.concat(names.main or {},'\0')..'\3'..table.concat(names.shaqi or {},'\0')
    if cache.signature==signature and ((cache.report and cache.report.pending==0)
      or cache.generation==session.store.generation) then return false end
    local ticket=session.store:checkout({})
    local updated,report=require('rules.native_slot_inventory').refresh(ticket.data.containers,snapshot,session.epoch,
      require('content.items'),{defer_additions=true,skip_selected_empty=true})
    cache.report=report
    if updated~=ticket.data.containers then
      local selected=slots.get(ticket.data.containers,'player/hotbar/'..ticket.data.containers.player.selected)
      if native.is(selected) and not native.resolve(selected,snapshot,session.epoch)
        and not require('host.pbz.native_input_dispatch').action_idle(pc,function()return binding:is_current()end) then return false end
      local candidate=require('storage.state').object()
      for key,value in pairs(ticket.data)do candidate[key]=value end;candidate.containers=updated
      -- Removal of an actively selected native reference requires an explicit
      -- observed-native-state authorization, not an arbitrary inventory edit.
      local previous_authority=session.selection_authority
      session.selection_authority=function(before,after)
        return native.is(before) and not after and not native.resolve(before,snapshot,session.epoch)
      end
      local committed,reason=session.session:commit(ticket,candidate)
      session.selection_authority=previous_authority;assert(committed,reason)
      cache.commits=cache.commits+1
    end
    if cache.signature~=signature then
      session.store.selection_revision=(session.store.selection_revision or session.store.generation)+1
    end
    cache.signature=signature;cache.generation=session.store.generation;cache.error=nil
    return updated~=ticket.data.containers
  end)
  if not ok then cache.error=tostring(changed);return false end
  return changed
end
return M
