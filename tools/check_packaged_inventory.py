"""Render the shipping catalogue against the same UI index and cache used in game."""
import argparse
import hashlib
from pathlib import Path
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('stage', type=Path)
parser.add_argument('resources', type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'build/lua-check'))
from lupa.lua54 import LuaRuntime

lua = LuaRuntime(unpack_returned_tuples=True)
scripts = args.stage / 'PBZMC/payload/platform/steam/ue4ss/Mods/PBZMCProbe/Scripts/pbzmc'
lua.globals().scripts = scripts.resolve().as_posix()
ui_root = (args.resources / 'ui').resolve()
lua.globals().ui_path = ui_root.as_posix()
icons, pages, entries = lua.execute("""
package.path=scripts..'/?.lua;'..scripts..'/vendor/?.lua;'..package.path
package.preload.UEHelpers=function() return {} end
local host=require('host.pbz.item_ui')
local ui=require('presentation.item_ui')
local json=require('dkjson')
local index=host.resource_index(ui_path)
assert(index==host.resource_index(ui_path))
local skin=assert(io.open(ui_path..'/bedrock_catalogue/manifest.json','rb'))
ui.catalogue_assets(index.assets,assert(json.decode(skin:read('*a'))),index.records)
skin:close()
local data=require('rules.container_slots').empty()
local pages,entries,icons=0,{},{}
for _,group in ipairs(require('rules.item_catalogue').categories()) do
  for page=1,group.pages do
    local draw,layout=ui.draw(data,index.assets,1920,1080,
      {inventory=true,catalogue_state={category=group.id,page=page}})
    pages=pages+1
    local displayed={}
    for _,cmd in ipairs(draw) do displayed[cmd.texture]=true end
    for _,id in ipairs(layout.catalogue.entries) do
      local path=assert(index.assets.item_icons[id],id)
      assert(displayed[path] and index.assets.labels[id],id)
      icons[path]=assert(index.records[path],path).sha256
      entries[id]=true
    end
  end
end
data.player.hotbar['1']={content_id='pbzmc:oak_wood',count=1,metadata={}}
local hotbar=ui.draw(data,index.assets,1920,1080,{})
local visible={}
for _,cmd in ipairs(hotbar) do visible[cmd.texture]=true end
assert(visible['construction/oak_wood.png'] and visible['original/textures/gui/sprites/hud/hotbar.png'])
local unique=0
for _ in pairs(entries) do unique=unique+1 end
return icons,pages,unique
""")
for name, expected in icons.items():
    file = (ui_root / name).resolve()
    assert file.is_relative_to(ui_root) and hashlib.sha256(file.read_bytes()).hexdigest() == expected, name
print(f'PASS: rendered {entries} catalogue entries across {pages} pages and the oak wood hotbar; verified {len(list(icons))} icon files.')
