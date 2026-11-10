-- Run with Lua 5.4 from the repository root.
package.path='src/?.lua;third_party/dkjson/?.lua;'..package.path
local input=require('presentation.hotbar_input').new()
local context={kind='game',weapon_group='pbz',epoch=1,unified_hotbar=true}
local epoch=1
local function sample(keys,buttons,wheel,focused)
  return input:update({keys=keys,buttons=buttons,epoch=epoch,wheel_delta=wheel,focused=focused~=false},context)
end
for _,group in ipairs({'pbz','mc','pbz'}) do
  epoch=epoch+1;context.weapon_group=group
  assert(#sample(16,1,0)==0) -- held 1 and attack belong to the previous context
  for i=2,9 do
    local held=16|(1<<(i+3))
    local events=sample(held,1,0)
    assert(#events==1 and events[1].kind=='select_slot' and events[1].index==i)
    assert(#sample(held,1,0)==0)
    sample(16,1,0)
  end
  assert(#sample(16,1,60)==0 and sample(16,1,60)[1].steps==-1)
  assert(sample(16,1,-240)[1].steps==2)
  assert(sample(17,1,0)[1].kind=='open_inventory')
end
assert(#sample(0,0,60)==0)
assert(#sample(0,0,0,false)==0)
assert(#sample(16,1,0)==0 and #sample(16,1,60)==0)
-- In combat PBZ can report HasAnyRootMotion=true after a manual unlock,
-- even though no attack, root-motion animation or weapon transition is active.
local class_path='/Script/SGameInputSystem.AbilityInputComponent'
local class={ForEachProperty=function(_,visit)
  visit({IsValid=function()return true end,GetFName=function()return {ToString=function()return 'InActionPhase' end}end,
    GetFullName=function()return 'BoolProperty '..class_path..':InActionPhase' end,GetOffset_Internal=function()return 416 end})
end}
function IsInGameThread()return true end
function StaticFindObject(path)assert(path==class_path);return class end
local handler={InActionPhase=false,IsValid=function()return true end,IsA=function(_,type_)return type_==class end}
local actor={['Ability Input Component']=handler,HasAnyRootMotion=function()return true end,
  IsPlayingRootMotion=function(self)return self.playing end}
local pc={Pawn=actor,IsLookInputIgnored=function()return false end,IsMoveInputIgnored=function()return false end}
local dispatch=require('host.pbz.native_input_dispatch')
local function idle()return dispatch.action_idle(pc,function()return true end)end
assert(idle());actor.playing=true;assert(not idle());actor.playing=false
handler.InActionPhase=true;assert(not idle());handler.InActionPhase=false
local native=require('rules.native_slot_reference')
local slot=native.new('main',0)
local data={player={selected=1,hotbar={['1']=slot,['2']={content_id='pbzmc:wooden_sword'}}}}
local camera={release_movement=function()end}
package.loaded['host.pbz.first_person_camera']={get=function()return camera end}
local busy=true;local reads=0
local reader={check=function()return true end,observe=function()reads=reads+1;error('story loadout cannot be read')end}
package.loaded['host.pbz.native_weapon_request']={new=function()return reader end}
package.loaded['host.pbz.native_input_dispatch']={action_idle=function(_,validate)validate();return not busy end}
package.loaded['host.pbz.campaign_inventory']={view=function()return data,1 end,
  dispatch=function(_,req,_,authorize)
    assert(authorize(data.player.hotbar[tostring(data.player.selected)],data.player.hotbar[tostring(req.index)]))
    data.player.selected=req.index
  end}
local selector=require('host.pbz.hotbar_equipment').new({}, {},1,function()return context end,function()end)
assert(selector:request({kind='scroll_slots',steps=1},data,1,context,1))
selector:tick(8);assert(data.player.selected==1 and selector.pending and reads==0)
selector:queue({kind='scroll_slots',steps=1})
selector:tick(8.1);assert(selector.pending.request.index==3)
selector:queue({kind='select_slot',index=2})
selector:tick(8.2);assert(selector.pending.request.index==2)
busy=false;selector:tick(8.3)
assert(data.player.selected==2 and not selector.pending and not camera.transition and reads==0)
context.weapon_group='mc'
assert(not pcall(selector.request,selector,{kind='select_slot',index=1},data,1,context,1.2))
assert(data.player.selected==2 and not selector.pending and not camera.transition and reads==1)
print('PASS held-input navigation, focus boundary, PBZ action completion and native slot read failure isolation')
