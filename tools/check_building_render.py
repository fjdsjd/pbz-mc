"""Rendering/shape/lease regressions; native swept walking is tested in PBZ."""
from pathlib import Path
import argparse,json,sys
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'build/lua-check'))
from lupa.lua54 import LuaRuntime

def main():
    p=argparse.ArgumentParser();p.add_argument('--assets',type=Path,required=True);a=p.parse_args()
    lua=LuaRuntime(unpack_returned_tuples=True)
    lua.execute("package.path=... ..'/src/?.lua;'.. ... ..'/third_party/dkjson/?.lua;'..package.path", ROOT.as_posix())
    # Compile every production module, including infrequently entered branches.
    for f in (ROOT/'src').rglob('*.lua'):lua.execute('assert(load(...))',f.read_text('utf8'))
    result=lua.execute(r'''
      local root=...;local Cat=require('host.pbz.construction_assets');local c=Cat.open(root)
      local checks=0;local function check(ok,label)checks=checks+1;assert(ok,label)end
      -- Scene decals must never project through MC skins, armor or atlases.
      -- Multiple sections and later item swaps reuse the component setting.
      local bundle=require('host.pbz.mesh_bundle')
      local function mesh()
        local o={uploads=0,decals=0,depth=true,shadow=true,collision=3}
        function o:SetReceivesDecals(value)
          assert(value==false);self.decals=self.decals+1;self.receives_decals=value
        end
        function o:CreateMeshSection_LinearColor(section)self.uploads=self.uploads+1;self.section=section end
        return o
      end
      local part={positions={},triangles={},normals={},uv={},colors={}}
      local m=mesh();bundle.apply(m,part);bundle.apply(m,part,1);bundle.apply(m,part)
      check(m.decals==1 and m.uploads==3 and m.receives_decals==false,'configure decal isolation once')
      check(m.depth and m.shadow and m.collision==3,'preserve depth shadows and collision')
      local second=mesh();bundle.apply(second,part)
      check(second.decals==1,'new component configured independently')
      local retry=mesh();local configure=retry.SetReceivesDecals
      retry.SetReceivesDecals=function()error('injected decal failure')end
      check(not pcall(bundle.apply,retry,part)and retry.uploads==0,'fail before publishing unsafe mesh')
      retry.SetReceivesDecals=configure;bundle.apply(retry,part)
      check(retry.decals==1 and retry.uploads==1,'configuration failure is retryable')
      local Pixel=require('host.pbz.pixel_texture')
      local texture={Filter=3,IsValid=function()return true end,GetFullName=function()return 'Texture2D /Engine/Transient.Texture2D_123' end}
      local refreshes=0;PBZMC_RefreshPixelTexture=function(path)
        check(path=='/Engine/Transient.Texture2D_123' and texture.Filter==0,'nearest before resource refresh')
        refreshes=refreshes+1;return true
      end
      check(Pixel.configure(texture)==texture and refreshes==1,'refresh imported texture once')
      texture.GetFullName=function()return 'Texture2D /Game/PBZ/NativeTexture' end
      check(not pcall(Pixel.configure,texture)and refreshes==1,'never refresh original PBZ textures')
      texture.GetFullName=function()return 'Texture2D /Engine/Transient.Texture2D_123' end
      PBZMC_RefreshPixelTexture=function()return nil,'incompatible UpdateResource' end
      local ok,err=pcall(Pixel.configure,texture)
      check(not ok and tostring(err):find('incompatible UpdateResource',1,true),'report incompatible native resource refresh')
      local blocks=require('content.blocks');local geometry=require('rules.placement_geometry')
      for _,name in ipairs({'stone_bricks','oak_log','oak_planks','dirt','tnt','spawner','glass','stone_brick_stairs','stone_slab'})do
        local r={content_id='pbzmc:'..name,x=0,y=0,z=0,properties={}}
        check(c:block(name).render_layer=='cutout',name..' depth material')
        if blocks.get(r.content_id).full_cube then check(#c:part(c:model(r)).positions<=(name=='spawner'and 48 or 24),name..' compact cube')end
      end
      check(c:block('red_stained_glass').render_layer=='translucent','stained glass alpha')
      for _,facing in ipairs({'north','south','east','west'})do
        for _,hinge in ipairs({'left','right'})do
          for _,opened in ipairs({true,false})do
            local r={content_id='pbzmc:spruce_door',properties={facing=facing,half='lower',hinge=hinge,open=opened}}
            local b=c:boxes(r);local n=0
            -- A 60 cm player can travel the full cell centreline through an
            -- open door. Its closed leaf intersects that same walking path.
            for step=-100,100,5 do for _,s in ipairs(b)do
              local x,y=0,0;if facing=='east'or facing=='west'then x=step else y=step end
              local h,o=s.half,s.center
              if geometry.capsule_overlaps(x-o[1],y-o[2],40-o[3],h[1],h[2],h[3],30,90)then n=n+1 end
            end end
            check(opened and n==0 or not opened and n>0,'door sweep '..facing..' '..hinge..' '..tostring(opened))
          end
        end
      end
      local function obj(n)local o={name=n};function o:IsValid()return true end;function o:GetAddress()return n end;function o:GetFullName()return n end;return o end
      local cap=obj('cap');cap.radius=42;cap.scale=1.5;cap.calls=0
      function cap:GetUnscaledCapsuleRadius()return self.radius end
      function cap:GetScaledCapsuleRadius()return self.radius*self.scale end
      function cap:SetCapsuleRadius(r)self.radius=r;self.calls=self.calls+1 end
      local move=obj('move');move.MaxStepHeight=45
      local b={actor={CapsuleComponent=cap,CharacterMovement=move},is_current=function()return true end}
      local C=require('host.pbz.player_collision');local lease=C.new(b)
      check(cap:GetScaledCapsuleRadius()==30 and move.MaxStepHeight==60,'scaled footprint and step')
      lease:close();lease:close();check(cap.radius==42 and move.MaxStepHeight==45 and cap.calls==2,'restore once')
      lease=C.new(b);cap.radius=25;move.MaxStepHeight=20;lease:close()
      check(cap.radius==25 and move.MaxStepHeight==20,'do not overwrite a new native owner')
      return checks
    ''',a.assets.as_posix())
    print(f'PASS {result} render, decal isolation, door and collision lease checks; native_game=false')

if __name__=='__main__':main()
