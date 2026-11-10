-- Vanilla Bedrock state controllers, keyframes and Molang, with host state
-- supplied separately. Files and expression compilation are shared per library.
local molang=require('presentation.molang')
local motion=require('presentation.mob_motion')
local M={};M.__index=M
local channels={'position','rotation','scale'}
local axes={x=1,y=2,z=3}
local function clamp(n,a,b)return math.max(a,math.min(b,n))end
local function copy(v)return {v[1]or 0,v[2]or 0,v[3]or 0}end
local function finite(v)return type(v)=='number'and v==v and math.abs(v)<1e8 end
function M.library(data)
 assert(data.schema==1,'mob-animation-schema')
 local lib={entities=data.entities,animations=data.animations,controllers=data.controllers,expressions={}}
 for i,node in ipairs(data.expressions)do lib.expressions[i]=molang.compile(node)end
 -- Some client definitions list the same controller both in scripts.animate
 -- (possibly with a weight) and in the legacy animation_controllers array.
 -- The compiled schedule appends the legacy IDs after the explicit aliases.
 for _,entity in pairs(lib.entities)do
   local named,run={},{}
   for _,step in ipairs(entity.run)do
     local alias=type(step)=='string' and step or next(step)
     if type(step)~='string' or not named[step] then run[#run+1]=step end
     local id=entity.aliases[alias]
     if lib.controllers[id] then named[id]=true end
   end
   entity.run=run
 end
 local function prepare(channel)
   if type(channel)~='table'or channel.e or channel.ordered or #channel>0 then return end
   if channel.pre or channel.post then prepare(channel.pre);prepare(channel.post);return end
   local keys={};for k,v in pairs(channel)do if tonumber(k)then keys[#keys+1]={time=tonumber(k),value=v}end end
   table.sort(keys,function(a,b)return a.time<b.time end);channel.keys=keys
 end
 for _,a in pairs(lib.animations)do
   for _,bone in pairs(a.bones)do for _,c in pairs(bone)do prepare(c)end end
 end
 for _,c in pairs(lib.controllers)do for _,state in pairs(c.states)do
   for _,v in pairs(state.variables)do if type(v)=='table'and v.remap_curve then
     local keys={};for x,y in pairs(v.remap_curve)do keys[#keys+1]={tonumber(x),y}end
     table.sort(keys,function(a,b)return a[1]<b[1]end);v.curve_keys=keys
   end end
 end end
 return lib
end
function M.new(lib,name,rig)
 if name=='ender_dragon' then return require('presentation.dragon_model').new(rig) end
 local self=setmetatable({lib=lib,entity=assert(lib.entities[name],'missing-vanilla-animation:'..name),
   rig=rig,poses={},controllers={},playing={},
   -- Vanilla humanoids divide their stride by this engine-supplied value.
   -- Summoned mobs do not use Elytra, including naturally flying species.
   vars={['variable.gliding_speed_value']=1},frame=0},M)
 for name,b in pairs(rig)do self.poses[name]={rotation=copy(b.rotation),position=copy(b.pivot),scale={1,1,1}}end
 self.visibility={}
 for _,rule in ipairs(self.entity.visibility or {})do
   local pattern='^'..rule[1]:gsub('([%^%$%(%)%%%.%[%]%+%-%?])','%%%1'):gsub('%*','.*')..'$'
   for name in pairs(rig)do if name:match(pattern)then self.visibility[#self.visibility+1]={name,rule[2],rule[3]}end end
 end
 self.query=function(k,a,b,c,d)return self:query_value(k,a,b,c,d)end
 return self
end
function M:value(v)
 if type(v)=='table'and v.e then return self.lib.expressions[v.e](self)end
 return v
end
function M:query_value(k,a,b,c,d)
 local q=self.q
 if q[k]~=nil then return q[k]end
 local m=self.mob
 if k=='position_delta'then return self.delta[(tonumber(a)or 0)+1]or 0 end
 if k=='movement_direction'then local n=math.sqrt(self.delta[1]^2+self.delta[2]^2+self.delta[3]^2);return n>0 and (self.delta[(tonumber(a)or 0)+1]or 0)/n or 0 end
 if k=='head_x_rotation'or k=='target_x_rotation'or k=='eye_target_x_rotation'then return self.look_pitch or 0 end
 if k=='head_y_rotation'or k=='target_y_rotation'or k=='eye_target_y_rotation'then return self.look_yaw or 0 end
 if k=='bone_origin'or k=='bone_rotation'then
   local bone=self.rig[tostring(a):lower()];local v=bone and (k=='bone_origin'and bone.pivot or bone.rotation)
   return v and (v[(tonumber(b)or 0)+1]or 0)or 0
 end
 if k=='get_equipped_item_name'then return (a=='off_hand' or a=='slot.weapon.offhand')and ''or self.weapon or ''end
 if k=='is_item_equipped'then return a==1 and 0 or self.weapon and 1 or 0 end
 if k=='is_item_name_any'then return self.weapon and (b=='minecraft:'..self.weapon or c=='minecraft:'..self.weapon or d=='minecraft:'..self.weapon)and 1 or 0 end
 if k=='property'then
   if a=='minecraft:climate_variant'then return 'temperate'end
   return a=='minecraft:sulfur_cube_archetype'and 'hot'or 0
 end
 if k=='model_scale'then return 1 end
 if k=='camera_rotation'then return a==0 and (self.look_pitch or 0)or self.look_yaw or 0 end
 if k=='time_since_last_vibration_detection'then return -1 end
 -- These queries describe unentered vanilla states (breeding, trade, sleep,
 -- riding etc.). Their default is false; supported host states are explicit q.
 return 0
end
local function catmull(a,b,c,d,t)return .5*((2*b)+(-a+c)*t+(2*a-5*b+4*c-d)*t*t+(-a+3*b-3*c+d)*t*t*t)end
function M:channel(value,axis,time,post)
 if type(value)~='table'or value.e then return self:value(value)end
 if #value>0 then return self:value(value[axis])end
 if value.pre or value.post then return self:channel(post and (value.post or value.pre)or (value.pre or value.post),axis,time,post)end
 local keys=value.keys
 if not keys or #keys==0 then return 0 end
 if time<=keys[1].time then return self:channel(keys[1].value,axis,time,false)end
 for i=2,#keys do
   local left,right=keys[i-1],keys[i]
   if time<right.time then
     local t=clamp((time-left.time)/(right.time-left.time),0,1);self.q.key_frame_lerp_time=t
     local a=self:channel(left.value,axis,time,true);local b=self:channel(right.value,axis,time,false)
     if type(left.value)=='table'and left.value.lerp_mode=='catmullrom' then
       return catmull(self:channel(keys[math.max(1,i-2)].value,axis,time,true),a,b,
         self:channel(keys[math.min(#keys,i+1)].value,axis,time,false),t)
     end
     return a+(b-a)*t
   end
 end
 return self:channel(keys[#keys].value,axis,time,true)
end
function M:animation(key,weight)
 local a=self.lib.animations[key];if not a or weight==0 then return end
 local playing=self.playing[key]
 if not playing or playing.frame<self.frame-1 then
   playing={time=0,start=self.now+(a.start_delay and self:value(a.start_delay)or 0)};self.playing[key]=playing
 end
 playing.frame=self.frame
 if self.now<playing.start then self.finished_all=false;return end
 local time=playing.time
 self.q.anim_time=time
 if playing.updated~=self.frame then time=a.anim_time_update and self:value(a.anim_time_update)or time+self.dt end
 local length=a.animation_length or 0
 local finished=length>0 and time>=length
 self.finished_any=self.finished_any or finished;self.finished_all=self.finished_all and finished
 if length>0 then
   if a.loop==true then
     if time>=length and a.loop_delay then playing.start=self.now+self:value(a.loop_delay)end
     time=time%length
   else time=math.min(time,length)end
 end
 playing.time=time;playing.updated=self.frame;self.q.anim_time=time
 weight=weight*(a.blend_weight and self:value(a.blend_weight)or 1)
 for name,bone in pairs(a.bones)do
   local pose=self.poses[name];local rest=self.rig[name]
   if pose then
     if a.override_previous_animation then
       for i=1,3 do pose.position[i]=rest.pivot[i];pose.rotation[i]=rest.rotation[i];pose.scale[i]=1 end
       pose.entity_rotation=false
     end
     if bone.entity_rotation then pose.entity_rotation=true end
     for _,key in ipairs(channels)do
       local channel=bone[key]
       if channel then
         if type(channel)=='table'and channel.ordered then
           pose.ordered=pose.ordered or {}
           for _,row in ipairs(channel.ordered)do
             local axis=axes[row[1]];self.this=pose.rotation[axis]
             pose.ordered[#pose.ordered+1]={axis,self:value(row[2])*weight}
           end
         else
           for i=1,3 do
             local origin=key=='position'and (bone.position_origin or rest.pivot)
             self.this=pose[key][i]-(origin and origin[i]or 0)
             local value=self:channel(channel,i,time,true)
             assert(finite(value),'nonfinite-mob-animation:'..name..':'..key)
             if key=='scale'then pose.scale[i]=pose.scale[i]*(1+(value-1)*weight)
             else pose[key][i]=pose[key][i]+value*weight end
           end
         end
       end
     end
   end
 end
end
function M:rows(rows,weight,depth)
 for _,row in ipairs(rows)do
   if type(row)=='string'then self:run(row,weight,depth)
   else for key,value in pairs(row)do local w=self:value(value);if molang.truth(w)then self:run(key,weight*molang.num(w),depth)end end end
 end
end
function M:run(alias,weight,depth)
 assert(depth<12,'cyclic-mob-animation-controller')
 local key=self.entity.aliases[alias]or alias;local controller=self.lib.controllers[key]
 if not controller then self:animation(key,weight);return end
 local live=self.controllers[key]
 if not live then
   live={state=controller.initial_state,at=self.now};self.controllers[key]=live
   self:value(controller.states[live.state].on_entry)
 end
 local state=assert(controller.states[live.state]);local blend=live.blend or 0
 local progress=live.prior and blend>0 and clamp((self.now-live.at)/blend,0,1)or 1
 for k,v in pairs(state.variables)do
   if type(v)=='table'and v.input then
     local x=self:value(v.input);local curve=v.remap_curve
     if curve then
       local keys=v.curve_keys
       local out=keys[1][2]
       for i=2,#keys do local a,b=keys[i-1],keys[i];out=x<b[1]and a[2]+(b[2]-a[2])*clamp((x-a[1])/(b[1]-a[1]),0,1)or b[2];if x<b[1]then break end end
       x=out
     end
     self.vars['variable.'..k]=x
   else self.vars['variable.'..k]=self:value(v)end
 end
 local any,all=self.finished_any,self.finished_all;self.finished_any=false;self.finished_all=true
 if progress<1 then self:rows(controller.states[live.prior].animations,weight*(1-progress),depth+1)end
 self:rows(state.animations,weight*progress,depth+1)
 self.q.any_animation_finished=self.finished_any and 1 or 0;self.q.all_animations_finished=self.finished_all and 1 or 0
 for _,row in ipairs(state.transitions)do
   local changed=false
   for target,condition in pairs(row)do
     if molang.truth(self:value(condition))then
       self:value(state.on_exit);live.prior=live.state;live.state=target;live.at=self.now;live.blend=state.blend_transition or 0
       self:value(assert(controller.states[target]).on_entry);changed=true;break
     end
   end
   if changed then break end
 end
 self.finished_any=any or self.finished_any;self.finished_all=all and self.finished_all
end
function M:update(m,now)
 self.mob=m;self.now=now;self.frame=self.frame+1
 local dt=math.max(0,math.min(.25,now-(self.previous_time or now)));self.previous_time=now;self.dt=dt
 self.born=self.born or now
 local p=m.position or {X=0,Y=0,Z=0};local old=self.previous_position or p
 local x,y,z=p.X-old.X,p.Y-old.Y,p.Z-old.Z
 if x*x+y*y+z*z>400^2 then x,y,z=0,0,0 end
 self.delta={-y/100,z/100,-x/100};self.previous_position={X=p.X,Y=p.Y,Z=p.Z}
 local speed=dt>0 and math.sqrt(x*x+y*y)/dt or 0
 local target=math.min(1,speed*.002)
 self.walk_speed=(self.walk_speed or 0)+(target-(self.walk_speed or 0))*(1-.6^(dt*20))
 self.walk_pos=(self.walk_pos or 0)+self.walk_speed*dt*20
 local ground=m.move and m.move.MovementMode==1
 local elapsed=now-(m.last_attack or -10);local kind=m.last_attack_kind or m.def.attack
 local strike=elapsed>=0 and elapsed<.5 and kind~='sonic'
 local charge=m.charge_started~=nil
 local q={life_time=now-self.born,delta_time=dt,anim_time=0,modified_distance_moved=self.walk_pos,
   modified_move_speed=self.walk_speed,ground_speed=speed/100,vertical_speed=dt>0 and z/dt/100 or 0,
   is_moving=speed>1 and 1 or 0,is_on_ground=ground and 1 or 0,is_alive=(m.health or 1)>0 and 1 or 0,
   is_jumping=not ground and z>0 and 1 or 0,is_jump_goal_jumping=not ground and z>0 and 1 or 0,
   is_in_water=m.swimming and 1 or 0,is_swimming=m.swimming and 1 or 0,swim_amount=m.swimming and 1 or 0,
   has_target=m.target and 1 or 0,is_angry=m.target and 1 or 0,is_charging=charge and 1 or 0,
   is_delayed_attacking=(charge or strike)and 1 or 0,is_sonic_boom=(m.charging_kind or kind)=='sonic'and (charge or elapsed<1.3)and 1 or 0,
   is_casting=kind=='fang'and (charge or strike)and 1 or 0,is_using_item=charge and 1 or 0,
   facing_target_to_range_attack=m.target and 1 or 0,hurt_time=math.max(0,10-(now-(m.last_hurt or -10))*20),
   death_ticks=m.dying_until and math.max(0,(now-m.dying_until+.6)*20)or 0,
   swell_amount=(m.fuse or 0)/1.5,fuse_time=m.fuse or 0,wing_flap_position=(now-self.born)*20,
   wing_flap_speed=1,frame_alpha=0,standing_scale=0,life_span=math.huge,
   is_eating_mob=kind=='tongue'and strike and 1 or 0,is_gliding=m.def.flies and 1 or 0}
 self.q=q
 motion.update(self,m,dt,speed,dt>0 and z/dt or 0,ground)
 local look=m.look_at
 if look then
   local dx,dy,dz=look.X-p.X,look.Y-p.Y,look.Z-p.Z
   local yaw_limit=m.def.name=='shulker'and 180 or 75
   local pitch_limit=m.def.name=='shulker'and 180 or 45
   self.look_yaw=clamp((math.deg(math.atan(dy,dx))-(m.yaw or 0)+180)%360-180,-yaw_limit,yaw_limit)
   self.look_pitch=clamp(-math.deg(math.atan(dz,math.sqrt(dx*dx+dy*dy))),-pitch_limit,pitch_limit)
 else self.look_yaw=0;self.look_pitch=0 end
 local weapons={arrow='bow',trident='trident',potion='splash_potion'}
 self.weapon=weapons[m.def.attack]
 if m.def.name=='pillager'or m.def.name=='piglin'then self.weapon='crossbow'end
 self.vars['variable.attack_time']=strike and elapsed/.5 or 0
 if m.command_swing then
   local s=m.command_swing
   if not s.cancelled and now>=s.start and now<s.start+s.duration then
     self.vars['variable.attack_time']=clamp((now-s.start)/s.duration,0,1)
   else m.command_swing=nil end
 end
 self.vars['variable.is_holding_bow']=self.weapon=='bow'and 1 or 0
 self.vars['variable.is_brandishing_spear']=self.weapon=='trident'and 1 or 0
 self.vars['variable.is_sneaking']=0
 if not self.initialized then self:value(self.entity.initialize);self.initialized=true end
 for name,pose in pairs(self.poses)do
   local base=self.rig[name];pose.ordered=nil;pose.entity_rotation=false;pose.visible=true
   for i=1,3 do pose.position[i]=base.pivot[i];pose.rotation[i]=base.rotation[i]or 0;pose.scale[i]=1 end
 end
 self:value(self.entity.pre);self.finished_any=false;self.finished_all=true
 self:rows(self.entity.run,1,0)
 local scale={};self.base_scale=self.base_scale or {}
 for i,value in ipairs(self.entity.scale or {1,1,1})do
   local n=self:value(value);assert(finite(n),'invalid-vanilla-entity-scale')
   self.base_scale[i]=self.base_scale[i]or (math.abs(n)>.001 and n or 1)
   scale[i]=n/self.base_scale[i]
 end
 for name,pose in pairs(self.poses)do if not self.poses[self.rig[name].parent]then
   for i=1,3 do pose.scale[i]=pose.scale[i]*scale[i]end
 end end
 for _,row in ipairs(self.visibility)do
   if molang.truth(self:value(row[3]))then self.poses[row[1]].visible=molang.truth(self:value(row[2]))end
 end
 return self.poses
end
return M
