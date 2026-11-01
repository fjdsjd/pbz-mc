-- One owned pause and ignore-input entry. UIOnly keeps gameplay input out of
-- the container; the native foreground snapshot supplies UI button edges.
local identity=require('host.pbz.object_identity')
local valid=require('host.pbz.appearance').valid
local json=require('dkjson')
local M={}
local function object(path)
  local value=StaticFindObject(path);assert(value and value:IsValid(),'input-api-unavailable:'..path);return value
end
local function enum(path,name)
  local value
  object(path):ForEachName(function(key,number)
    local text=key:ToString();if text==name or text:match('::([^:]+)$')==name then value=number end
  end)
  assert(value~=nil,'input-enum-unavailable:'..name);return value
end
function M.pointer()
  assert(type(PBZMC_ReadPointerState)=='function','native-pointer-bridge-required')
  local text,why=PBZMC_ReadPointerState();assert(text,why)
  local state=assert(json.decode(text));assert(type(state.focused)=='boolean','invalid-pointer-snapshot')
  return state
end
function M.events()
  local text,why=PBZMC_ReadPointerEvents();assert(text,why)
  local batch=assert(json.decode(text))
  assert(type(batch.samples)=='table' and type(batch.latest)=='table','invalid-pointer-events')
  return batch
end
function M.acquire(ui,binding,log,options)
  options=options or {}
  assert(ui:valid() and binding:is_current(),'inventory-input-owner-unavailable')
  assert(M.pointer().focused,'inventory-requires-game-foreground')
  local pc
  for _,candidate in ipairs(FindAllOf('PlayerController') or {}) do
    if valid(candidate) and candidate:IsLocalPlayerController() and identity.matches(candidate.Pawn,binding.actor_id) then
      assert(not pc,'multiple-local-inventory-controllers');pc=candidate
    end
  end
  assert(pc,'inventory-local-controller-unavailable')
  local gameplay=object('/Script/Engine.Default__GameplayStatics')
  local widgets=object('/Script/UMG.Default__WidgetBlueprintLibrary')
  assert(not gameplay:IsGamePaused(pc),'inventory-native-pause-already-owned')
  local self={pc=pc,pc_id=identity.capture(pc),world_id=identity.capture(pc:GetWorld()),
    old_cursor=pc.bShowMouseCursor,old_capture=gameplay:GetViewportMouseCaptureMode(pc),log=log or function() end}
  function self:current()
    return valid(self.pc) and identity.matches(self.pc,self.pc_id) and identity.matches(self.pc:GetWorld(),self.world_id)
  end
  function self:release()
    if self.released then return true end
    local function stop_pointer()
      if self.pointer_capture then local done,why=PBZMC_EndPointerCapture();assert(done,why);self.pointer_capture=false end
    end
    if not self:current() then stop_pointer();self.released=true;return true end
    -- Never focus an old/unfocused viewport while the user is in another app.
    local pointer=options.pointer and options.pointer() or M.pointer()
    if not pointer.focused then return false end
    if (pointer.keys or 0)~=0 or (pointer.buttons or 0)~=0 then
      -- A permanent MC input owner can quarantine held controls in a new
      -- epoch. Standalone/native input still waits for physical release.
      if not self.held_quarantined then
        if not options.quarantine_held or not options.quarantine_held() then return false end
        self.held_quarantined=true
      end
    end
    if self.move then pc:SetIgnoreMoveInput(false);self.move=false end
    if self.look then pc:SetIgnoreLookInput(false);self.look=false end
    if self.ui_only then
      pc.bShowMouseCursor=self.old_cursor
      widgets:SetInputMode_GameOnly(pc,true)
      local capture=self.old_capture
      if capture==enum('/Script/Engine.EMouseCaptureMode','NoCapture') then
        capture=enum('/Script/Engine.EMouseCaptureMode','CapturePermanently_IncludingInitialMouseDown')
      end
      gameplay:SetViewportMouseCaptureMode(pc,capture)
      widgets:SetFocusToGameViewport();self.ui_only=false
    end
    if self.paused then assert(gameplay:SetGamePaused(pc,false),'inventory-unpause-failed');self.paused=false end
    stop_pointer()
    self.released=true;self.log('inventory input released; game cursor/capture restored')
    return true
  end
  local ok,why=pcall(function()
    if not options.external_events then
      local capturing,err=PBZMC_BeginPointerCapture();assert(capturing,err);self.pointer_capture=true
    end
    pc:SetIgnoreLookInput(true);self.look=true
    pc:SetIgnoreMoveInput(true);self.move=true
    assert(gameplay:SetGamePaused(pc,true),'inventory-pause-failed');self.paused=true
    self.ui_only=true -- Cleanup also handles a setter that fails partway.
    pc.bShowMouseCursor=true
    widgets:SetInputMode_UIOnlyEx(pc,nil,enum('/Script/Engine.EMouseLockMode','DoNotLock'),true)
    gameplay:SetViewportMouseCaptureMode(pc,enum('/Script/Engine.EMouseCaptureMode','NoCapture'))
    self.log('inventory input acquired; UIOnly cursor=true pause=true look/move ignored')
  end)
  if not ok then
    local released,done=pcall(self.release,self)
    if not released or not done then self.creation_failure=tostring(why);return self end
    error(why)
  end
  return self
end
return M
