-- Formal inventory ownership: exact native checkpoint -> existing player store
-- -> shared InventorySession -> immutable checkpoint -> native ordinary root.
-- Opt-in until native equipment/world-item adapters are connected. No fixture
-- migration or latest-head fallback. Corrupt MC checkpoints use an explicit,
-- separate recovery branch; the failed immutable files and PBZ progress stay.
local M={}
local json=require('dkjson')
local state=require('storage.state')
local encode=require('storage.canonical_json')
local sha=require('storage.sha256')
local fs=require('storage.file_io')
local identity=require('host.pbz.object_identity')
local UE=require('UEHelpers')
local Campaign=require('storage.campaign_store')
local Session=require('runtime.inventory_session')
local SessionStore=require('storage.session_store')
local definitions=require('content.items')
local active,config,base,log,hooks,frozen,pending,load_epoch=nil,nil,nil,nil,nil,false,nil,0
local load_error
local function valid(v) return v and v:IsValid() end
local function section(root,name)
  local found
  for k,v in pairs(root) do
    if k:lower()==name:lower() then assert(not found,'ambiguous-campaign-section');found=v end
  end
  return found
end
local function snapshot(allow_missing)
  assert(IsInGameThread(),'campaign-inventory-game-thread-required')
  local gi=UE.GetGameInstance();local gi_id=identity.capture(gi)
  local chosen;local values=FindAllOf('PBZSaveLoadSubsystem') or {};assert(#values<=8,'campaign-subsystem-limit')
  for _,v in ipairs(values) do
    if valid(v) and v:GetFullName():match('^PBZSaveLoadSubsystem ') and identity.matches(v:GetOuter(),gi_id) then
      assert(not chosen,'campaign-subsystem-not-unique');chosen=v
    end
  end
  local sub_id=identity.capture(assert(chosen,'campaign-subsystem-unavailable'))
  local path=assert(sub_id.name:match('^PBZSaveLoadSubsystem (.+)$'))
  local summary
  if allow_missing then summary=PBZMC_ReadCampaignLoadState else summary=PBZMC_ReadCampaignState end
  if summary then
    -- For existing campaigns only the verified identity/anchor cross into
    -- Lua. A read error must never be treated as first-time registration.
    local raw,why,backup=summary(path);assert(raw,why)
    local current=state.decode(raw)
    assert(identity.matches(UE.GetGameInstance(),gi_id) and identity.matches(chosen,sub_id),'campaign-scope-changed')
    if allow_missing and current.needs_registration==true then
      assert(type(current.root_sha256)=='string' and #current.root_sha256==64,
        'campaign-registration-bridge-update-required')
      return {path=path,instance=gi_id,subsystem=sub_id,needs_registration=true,registration=current,backup=backup}
    end
    assert(type(current.campaign_id)=='string' and type(current.checkpoint)=='string'
      and type(current.root_sha256)=='string' and #current.root_sha256==64,'campaign-state-summary')
    return {path=path,campaign_id=current.campaign_id,checkpoint=current.checkpoint,
      raw_sha256=current.root_sha256,instance=gi_id,subsystem=sub_id,
      selected=config and current.selection_mode==config.mode and current.selected or nil}
  end
  local raw,why=PBZMC_ReadOrdinaryJson(path);assert(raw,why)
  local root=state.decode(raw);assert(type(root.PBZGameSystem)=='table','campaign-gameplay-root-required')
  local marker=section(root,'PBZMC_CampaignIdentity')
  local anchor=section(root,'PBZMC_Checkpoint')
  if allow_missing and (not marker or not anchor) then
    error('campaign-registration-bridge-update-required')
  end
  assert(marker,'campaign-identity-required')
  assert(type(marker.campaign_id)=='string' and encode(marker)==encode({owner='pbzmc',schema='campaign-identity-v1',
    campaign_id=marker.campaign_id}),'campaign-identity-format')
  assert(anchor,'campaign-checkpoint-required')
  assert(type(anchor.checkpoint)=='string' and #anchor.checkpoint==64 and anchor.checkpoint:match('^[0-9a-f]+$')
    and encode(anchor)==encode({owner='pbzmc',schema='campaign-checkpoint-v1',campaign_id=marker.campaign_id,
      checkpoint=anchor.checkpoint}),'campaign-checkpoint-format')
  assert(identity.matches(UE.GetGameInstance(),gi_id) and identity.matches(chosen,sub_id),'campaign-scope-changed')
  return {raw=raw,path=path,campaign_id=marker.campaign_id,checkpoint=anchor.checkpoint,instance=gi_id,subsystem=sub_id}
end
local function status(operation,why,write)
  local s=active
  if frozen or load_error then s=nil end -- The previous campaign does not own this load.
  local report={schema=2,operation=operation,enabled=config~=nil,
    frozen=frozen,load_epoch=load_epoch,error=why or load_error,campaign_id=s and s.campaign_id,checkpoint=s and s.checkpoint,
    mode=config and config.mode,generation=s and s.store.generation,opened=s and s.session.opened or false,
    containers=s and s.store.core.containers,formal_inventory_bound=s~=nil,fixture_migrated=false,
    persistence='native-savepoint-only',dirty=s and s.store.dirty,savepoint=s and s.savepoint,
    selection_metrics=s and s.selection_metrics}
  if s then s.last_status=report end
  -- No diagnostic serialization or file write on a gameplay transaction.
  if write or why then fs.write(base..'campaign-inventory-status.json',json.encode(report,{indent=true})) end
end
local function diagnostic_reason(why)
  if fs.is_error(why) then return '无法读写模组存档文件。请检查日志中的路径、目录权限与磁盘空间；不要删除存档数据。' end
  if why:find('save-limit:',1,true) then return '存档展开后的 JSON 超过安全上限（UTF-8 8 MiB、400000 个值）；下方给出实际值和上限。' end
  if why:find('missing-campaign-checkpoint',1,true) or why:find('existing-campaign-anchor-missing',1,true)
      or why:find('missing-checkpoint',1,true) then
    return '缺少此原版存档对应的 MC 数据。请恢复同一备份中的 pbzmc-data/player-store，勿用空背包覆盖。'
  end
  if why:find('checksum',1,true) then return 'MC 存档数据校验失败。请保留文件并恢复配套备份，不要删除或重置存档。' end
  if why:find('campaign-registration-bridge-update-required',1,true) then
    return 'Lua 脚本和原生存档桥版本不一致。请完整安装新版并重启 PBZ。'
  end
  if why:find('native FString length exceeds the probe bound',1,true) then
    return '旧版存档桥上限为 262144 个 UTF-16 代码单元，请完整更新模组并重启游戏。'
  end
end
local function reject_load(why)
  why=tostring(why)
  frozen=true;pending=nil
  if not load_error then
    load_error='MC 读档失败：'..(diagnostic_reason(why) or '')..
      '背包、快捷栏和建筑未加载。请保留当前存档与 pbzmc-data 的备份；更新后可重新读档。原因：'..why
    log(load_error)
    pcall(status,'load-rejected',load_error,true)
  end
end
function M.enabled() return config~=nil end
function M.failure() return load_error end
function M.load_epoch() return load_epoch end
function M.notice()
  if load_error then return load_error end
  if active and M.current(active.binding) and active.recovery and active.recovery.automatic_reset then
    return 'MC 数据已自动重建：旧 MC 数据读取失败，已保留原文件；PBZ 进度不变。请到原版存档点保存。'
  end
end
function M.game_mode(binding)
  return active and active.binding==binding and require('rules.game_mode').get(active.store.core)or 'survival'
end
function M.set_game_mode(binding,mode)
  local s=M.ensure(binding)
  assert(not s.session.opened and not s.restart_frozen and not s.session.busy,'gamemode-session-unavailable')
  local ticket=s.store:checkout({})
  local next=require('rules.game_mode').change(ticket.data,mode)
  local ok,why=s.session:commit(ticket,next);assert(ok,why)
  binding.mc_creative=mode=='creative'
  if s.status_service then s.status_service.mode=require('rules.game_mode').action(s.store.core,s.mode)end
  log('MC gamemode='..mode..'; same inventory/buildings; native-savepoint-only')
  return mode
end
function M.bound() return active~=nil and M.current(active.binding) end
function M.current(binding)
  local s=active
  return s and not frozen and not s.failure and s.binding==binding and binding:is_current() and not binding.closing
    and identity.matches(binding.actor:GetWorld(),s.world) and identity.matches(UE.GetGameInstance(),s.instance) or false
end
local function install_hooks()
  if hooks then return end
  local path='/Script/ProjectPBZ.PBZGameInstance:LoadGame'
  local fn=StaticFindObject(path);assert(valid(fn) and fn:GetFunctionFlags()==0x04420401,'campaign-load-hook-schema')
  local fields=0
  fn:ForEachProperty(function(f)
    fields=fields+1
    if fields==1 then assert(f:GetFullName()=='StrProperty '..path..':SlotName' and f:GetOffset_Internal()==0)
    elseif fields==2 then assert(f:GetFullName()=='StructProperty '..path..':LoadGameResultParam' and f:GetOffset_Internal()==16
      and f:GetStruct():GetFullName()=='ScriptStruct /Script/ProjectPBZ.LoadGameResultParam')
    else error('campaign-load-hook-extra-field') end
  end)
  assert(fields==2,'campaign-load-hook-fields')
  hooks={RegisterHook(path,function(Context)
    if not config then return nil end
    local ok,why=pcall(function()
      assert(identity.matches(Context:get(),identity.capture(UE.GetGameInstance())),'campaign-load-context')
      load_epoch=load_epoch+1;frozen=true;load_error=nil
      pending={epoch=load_epoch,old_binding=active and active.binding}
      status('load-begin')
    end)
    if not ok then reject_load(why) end
    return nil
  end,function(Context,Slot,Result)
    if not config then return nil end
    local ok,why=pcall(function()
      assert(pending and identity.matches(Context:get(),identity.capture(UE.GetGameInstance())),'campaign-load-pair-required')
      local result=Result:get()
      assert(result and result:IsMappedToObject() and result:GetFullName()=='ScriptStruct /Script/ProjectPBZ.LoadGameResultParam',
        'campaign-load-result-unavailable')
      assert(result.ResultType==0,'campaign-native-load-failed')
      -- Do not serialize/parse a large native root on the LoadGame callback
      -- stack. The first ready player binds it once, outside this callback.
      pending.success=true;status('load-result-success-await-player')
    end)
    if not ok then reject_load(why) end
    return nil
  end)}
  local save_path='/Script/ProjectPBZ.PBZGameSystem:PreSaveGame'
  local save_fn=StaticFindObject(save_path)
  assert(valid(save_fn) and save_fn:GetFunctionFlags()==0x20401,'campaign-savepoint-hook-schema')
  local fields=0
  save_fn:ForEachProperty(function(f)
    fields=fields+1
    assert(fields==1 and f:GetFullName()=='StructProperty '..save_path..':SaveGameParam'
      and f:GetOffset_Internal()==0 and f:GetStruct():GetFullName()=='ScriptStruct /Script/ProjectPBZ.SaveGameParam',
      'campaign-savepoint-hook-fields')
  end)
  assert(fields==1,'campaign-savepoint-hook-parameter')
  -- This collector is an existing PBZStartSaveGame listener, after the native
  -- save was accepted and before its ordinary JSON snapshot is serialized.
  -- Synchronous post callback; no save request, return or parameter override.
  local pre,post=RegisterHook(save_path,function() return nil end,function(Context)
    if active and not frozen and not active.saving then
      local ok,why=pcall(function()
        assert(IsInGameThread(),'campaign-savepoint-thread')
        local receiver=Context:get()
        assert(valid(receiver) and identity.matches(receiver:GetWorld(),active.world),'campaign-savepoint-world')
        M.savepoint('PBZGameSystem.PreSaveGame')
      end)
      if not ok then
        active.saving=false;active.save_error=tostring(why)
        log('MC 存档点未能确认保存背包与建筑：'..(diagnostic_reason(tostring(why)) or '')..tostring(why))
        pcall(status,'savepoint-failed',tostring(why),true)
      end
    end
    return nil
  end)
  hooks.save={path=save_path,pre=pre,post=post}
end
function M.start(logger,directory)
  if base then return end
  base=directory..'/pbzmc-data/';log=logger
  local raw=fs.read(base..'campaign-inventory-enabled.json',false)
  if raw then
    config=state.decode(raw)
    assert(config.schema==1 and config.mode=='free' and type(config.campaign_id)=='string','campaign-inventory-config')
  end
  config={schema=1,mode=config and config.mode or 'free'}
  install_hooks()
end
local function bind(binding)
  if active and active.status_service then
    if not pending then active.status_service:flush_memory() end
    active.status_service:close()
  end
  local snap=snapshot(true)
  if snap.needs_registration then
    local starter_snapshot
    local ok,reader=pcall(require('host.pbz.native_equipment').new,binding,require('host.pbz.local_player').controller(),load_epoch)
    if ok and reader then
      local read,value=pcall(reader.read,reader,load_epoch)
      if read then starter_snapshot=value end
      reader:close()
    end
    require('host.pbz.campaign_registration').ensure(base,snap.path,snap.registration,starter_snapshot,snap.backup)
    snap=snapshot()
  end
  local c=Campaign.open(base..'player-store',snap.campaign_id,'local-primary',definitions)
  local loaded,recovery
  if active and not pending and active.campaign_id==snap.campaign_id then
    -- Actor replacement is not a reason to rewind committed inventory. A
    -- changed root without a proven load request remains blocked for review.
    assert(snap.checkpoint==active.checkpoint,'formal-inventory-unclassified-root-change')
    loaded={profiles=active.profiles};c=active.campaign;recovery=active.recovery
  else
    local why;loaded,why=c:load(snap.checkpoint)
    if not loaded then
      c,loaded,recovery=require('storage.campaign_recovery').create(base,snap.campaign_id,snap.checkpoint,why)
      if recovery.automatic_reset then
        log('MC 数据已自动重建；PBZ 进度不变，旧文件原位保留。source='..snap.checkpoint..
          ' replacement='..recovery.checkpoint..' reason='..tostring(recovery.reason))
      end
    end
  end
  for mode,store in pairs(loaded.profiles) do loaded.profiles[mode]=SessionStore.new(store) end
  local s={campaign=c,campaign_id=snap.campaign_id,checkpoint=snap.checkpoint,profiles=loaded.profiles,
    binding=binding,world=identity.capture(binding.actor:GetWorld()),instance=snap.instance,
    store=assert(loaded.profiles[config.mode]),epoch=load_epoch,mode=config.mode,recovery=recovery}
  if recovery and recovery.automatic_reset then s.unpublished=true end
  if active and not pending and active.profiles==s.profiles then
    s.unpublished=active.unpublished;s.savepoint=active.savepoint;s.selection_metrics=active.selection_metrics
  end
  local host={}
  function host:is_current()
    -- LoadGame freezes the session synchronously. Disk/root compare fences
    -- belong at binding and savepoints, not on every mouse/scroll operation.
    return M.current(binding) and active==s and not s.restart_frozen
  end
  function host:begin_inventory() return assert(s.next_lease,'formal-inventory-input-lease-required') end
  function host:item_controls_context() return s.input_context end
  function host:pick_target()return require('host.pbz.item_interface').pick_target(binding)end
  function host:authorize_selection(before,after)
    return s.selection_authority and s.selection_authority(before,after)==true or false
  end
  s.session=Session.new(s.store,host,s.world.name)
  -- Pure legacy grants are preflighted in the detached memory store. Do not
  -- expose a partially initialized campaign if a migration fails midway.
  local core=s.store.core
  local tnt_ready=require('host.pbz.tnt_damage').ready()
  if not(core.shield_unlocked and core.recovery_items_unlocked and core.pearl_unlocked and core.boat_unlocked
      and core.chorus_unlocked and (not tnt_ready or core.tnt_unlocked and core.flint_unlocked))then
    local ticket=s.store:checkout({});local candidate=ticket.data
    for _,name in ipairs({'shield_unlock','recovery_unlock','pearl_unlock','boat_unlock','chorus_unlock'})do
      candidate=require('rules.'..name).apply(candidate,s.campaign_id)
    end
    if tnt_ready then candidate=require('rules.tnt_unlock').apply(candidate,s.campaign_id)end
    if candidate~=ticket.data then
      local ok,why=s.store:commit(ticket,candidate);assert(ok,why)
      log('MC legacy starter grants applied in one memory transaction; next native savepoint persists them')
    end
  end
  active=s;pending=nil;frozen=false
  binding.mc_creative=require('rules.game_mode').creative(s.store.core)
  local ok,service=pcall(require('host.pbz.player_status_service').new,s,log)
  if ok then s.status_service=service else log('MC player status initialization failed: '..tostring(service)) end
  status('bound');log('formal inventory bound mode='..config.mode..' generation='..s.store.generation..' checkpoint='..s.checkpoint)
  return s
end
function M.ensure(binding)
  assert(config and binding and binding:is_current(),'formal-inventory-current-player-required')
  if M.current(binding) then return active end
  if load_error then error(load_error,0) end
  assert(not active or not active.failure or pending,'formal-inventory-publication-requires-recovery')
  if pending then
    assert(pending.success and binding~=pending.old_binding,'formal-inventory-waiting-for-loaded-player')
  end
  local ok,result=pcall(bind,binding)
  if ok then return result end
  -- All bind failures are terminal for this load, including a missing exact
  -- checkpoint, invalid old schema or failed migration. A new LoadGame is the
  -- recovery boundary; rendering must not retry disk/JSON work every frame.
  reject_load(result);error(load_error,0)
end
local function publish(s,snap)
  assert(M.current(s.binding) and snap.campaign_id==s.campaign_id and snap.checkpoint==s.checkpoint,'formal-inventory-anchor-changed')
  local digest,why=s.campaign:create(s.profiles);assert(digest,why)
  assert(M.current(s.binding),'formal-inventory-owner-changed')
  require('storage.campaign_recovery').before_publish(base,s.campaign,digest)
  local expected=snap.raw_sha256 or sha(snap.raw)
  -- Put performs the exact-root compare immediately before the native write,
  -- then reads back the whole root and checks the anchor and unrelated fields.
  -- Consume that verified receipt instead of serializing the root twice more.
  local receipt,err=PBZMC_PutCampaignCheckpoint(snap.path,expected,s.campaign_id,digest);assert(receipt,err)
  local after=state.decode(receipt)
  assert(M.current(s.binding) and after.checkpoint==digest and after.campaign_id==s.campaign_id
    and after.before_sha256==expected and type(after.after_sha256)=='string' and #after.after_sha256==64,
    'formal-inventory-anchor-readback')
  s.checkpoint=digest
end
local function finish(s,before,operation,ok,why)
  status(operation,not ok and why or nil)
  if not ok and why=='inventory-input-release-failed' then return false,why end
  assert(ok,why);return true
end
function M.savepoint(source)
  local s=assert(active,'savepoint-profile-unavailable')
  assert(not s.saving and M.current(s.binding) and not s.session.busy,'savepoint-session-unavailable')
  -- A yielding /fill or /clone can have committed native batches while the
  -- enclosing command is unfinished. Do not publish that intermediate core.
  -- Use already-loaded owners only, including a service currently closing.
  local commands=package.loaded['host.pbz.command_service']
  local service=commands and commands.get(s.binding)
  if not service then
    local buildings=package.loaded['host.pbz.building_service']
    local build=buildings and buildings.get(s.binding)
    service=build and build.commands
  end
  if service and service.has_pending_mutations and service:has_pending_mutations()then
    local reason='command-world-transaction-pending: wait for command completion before saving'
    if service.message then pcall(service.message,service,'chat','命令方块事务尚未完成，请等待命令结束后再次存档。',{source='server'})end
    error(reason,0)
  end
  -- Clock progress is cheap runtime state, carried by the profile across pawn
  -- replacement. Publish it with scheduled functions only at native saves.
  for _,store in pairs(s.profiles)do
    if store.command_tick and store.core.commands and store.core.commands.clock~=store.command_tick then
      local next_commands=require('storage.state').clone(store.core.commands)
      next_commands.clock=store.command_tick
      local committed,why=store:commit_commands(store.core.commands,next_commands);assert(committed,why)
    end
  end
  if s.status_service then s.status_service:flush_memory() end
  local boats=package.loaded['host.pbz.boat_service']
  local boat=boats and boats.get(s.binding)
  if boat then boat:flush_memory() end
  local dirty=s.unpublished
  for _,store in pairs(s.profiles) do dirty=dirty or store.dirty or store.runtime_selected~=nil end
  if not dirty then return true end
  s.saving=true;local began=os.clock();local before=s.checkpoint
  local ok,why=pcall(function()
    local snap=snapshot()
    assert(snap.campaign_id==s.campaign_id and snap.checkpoint==s.checkpoint,'savepoint-anchor-changed')
    s.unpublished=true
    for _,store in pairs(s.profiles) do
      local flushed,err=store:flush();assert(flushed,err)
    end
    publish(s,snap)
    s.unpublished=false;s.save_error=nil
    s.savepoint={source=source,previous=before,checkpoint=s.checkpoint,milliseconds=(os.clock()-began)*1000,
      disk_generation=s.store.durable.generation,gameplay_revision=s.store.generation}
    status('savepoint-published',nil,true)
    log('MC savepoint published checkpoint='..s.checkpoint..' ms='..s.savepoint.milliseconds)
  end)
  s.saving=false;assert(ok,why);return true
end
function M.freeze_for_developer_restart()
  assert(active and not active.store.dirty and not active.unpublished and not active.save_error,
    'developer-restart-requires-completed-savepoint')
  -- Keep world/appearance ownership alive (including the platform under the
  -- player). Only new gameplay commits stop while the requested save finishes.
  active.restart_frozen=true
end
function M.view(binding)
  local s=M.ensure(binding)
  require('host.pbz.native_slot_sync').poll(s,binding)
  return require('runtime.hotbar_selection').view(s.store)
end
-- Read-only appearance snapshot, also for verified cinematic doubles in the
-- same world. No native slot poll, checkout, serialization or recursion into
-- appearance:is_current() on the per-bone rendering path.
function M.armor_slots(binding)
  local s=active
  if not s or frozen or s.failure or not binding or not binding.world_id or s.binding.closing then return nil end
  local world=s.binding.world_id
  if not world or world.name~=binding.world_id.name or world.address~=binding.world_id.address then return nil end
  return s.store.core.containers.player.armor
end
-- Buildings share the exact campaign checkpoint and player profile. The legacy
-- transaction shape is private to this facade; no second inventory is saved.
function M.build_store(binding)
  local s=M.ensure(binding)
  local building_store=require('storage.session_store')
  local previous=state.clone(s.store.core.buildings)
  local grids=state.clone(s.store.core.building_grids or state.object())
  local expected=s.store.core.buildings
  local expected_grids=s.store.core.building_grids
  local function unchanged(current)
    for id,a in pairs(current) do if not building_store.same_building(a,previous[id]) then return false end end
    for id in pairs(previous) do if not current[id] then return false end end
    return true
  end
  local facade=setmetatable({},{__index=function(_,key)
    if key=='generation' then return s.store.generation end
  end})
  function facade:current() return active==s and M.current(binding) end
  -- A running fuse is independent of container input. Its world-only change
  -- uses a fresh checkout and preserves cursor/slots even while B is open.
  function facade:environmental(callback)
    if self.environment or s.session.busy or s.session.quarantined then return false,'building-transaction-busy' end
    self.environment=true
    local result=table.pack(pcall(callback));self.environment=nil
    if not result[1]then return false,tostring(result[2])end
    return table.unpack(result,2,result.n)
  end
  function facade:load()
    assert(self:current(),'building-campaign-changed')
    return {schema=1,inventory=state.object(),buildings=state.clone(previous),building_grids=state.clone(grids)}
  end
  function facade:commit(data,changes)
    if not self:current() or s.session.opened and not self.environment or s.restart_frozen then return false,'building-campaign-unavailable' end
    if changes~=nil then
      local ok,before,warning=pcall(function()
        assert(not s.session.busy and not s.session.quarantined,'building-transaction-busy')
        local epoch=s.session.epoch
        assert(s.session.host and s.session.host:is_current(),'inventory-scene-changed')
        if s.session.context=='ender' then assert(s.session.host:ender_access(),'ender-access-lost') end
        local current=s.store.core.buildings
        -- A container/status transaction may deep-clone unchanged buildings.
        -- Reconcile stable values only when that pointer actually changed.
        if current~=expected then assert(unchanged(current),'building-state-changed');expected=current end
        if s.store.core.building_grids~=expected_grids then
          local current_grids=s.store.core.building_grids or {}
          for world,origin in pairs(grids) do
            assert(building_store.same_building_grid(origin,current_grids[world]),'building-grid-changed')
          end
          for world in pairs(current_grids) do assert(grids[world],'building-grid-changed') end
          expected_grids=s.store.core.building_grids
        end
        assert(type(data)=='table' and data.schema==1 and type(data.buildings)=='table','invalid-building-candidate')
        assert(type(changes)=='table','invalid-building-delta')
        local baseline={}
        -- The declared delta is the authority: each changed candidate record
        -- must agree, and no container/cursor/selection data enters this API.
        for _,row in ipairs(changes) do
          local id=row.after and row.after.id or row.before and row.before.id
          assert(id and building_store.same_building(data.buildings[id],row.after),'building-delta-candidate-mismatch')
          if row.after then state.validate_value(row.after) end
          baseline[#baseline+1]={id=id,after=row.after and state.clone(row.after) or nil}
        end
        local proposed_grids=data.building_grids or grids
        local next_grids=grids
        state.validate_building_grids(proposed_grids);state.validate_value(proposed_grids)
        for world,origin in pairs(proposed_grids) do
          if not grids[world] then
            if next_grids==grids then next_grids=state.object();for w,p in pairs(grids) do next_grids[w]=p end end
            next_grids[world]=state.clone(origin)
          end
        end
        local ticket={owner=s.store,generation=s.store.generation,core=s.store.core,
          buildings=current,building_grids=s.store.core.building_grids}
        assert(self:current() and s.session.host:is_current() and s.session.epoch==epoch and not s.restart_frozen,
          'inventory-scene-changed')
        local saved,err=s.store:commit_buildings(ticket,changes,proposed_grids)
        assert(saved,err)
        -- Preserve a detached baseline without another full-map clone. The
        -- caller's mutable batch records are never retained by store/baseline.
        for _,row in ipairs(baseline) do previous[row.id]=row.after end
        expected=s.store.core.buildings
        grids=next_grids
        expected_grids=s.store.core.building_grids
        return ticket.generation,err
      end)
      if not ok then return false,tostring(before) end
      -- Commit already happened. As on the legacy path, publication errors
      -- cannot authorize rolling native geometry back over a committed core.
      local published,err=pcall(finish,s,before,'building-transaction',true,warning)
      if not published then return true,tostring(err) end
      return true,warning
    end
    -- Compare stable values directly, including the small block-state axis.
    -- No full-world JSON encoding is needed to detect a concurrent edit.
    local current=s.store.core.buildings
    for id,a in pairs(current) do
      local b=previous[id];if not b then return false,'building-state-changed' end
      for k,v in pairs(a) do
        if k=='properties' then
          if not require('rules.block_properties').equal(v,b[k]) then return false,'building-state-changed' end
        elseif b[k]~=v then return false,'building-state-changed' end
      end
      for k,v in pairs(b) do
        if k=='properties' then
          if not require('rules.block_properties').equal(v,a[k]) then return false,'building-state-changed' end
        elseif a[k]~=v then return false,'building-state-changed' end
      end
    end
    for id in pairs(previous) do if not current[id] then return false,'building-state-changed' end end
    local ticket=s.store:checkout({});local candidate=state.object()
    for key,value in pairs(ticket.data) do candidate[key]=value end
    candidate.buildings=state.clone(data.buildings)
    candidate.building_grids=state.clone(data.building_grids or grids)
    local before=s.store.generation
    local ok,why=s.session:commit(ticket,candidate)
    if not ok then return false,why end
    previous=state.clone(data.buildings)
    grids=state.clone(candidate.building_grids)
    expected=s.store.core.buildings;expected_grids=s.store.core.building_grids
    local published,err=pcall(finish,s,before,'building-transaction',true,why)
    -- The store commit already happened. Never roll back native geometry after
    -- that point; publication failure freezes the profile for recovery.
    return true,published and why or tostring(err)
  end
  return facade
end
function M.open(binding,lease)
  local s=M.ensure(binding)
  -- Normal close may return cursor/craft ownership. Publish those commits
  -- before the real lease unpauses PBZ and allows native save work to resume.
  s.next_lease={release=function()
    if s.defer_release then return false end
    return lease:release()
  end}
  local ok,why=s.session:open('inventory');s.next_lease=nil;assert(ok,why)
end
function M.dispatch(binding,request,context,selection_authority)
  local s=M.ensure(binding);local before=s.store.generation
  assert(not s.restart_frozen,'developer-restart-in-progress')
  local intent={};for k,v in pairs(request) do intent[k]=v end
  intent.epoch=s.session.epoch;intent.revision=s.store.generation
  if context and (request.kind=='select_slot' or request.kind=='scroll_slots') then
    intent.input_epoch=context.epoch
    local began=os.clock()
    local function write(index)
      assert(M.current(binding),'selection-owner-changed')
      s.store.dirty=true
      return true
    end
    local ok=require('runtime.hotbar_selection').select(s.session,intent,context,write,selection_authority)
    s.selection_metrics=s.selection_metrics or {count=0,total_ms=0,max_ms=0,profile_writes=0}
    local ms=(os.clock()-began)*1000;local m=s.selection_metrics;m.count=m.count+1;m.total_ms=m.total_ms+ms;m.max_ms=math.max(m.max_ms,ms)
    return ok
  end
  local ok,why
  if context then
    s.input_context=context;intent.input_epoch=context.epoch;s.selection_authority=selection_authority
    ok,why=s.session:controls(intent);s.selection_authority=nil
  else ok,why=s.session:dispatch(intent) end
  return finish(s,before,'intent-'..request.kind,ok,why)
end
function M.close(normal)
  if not active then return true end
  local s=active;local before=s.store.generation
  s.defer_release=normal
  local called,ok,why=pcall(s.session.close,s.session,normal and 'normal' or 'reload')
  if not called then s.defer_release=false;error(ok) end
  if not normal then s.defer_release=false;return ok,why end
  local completed,result,warning=pcall(finish,s,before,'close',ok,why)
  s.defer_release=false
  if not completed then error(result) end
  return result,warning
end
function M.enable(binding)
  assert(base and not config,'formal-inventory-already-enabled')
  local snap=snapshot()
  config={schema=1,mode='free',campaign_id=snap.campaign_id}
  local ok,why=pcall(function() install_hooks();M.ensure(binding) end)
  if not ok then config=nil;error(why) end
  fs.write(base..'campaign-inventory-enabled.json',json.encode(config))
  status('enabled')
end
function M.command_state(binding)
  return M.ensure(binding).store.core.commands
end
function M.command_clock(binding)
  local store=M.ensure(binding).store
  store.command_tick=store.command_tick or (store.core.commands and store.core.commands.clock)or 0
  return function(advance)
    if advance then store.command_tick=store.command_tick+advance end
    return store.command_tick
  end
end
function M.save_command_state(binding,value,...)
  local s=M.ensure(binding)
  if s.restart_frozen or s.session.busy or s.session.quarantined then return false,'command-transaction-busy' end
  local expected=s.store.core.commands
  if select('#',...)>0 then expected=(...)end
  return s.store:commit_commands(expected,value)
end
-- Capture this lease while the binding is current. Shutdown may call it after
-- a death/load has retired the actor or rebound the active campaign. Only the
-- original in-memory profile is accessible here; no native object or disk API.
-- Rows are the forward committed journal {before,after}; this applies its
-- reverse, atomically in memory, after validating every compare-and-swap.
function M.command_rollback(binding)
  local s=M.ensure(binding);local store=s.store
  local world=assert(s.world and s.world.name,'command-rollback-world-required'):gsub('^World ','')
  local same=SessionStore.same_building
  return function(changes)
    local original=store.core
    local called,prepared=pcall(function()
      assert(not store.read_only and store.loaded and original,'command-rollback-store-unavailable')
      assert(type(changes)=='table'and #changes<=16384,'command-rollback-journal-limit')
      local count=0;for index in pairs(changes)do
        count=count+1;assert(type(index)=='number'and index%1==0 and index>=1 and index<=#changes,'command-rollback-journal-array')
      end
      assert(count==#changes,'command-rollback-journal-array')
      assert(store.generation+math.ceil(count/128)<2^53,'command-rollback-generation-exhausted')
      local rows,seen,positions={},{},{}
      local function position_key(r)return r.world..string.pack('<ddd',r.x+0.,r.y+0.,r.z+0.)end
      for index=#changes,1,-1 do
        local row=changes[index];assert(type(row)=='table','command-rollback-journal-row')
        local before,after=row.before,row.after
        local id=after and after.id or before and before.id
        assert(type(id)=='string'and not seen[id],'command-rollback-journal-id')
        assert(not before or before.id==id,'command-rollback-id-changed')
        for _,record in pairs({before=before,after=after})do
          assert(record.world==world,'command-rollback-wrong-world')
          state.validate_buildings(state.object({[id]=record}));state.validate_value(record)
        end
        local current=original.buildings[id]
        assert(same(current,after),'command-rollback-record-conflict:'..id)
        rows[#rows+1]={before=current,after=before and state.clone(before)or nil}
        seen[id]=true
        if before then positions[position_key(before)]=id end
      end
      local candidate=state.object()
      for id,record in pairs(original.buildings)do
        -- A newly placed unrelated block must not be overlapped by restoring a
        -- removed command-owned record, even if its instance ID is different.
        assert(seen[id]or not positions[position_key(record)],'command-rollback-position-conflict:'..id)
        candidate[id]=record
      end
      for _,row in ipairs(rows)do local id=row.after and row.after.id or row.before.id;candidate[id]=row.after end
      state.validate_buildings(candidate)
      return rows
    end)
    if not called then return false,tostring(prepared)end
    if #prepared==0 then return true,0 end
    -- commit_buildings is pure Lua and never yields. A validation failure in a
    -- later bounded delta restores the exact pre-call core; the generation is
    -- kept monotonic so already issued tickets cannot become valid again.
    local applied,why=pcall(function()
      for first=1,#prepared,128 do
        local rows={}
        for index=first,math.min(first+127,#prepared)do
          local row=prepared[index];local id=row.after and row.after.id or row.before.id
          assert(same(store.core.buildings[id],row.before),'command-rollback-record-conflict:'..id)
          rows[#rows+1]={before=store.core.buildings[id],after=row.after}
        end
        local ticket={owner=store,generation=store.generation,core=store.core,
          buildings=store.core.buildings,building_grids=store.core.building_grids}
        local ok,reason=store:commit_buildings(ticket,rows);assert(ok,reason)
      end
    end)
    if not applied then store.core=original;return false,tostring(why)end
    return true,#prepared
  end
end
function M.command_items(binding,operation)
  local s=M.ensure(binding)
  assert(not s.session.opened and not s.restart_frozen and not s.session.busy,'command-inventory-unavailable')
  local ticket=s.store:checkout({})
  local containers,result=operation(ticket.data.containers,s.store.generation+1,s.campaign_id)
  if not containers then return result end
  local candidate=state.object();for k,v in pairs(ticket.data)do candidate[k]=v end
  candidate.containers=containers
  local ok,why=s.session:commit(ticket,candidate);assert(ok,why)
  return result
end
function M.take_arrows(binding)
  -- Explicit integration-test setup through the free-mode ownership store.
  -- This is not fixture migration or a completed creative catalogue UI.
  local s=M.ensure(binding);assert(config.mode=='free' and not s.session.opened,'free-catalogue-context-required')
  local ticket=s.store:checkout({});local slots=require('rules.container_slots')
  assert(not slots.get(ticket.data.containers,'player/main/1'),'test-setup-slot-not-empty')
  local draft=slots.edit(ticket.data.containers)
  draft:set('player/main/1',{content_id='pbzmc:arrow',count=64,metadata={}})
  local candidate=state.object();for k,v in pairs(ticket.data) do candidate[k]=v end;candidate.containers=draft.data
  local before=s.store.generation;local ok,why=s.session:commit(ticket,candidate)
  return finish(s,before,'explicit-free-arrow-setup',ok,why)
end
function M.developer_give(binding,content_id,count)
  local s=M.ensure(binding);assert(not s.session.opened,'developer-close-inventory-first')
  assert(type(count)=='number' and count%1==0 and count>=1 and count<=2304,'developer-give-count')
  local definition=assert(definitions.get(content_id),'developer-unknown-item')
  assert(definition.kind~='balance','developer-item-required')
  assert(not definition.instance or count<=36,'developer-instance-count')
  local ticket=s.store:checkout({});local containers=ticket.data.containers
  local transfer=require('rules.container_transfer')
  for i=1,definition.instance and count or 1 do
    local value={content_id=content_id,count=definition.instance and 1 or count,metadata=state.object()}
    if definition.instance then value.instance_id=string.format('dev-%s-%d-%d',s.campaign_id,s.store.generation+1,i) end
    local next_containers,remainder=transfer.offer(containers,value,'player',definitions)
    assert(not remainder,'developer-inventory-full');containers=next_containers
  end
  local candidate=state.object();for k,v in pairs(ticket.data) do candidate[k]=v end;candidate.containers=containers
  local before=s.store.generation;local ok,why=s.session:commit(ticket,candidate)
  return finish(s,before,'developer-give',ok,why)
end
function M.developer_camera_loadout(binding,pc)
  local s=M.ensure(binding);assert(not s.session.opened,'developer-close-inventory-first')
  local ticket=s.store:checkout({});local slots=require('rules.container_slots');local draft=slots.edit(ticket.data.containers)
  local function find(content)
    for _,area in ipairs({'hotbar','main'}) do for i=1,area=='hotbar' and 9 or 27 do
      local address='player/'..area..'/'..i;local stack=draft:get(address)
      if stack and stack.content_id==content then return address,stack end
    end end
  end
  for _,content in ipairs({'pbzmc:diamond_sword','pbzmc:bow','pbzmc:arrow'}) do
    local address,stack=find(content)
    if not address then
      stack={content_id=content,count=content=='pbzmc:arrow' and 64 or 1,metadata=state.object()}
      if content~='pbzmc:arrow' then stack.instance_id='camera-loadout-'..s.campaign_id..'-'..content end
    end
    if not address or address:match('/main/') then
      local hole
      for i=1,9 do if not draft:get('player/hotbar/'..i) then hole='player/hotbar/'..i;break end end
      assert(hole,'camera-loadout-hotbar-full')
      if address then draft:set(address,nil) end;draft:set(hole,stack)
    end
  end
  local reader,why=require('host.pbz.native_equipment').new(binding,pc,1);assert(reader,why)
  local declared;declared,why=reader:read(1);assert(declared,why)
  local runtime;runtime,why=reader:read_runtime(1,{selection=true});assert(runtime,why)
  assert(runtime.slots['Weapon.Slot.Main'].count==#declared.main_weapons,'loadout-native-capacity-disagrees')
  local updated=require('rules.native_slot_inventory').refresh(draft.data,declared,1,definitions);reader:close()
  local candidate=state.object();for k,v in pairs(ticket.data) do candidate[k]=v end;candidate.containers=updated
  local before=s.store.generation;local ok,err=s.session:commit(ticket,candidate)
  return finish(s,before,'camera-loadout',ok,err)
end
function M.developer_shield_loadout(binding)
  local s=M.ensure(binding);assert(not s.session.opened,'developer-close-inventory-first')
  local ticket=s.store:checkout({});local slots=require('rules.container_slots');local draft=slots.edit(ticket.data.containers)
  local function shield(suffix)
    return {content_id='pbzmc:shield',count=1,metadata=state.object(),instance_id='shield-'..s.campaign_id..'-'..suffix}
  end
  local off=draft:get('player/offhand')
  if not off then draft:set('player/offhand',shield('offhand'))
  else assert(off.content_id=='pbzmc:shield','developer-offhand-occupied') end
  local found,hole
  for i=1,9 do local v=draft:get('player/hotbar/'..i)
    if v and v.content_id=='pbzmc:shield' then found=i end
    if not v and not hole then hole=i end
  end
  if not found then assert(hole,'developer-hotbar-full');draft:set('player/hotbar/'..hole,shield('main')) end
  local candidate=state.object();for k,v in pairs(ticket.data) do candidate[k]=v end;candidate.containers=draft.data
  local before=s.store.generation;local ok,why=s.session:commit(ticket,candidate)
  finish(s,before,'developer-shield-loadout',ok,why);return found or hole
end
function M.observe() status('observe',nil,true);return active end
function M.reconcile()
  if not active then return true end
  local ok,why=active.session:reconcile()
  if active.failure then active.session.quarantined=true end
  return ok,why
end
return M
