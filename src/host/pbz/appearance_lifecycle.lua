-- One pose writer for the local player and the game's verified protagonist
-- doubles. Story/camera ownership remains entirely with the native sequence.
local identity=require('host.pbz.object_identity')
local Appearance=require('host.pbz.appearance')
local Registry=require('runtime.appearance_registry')
local M={}
local active
local protagonist_classes={
  BP_Seq_Hun_C='BlueprintGeneratedClass /HuaShira/Animation/Seqs/ActorForSeqs/BP_Seq_Hun.BP_Seq_Hun_C',
  BP_Renewal_Hun_C='BlueprintGeneratedClass /Game/RenewalContent/Actors/Players/BP_Renewal_Hun.BP_Renewal_Hun_C',
  BP_Renewal_Hun_Young_C='BlueprintGeneratedClass /Game/RenewalContent/Actors/Players/BP_Renewal_Hun_Young.BP_Renewal_Hun_Young_C',
  BP_Renewal_Hun_Climax_C='BlueprintGeneratedClass /Game/RenewalContent/Actors/Players/BP_Renewal_Hun_Climax.BP_Renewal_Hun_Climax_C'
}
function M.get() return active end
function M.start(log,assets)
  assert(not active,'appearance-lifecycle-already-started')
  local self={log=log,closed=false,ticks=0,hooks={},errors={},protagonist_assets={},source_hints={},class_cache={},class_retry={}}
  active=self
  local host={}
  function host:key(actor)
    local id=identity.capture(actor);return id.name..'@'..tostring(id.address)
  end
  function host:alive(actor)
    if not Appearance.valid(actor)then return false end
    local hint=self.lifecycle.source_hints[self:key(actor)]
    if hint then
      if not identity.matches(hint.object,hint.identity)
          or not identity.matches(hint.object:GetOwner(),identity.capture(actor))then return false end
      local asset=hint.object:GetSkeletalMeshAsset()
      return Appearance.valid(asset)and self.lifecycle.protagonist_assets[asset:GetFullName()]==true
    end
    return true
  end
  function host:current(binding) return binding:is_current() and not binding.closing end
  function host:bind(actor,reason)
    local key=self.lifecycle.host:key(actor)
    local hint=self.lifecycle.source_hints[key]
    if hint and not identity.matches(hint.object,hint.identity)then hint=nil;self.lifecycle.source_hints[key]=nil end
    local binding=Appearance.new(actor,assets,log,hint and hint.object)
    binding.lifecycle=self.lifecycle
    if not binding.creation_failure and not self.lifecycle.protagonist_assets[binding.asset_id.name] then
      self.lifecycle.protagonist_assets[binding.asset_id.name]=true
      self.lifecycle.scan_requested=true
    end
    if binding.creation_failure then
      log('appearance partial creation retained for cleanup: '..binding.creation_failure..'; '..binding.cleanup_failure)
    else log('appearance lifecycle bind reason='..reason..' tick='..self.lifecycle.ticks..' actor='..binding.actor_id.name) end
    return binding
  end
  host.lifecycle=self
  self.host=host
  function host:update(binding)
    -- The combat coordinator may supply a read-only MC render frame after it
    -- owns input. Nil (including cinematic/native ownership) uses native pose.
    -- All component writes still occur in this single lifecycle update.
    local frame=self.lifecycle.presentation_source and self.lifecycle.presentation_source(binding) or nil
    binding:update(frame)
    local camera=package.loaded['host.pbz.first_person_camera']
    camera=camera and camera.get()
    local pawn=self.lifecycle.cached_pawn
    local cinematic=not pawn or binding.actor:GetAddress()~=pawn:GetAddress() or (camera and camera.in_story)
    if cinematic or binding.weapons_suppressed~=binding.suppress_native_weapons or binding.frames%6==0 then
      binding:ensure_hidden()
    end
    if binding.frames%((cinematic or binding.suppress_native_weapons)and 30 or 120)==0 then binding:hide_native() end
  end
  function host:release(binding) binding:close() end
  self.registry=Registry.new(host)
  function self:guard(label,fn)
    if self.closed or self.busy then return end
    self.busy=true
    local ok,why=pcall(fn)
    self.busy=false
    if ok then self.errors[label]=nil
    elseif self.errors[label]~=tostring(why) then
      self.errors[label]=tostring(why);log('appearance lifecycle '..label..' failed: '..tostring(why))
    end
    return ok,why
  end
  local character_class=StaticFindObject('/Script/Engine.Character')
  local skeletal_class=StaticFindObject('/Script/Engine.SkeletalMeshComponent')
  local function controlled_player(controller)
    if not Appearance.valid(controller) or not controller:IsLocalPlayerController() then return end
    local pawn=controller.Pawn
    if not Appearance.valid(pawn) or not pawn:IsA(character_class) then return end
    local world=pawn:GetWorld()
    if not Appearance.valid(world) or controller:GetWorld():GetAddress()~=world:GetAddress() then return end
    if not self.protagonist_world or self.protagonist_world.identity.address~=world:GetAddress()
        or not Appearance.valid(self.protagonist_world.object) then
      self.protagonist_world={object=world,identity=identity.capture(world)}
    end
    return pawn
  end
  function self:local_player()
    if self.player_tick==self.ticks then
      if not self.cached_pawn then return end
      if Appearance.valid(self.cached_pawn) and Appearance.valid(self.controller) then
        local pawn=self.controller.Pawn
        if Appearance.valid(pawn) and pawn:GetAddress()==self.cached_pawn:GetAddress() then return self.cached_pawn end
      end
    end
    self.player_tick=self.ticks;self.cached_pawn=nil
    local pawn=controlled_player(self.controller)
    if pawn then self.cached_pawn=pawn;return pawn end
    if self.player_retry and self.ticks<self.player_retry then return end
    self.player_retry=self.ticks+12
    self.controller=nil
    for _,pc in ipairs(FindAllOf('PlayerController') or {}) do
      pawn=controlled_player(pc)
      if pawn then self.controller=pc;self.cached_pawn=pawn;return pawn end
    end
  end
  function self:consider(actor,reason,source)
    local player=self:local_player()
    if player and identity.matches(actor,identity.capture(player)) then return self.registry:observe(actor,reason) end
    -- Possession can be absent during a native cinematic handoff. Retain only
    -- the last verified, still-live world; never broaden discovery to all worlds.
    local world=self.protagonist_world
    if not Appearance.valid(actor)or not world or not identity.matches(world.object,world.identity)
        or not identity.matches(actor:GetWorld(),world.identity)then return end
    -- IsA admits later derived story variants without matching arbitrary names.
    for name,path in pairs(protagonist_classes)do
      local cls=self.class_cache[name]
      if not Appearance.valid(cls) and self.ticks>=(self.class_retry[name] or 0)then
        cls=StaticFindObject(path:match('^[^ ]+ (.+)$'));self.class_cache[name]=cls;self.class_retry[name]=self.ticks+30
      end
      if Appearance.valid(cls)and actor:IsA(cls)then
        return self.registry:observe(actor,'protagonist-double-'..reason)
      end
    end
    -- A sequence can instantiate a plain skeletal actor instead of a pawn.
    -- Authorize only an exact body asset already observed on a verified Hun.
    local function match(component)
      if Appearance.valid(component)then
        local asset=component:GetSkeletalMeshAsset()
        if Appearance.valid(asset)and self.protagonist_assets[asset:GetFullName()]then
          self.source_hints[host:key(actor)]={object=component,identity=identity.capture(component)}
          self.registry:observe(actor,'protagonist-mesh-double-'..reason)
          return true
        end
      end
    end
    if source then match(source);return end
    -- Most spawned effects and projectiles have no skeleton. Avoid constructing
    -- a reflected array of components for every one of those BeginPlay events.
    local first=actor:GetComponentByClass(skeletal_class)
    if not Appearance.valid(first) or match(first) then return end
    for _,wrapped in ipairs(actor:K2_GetComponentsByClass(skeletal_class)) do
      local component=wrapped:get()
      if component:GetAddress()~=first:GetAddress() and match(component) then return end
    end
  end
  function self:current()
    local actor=self:local_player()
    if not actor then return end
    if not self.current_actor or not self.current_actor:IsValid() or self.current_actor:GetAddress()~=actor:GetAddress() then
      self.current_actor=actor;self.current_key=host:key(actor)
    end
    local entry=self.registry.entries[self.current_key]
    return entry and entry.binding
  end
  function self:ensure(reason)
    local actor=self:local_player()
    if actor then
      local entry=self.registry.entries[host:key(actor)]
      if reason=='local-player-discovery' and entry then return entry.binding end
      return self.registry:observe(actor,reason or 'explicit-observe')
    end
  end
  function self:rebind()
    local actor=assert(self:local_player(),'appearance-player-required')
    self.registry:forget(actor)
    return self.registry:observe(actor,'development-rebind')
  end
  local function hook(path,callback)
    local fn=StaticFindObject(path)
    if not fn or not fn:IsValid() then log('appearance optional event unavailable '..path);return end
    local ok,pre,post=pcall(RegisterHook,path,function() end,callback)
    if ok then self.hooks[#self.hooks+1]={path=path,pre=pre,post=post};log('appearance event registered '..path)
    else log('appearance event unavailable '..path..': '..tostring(pre)) end
  end
  RegisterBeginPlayPostHook(function(context)
    self:guard('beginplay',function()
      local actor=context:get()
      require('host.pbz.auto_defense').spawned(actor)
      self:consider(actor,'beginplay')
    end)
  end)
  RegisterEndPlayPreHook(function(context)
    self:guard('endplay',function()
      local actor=context:get()
      if actor and actor:IsValid() then
        for key,entry in pairs(self.registry.entries) do
          if entry.actor:GetAddress()==actor:GetAddress() then self.source_hints[key]=nil;self.registry:forget(actor);break end
        end
      end
    end)
  end)
  hook('/Script/Engine.Controller:Possess',function()
    self.player_tick=nil;self.player_retry=nil
    self:guard('possess',function() self:ensure('possess') end)
  end)
  hook('/Script/Engine.PlayerController:ClientRestart',function()
    self.player_tick=nil;self.player_retry=nil
    self:guard('client-restart',function() self:ensure('client-restart') end)
  end)
  local function mesh_changed(context)
    self:guard('mesh-change',function()
      local component=context:get()
      for _,entry in pairs(self.registry.entries) do
        if entry.binding and identity.matches(component,entry.binding.source_id) then
          entry.binding.checked_tick=nil
          if host:alive(entry.actor)then self.registry:observe(entry.actor,'mesh-changed')
          else self.registry:forget(entry.actor);self.source_hints[host:key(entry.actor)]=nil end
        end
      end
      if Appearance.valid(component)then
        local owner=component:GetOwner()
        local asset=component:GetSkeletalMeshAsset()
        if Appearance.valid(asset) and self.protagonist_assets[asset:GetFullName()] then self:consider(owner,'late-mesh',component) end
        local entry=Appearance.valid(owner)and self.registry.entries[host:key(owner)]
        if entry and entry.binding then entry.binding:hide_native()end
      end
    end)
  end
  hook('/Script/Engine.SkinnedMeshComponent:SetSkeletalMesh',mesh_changed)
  hook('/Script/Engine.SkeletalMeshComponent:SetSkeletalMeshAsset',mesh_changed)
  self.action=LoopInGameThreadAfterFrames(1,function()
    self:guard('tick',function()
      self.ticks=self.ticks+1
      self:ensure('local-player-discovery')
      if self.protagonist_world and (self.scan_world~=self.protagonist_world or self.scan_requested and not self.mesh_scan) then
        self.scan_world=self.protagonist_world;self.scan_requested=nil
        -- The skeletal inventory also contains every known character class.
        -- Enumerating four classes (including unloaded story variants) ahead
        -- of it caused a large synchronous stall at combat-camera handoffs.
        local known={}
        for _,path in pairs(protagonist_classes)do
          local class=StaticFindObject(path:match('^[^ ]+ (.+)$'))
          if Appearance.valid(class)then known[#known+1]=class end
        end
        self.mesh_scan={items=FindAllOf('SkeletalMeshComponent') or {},index=1,seen={},known=known}
      end
      local scan=self.mesh_scan
      if scan then
        local deadline=os.clock()+.0007
        for i=scan.index,math.min(scan.index+7,#scan.items) do
          scan.index=i+1
          local component=scan.items[i]
          if Appearance.valid(component)then
            local asset=component:GetSkeletalMeshAsset()
            local actor=component:GetOwner()
            if Appearance.valid(actor)and not scan.seen[actor:GetAddress()]then
              local match=Appearance.valid(asset)and self.protagonist_assets[asset:GetFullName()]
              if not match then
                for _,class in ipairs(scan.known)do if actor:IsA(class)then match=true;break end end
              end
              if match then scan.seen[actor:GetAddress()]=true;self:consider(actor,'mesh-discovery',component)end
            end
          end
          if os.clock()>=deadline then break end
        end
        if scan.index>#scan.items then self.mesh_scan=nil end
      end
      local ok,why=self.registry:tick();assert(ok,why)
      for key in pairs(self.source_hints)do if not self.registry.entries[key]then self.source_hints[key]=nil end end
    end)
  end)
  log('appearance lifecycle started; local player and verified protagonist doubles, one game-thread pose writer')
  return self
end
return M
