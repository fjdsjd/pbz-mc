"""Check the complete construction catalogue against the pinned vanilla registry."""
import argparse
import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'build/lua-check'))
from lupa.lua54 import LuaRuntime


def read(path):
    return json.loads(path.read_bytes())


def check_rules(ref, names):
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.globals().root = ROOT.as_posix()
    lua.execute("package.path=root..'/src/?.lua;'..root..'/third_party/dkjson/?.lua;'..package.path")
    verify = lua.eval("""function(pos,name,hardness,correct)
      local id='pbzmc:'..name
      local registry=require('content.blocks')
      local menu=require('rules.item_catalogue')
      local row=assert(registry.get(id))
      local page=menu.page('construction',math.ceil(pos/menu.page_size))
      assert(page.entries[(pos-1)%menu.page_size+1]==id and registry.construction[pos]==id,name)
      assert(row.available and row.infinite and row.hardness==hardness and not not row.requires_correct_tool==correct,name)
      local mining=require('rules.block_mining')
      for _,tool in ipairs({false,'wooden_pickaxe','netherite_pickaxe','golden_axe','iron_shovel'}) do
        local sample=assert(mining.sample(id,tool and 'pbzmc:'..tool))
        assert(sample.breakable and math.abs(sample.hardness-hardness)<1e-5 and sample.progress_per_tick>0,name)
      end
    end""")
    for i, row in enumerate(ref['blocks'], 1):
        assert row[0] == names[i - 1]
        verify(i, row[0], row[3], row[5])
    lua.execute("""local mine=require('rules.block_mining').sample
      local id='pbzmc:iron_block'
      assert(mine(id,false).divisor==100 and mine(id,'pbzmc:wooden_pickaxe').divisor==100)
      assert(mine(id,'pbzmc:stone_pickaxe').divisor==30 and mine(id,'pbzmc:netherite_pickaxe').speed==9)
      assert(mine('pbzmc:cherry_planks','pbzmc:golden_axe').speed==12)
      assert(mine('pbzmc:red_concrete_powder','pbzmc:iron_shovel').speed==6)
      local ops=require('host.pbz.construction_devices')
      assert(ops.scrape('pbzmc:waxed_oxidized_cut_copper_slab')=='pbzmc:oxidized_cut_copper_slab')
      assert(ops.scrape('pbzmc:oxidized_copper_grate')=='pbzmc:weathered_copper_grate')
      assert(ops.scrape('pbzmc:cherry_log')=='pbzmc:stripped_cherry_log')
    """)


def check_assets(ref, names, assets):
    directory = assets / 'construction'
    manifest = read(directory / 'manifest.json')
    ui = read(assets / 'ui/manifest.json')
    sounds = read(directory / 'sounds/manifest.json')
    geometry = (directory / 'geometry.bin').read_bytes()
    assert set(manifest['blocks']) == set(names)|{'dirt','tnt','spawner'} and manifest['shapes'] == ref['shapes']
    meshes, count = {}, 0
    for row in ref['blocks']:
        name, profile = row[0], row[2]
        packed = (directory / 'blocks' / (name + '.json')).read_bytes()
        assert hashlib.sha256(packed).hexdigest() == manifest['blocks'][name]['sha256']
        block = json.loads(packed)
        assert block['render_layer'] in ('cutout', 'translucent')
        default, states = ref['profiles'][profile]
        assert block['defaults'] == default and states.keys() == block['lookup'].keys(), name
        assert (assets / 'ui' / ui['item_icons']['pbzmc:' + name]).is_file()
        assert ui['labels']['pbzmc:' + name] and row[9] in sounds['groups']
        for key, shape in states.items():
            parts, *actual = block['states'][block['lookup'][key] - 1]
            assert actual == shape, (name, key)
            assert all(str(idx) in block['meshes'] and weight > 0 for choices in parts for idx, weight in choices)
        assert str(block['item']) in block['meshes']
        for idx, spec in block['meshes'].items():
            if idx not in meshes:
                offset, length, digest = spec
                assert len(geometry) >= offset + length and length > 0
                assert hashlib.sha256(geometry[offset:offset + length]).hexdigest() == digest
                meshes[idx] = spec
            assert meshes[idx] == spec
        count += len(states)
    print(f'PASS {count} visual/physical states, {len(meshes)} shared meshes, {len(ref["shapes"])} shapes')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--assets', type=Path, help='also verify a converted runtime asset directory')
    args = parser.parse_args()
    reference = read(ROOT / 'src/content/construction_reference.json')
    tabs = reference['tabs']
    catalogue = tabs['building_blocks'] + tabs['colored_blocks']
    assert (len(tabs['building_blocks']), len(tabs['colored_blocks']), len(set(catalogue))) == (475, 195, 670)
    check_rules(reference, catalogue)
    print('PASS 670 catalogue entries and 3,350 mining samples')
    if args.assets:
        check_assets(reference, catalogue, args.assets)
