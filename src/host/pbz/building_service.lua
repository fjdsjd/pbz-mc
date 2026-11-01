-- Playable building owner, independent of selected weapon/camera. World actor
-- lifetime follows the player/campaign binding; only stable records are saved.
local registry=require('content.blocks')
local campaign=require('host.pbz.campaign_inventory')
local placement=require('host.pbz.build_placement')
local mining=require('rules.block_mining')
local M={};local active
local function current(self) return self.store:current() and self.world:is_current() end
function M.get(binding) return active and active.binding==binding and active or nil end
function M.close()
  if not active then return true end
  active:cancel()
  if active.mechanisms then active.mechanisms:close()end
  local ok,why=active.session:close()
  if ok then active=nil end
  return ok,why
end
function M.ensure(binding,directory,log)
  if active and (active.binding~=binding or not current(active)) then
    local ok,why=M.close();assert(ok,why)
  end
  if not active then
    local world=require('host.pbz.build_world').new(registry,log,directory..'/pbzmc-assets')
    local store=campaign.build_store(binding)
    local self={binding=binding,world=world,store=store,log=log,placed=0,removed=0,progress=0,preload=0}
    self.audio=require('host.pbz.block_sounds').new(directory..'/pbzmc-assets',log)
    local pc=require('UEHelpers').GetPlayerController()
    self.session=require('runtime.build_session').attach(store,'free',world,registry)
    function self:cancel()
      if self.mining then
        local h=self.session.handles[self.mining]
        local r=self.session.data.buildings[self.mining]
        if h and r and current(self) then self.world:set_crack(h,registry.get(r.content_id).model,nil) end
      end
      self.mining=nil;self.progress=0;self.next_sound=0;self.sound_tick=nil;self.mining_run=mining.new();self.mining_sample=nil
    end
    self.target=placement.target
    self.place=placement.place
    function self:mine(record,aim)
      local hit,handle
      if record.held then hit,handle=self:target(aim) end
      local id=handle and handle.id
      if self.mining~=id then
        self:cancel();self.mining=id
        if handle and self.world.warm_cracks then self.world:warm_cracks(handle.model) end
      end
      if not id then return false end
      if (self.next_break or 0)>record.now then return true end
      local block=self.session.data.buildings[id];local definition=registry.get(block.content_id)
      if definition.fluid then self:cancel();return false end
      if definition.mechanism=='piston_head'then
        local ids=self.mechanisms:expand_removals({id})
        for _,rid in ipairs(ids)do local r=self.session.data.buildings[rid];if r and r.content_id~='pbzmc:piston_head'then block=r;definition=registry.get(r.content_id);break end end
      end
      local tool_id=record.equipment.main and record.equipment.main.content_id or false
      local creative=self.binding.mc_creative==true
      if creative and tool_id then
        local kind=require('content.combat_profiles').get(tool_id).kind
        if kind=='sword' or kind=='trident'then self:cancel();return false end
      end
      local movement=self.binding.actor and self.binding.actor.CharacterMovement
      local mode=movement and movement.MovementMode or 1
      local grounded,submerged=mode~=3,mode==4
      -- Cache the pure sample until the tool or environment changes. Never
      -- allocate a new rules table or scan block/tool definitions per frame.
      if not self.mining_sample or self.mining_tool~=tool_id or self.mining_grounded~=grounded or self.mining_submerged~=submerged or self.mining_creative~=creative then
        self.mining_sample=assert(mining.sample(block.content_id,tool_id,{on_ground=grounded,submerged=submerged}))
        if creative then self.mining_sample={instant=true,progress_per_tick=1,breakable=true,ticks=0}end
        self.mining_creative=creative
        self.mining_tool=tool_id;self.mining_grounded=grounded;self.mining_submerged=submerged
      end
      self.mining_run=self.mining_run or mining.new()
      self.progress=mining.advance(self.mining_run,record.dt,self.mining_sample)
      local sound_tick=self.mining_run.ticks>0 and math.floor((self.mining_run.ticks-1)/4) or nil
      if not self.mining_sample.instant and sound_tick and sound_tick~=self.sound_tick then
        if definition.mechanism then self.mechanisms:sound((definition.sound_group or 'stone')..'_hit',block)
        else self.audio:play('hit',block,pc)end
        self.sound_tick=sound_tick
      end
      if self.progress>=1 then
        local ok,why;local count=1
        if record.chain_mining then
          local connected=require('rules.connected_blocks').find(self.session.data.buildings,self.session.handles,id)
          ok,why=require('rules.remove_buildings')(self.session,connected,self.world,self.store)
          if ok then count=why end
        else ok,why=self.session:remove(id,'mined') end
        self.last_rejection=not ok and why or nil
        if ok then
          self.removed=self.removed+count;self.last_chain=count
          self.log('building removed '..id..' count='..count..' no drop/refund')
          if definition.mechanism then self.mechanisms:sound((definition.sound_group or 'stone')..'_break',block)
          else self.audio:play('break',block,pc)end
          -- The first zero-hardness hit remains instant. Continuing to hold
          -- attack must not drill through one new block per render frame.
          local delay=(mining.break_delay_ticks or 5)/20
          self.mining=nil;self.progress=0;self.mining_run=nil;self.mining_sample=nil;self.sound_tick=nil
          self.next_break=record.now+delay
        end
      else self.world:set_crack(handle,definition.model,self.progress>0 and math.min(9,math.floor(self.progress*10)) or nil) end
      return true
    end
    function self:state()
      local records,handles=0,0
      for _,r in pairs(self.session.data.buildings) do if r.world==self.world.world_id then records=records+1 end end
      for _ in pairs(self.session.handles) do handles=handles+1 end
      return {world=self.world.world_id,generation=self.store.generation,records=records,handles=handles,
        pending=#self.session.pending,placed=self.placed,removed=self.removed,last_chain=self.last_chain,
        mining=self.mining,progress=self.progress,mining_rule=self.mining_sample,mining_ticks=self.mining_run and self.mining_run.ticks,
        last_id=self.last_id,last_rejection=self.last_rejection,buildings=self.session.data.buildings,
        last_place_ms=self.last_place_ms,last_transaction_ms=self.last_transaction_ms,place_samples_ms=self.place_samples,
        collision=true,infinite=true,drops=false,quarantined=self.session.quarantined or false,
        grid=self.session.grid,
        rendering=self.world:render_stats(),mechanisms=self.mechanisms and self.mechanisms:state(),
        restore_error=self.restore_error,audio={ready=self.audio.ready,played=self.audio.played,error=self.audio.error,
          counts=self.audio.counts,last=self.audio.last}}
    end
    self.mechanisms=require('host.pbz.mechanism_service').new(self)
    active=self;log('production buildings bound; restore='..#self.session.pending)
  end
  active.world:prewarm()
  if #active.session.pending>0 then
    local now=os.clock()
    if now>=(active.restore_at or 0) then
      local ok,why=active.session:restore_batch(1)
      active.restore_error=not ok and why or nil
      active.restore_at=ok and 0 or now+1
    end
  end
  active.session:poll_cleanup()
  active.world:poll_faces(2)
  if active.mechanisms then
    active.game_clock=active.game_clock or StaticFindObject('/Script/Engine.Default__GameplayStatics')
    active.mechanisms:tick(active.game_clock:GetTimeSeconds(active.binding.actor))
  end
  return active
end
return M
