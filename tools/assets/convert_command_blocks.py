"""Convert the pinned vanilla command-block resources into a private local pack.

The construction geometry/UV conventions and original display transforms are
reused, but the atlas and mesh store are independent of the construction pack.
Run after convert_construction with the same PBZMC_ASSET_WORK directory. Only
the source converter and hashes belong in the repository; its output is private.
"""
from __future__ import annotations

import argparse
from functools import lru_cache
from hashlib import sha256
from io import BytesIO
import json
from pathlib import Path
import zipfile

from PIL import Image, ImageChops

from asset_paths import ROOT
import convert_construction as construction
from convert_original_item_models import CONTEXTS, display_transform
from mc_generated_geometry import mesh_bytes


NAMES = ('command_block', 'repeating_command_block', 'chain_command_block')
FACINGS = ('down', 'east', 'north', 'south', 'up', 'west')
CLIENT_SHA256 = '4508d006323f24fa02876310c192d739af56516eb259000ac50f0909a68c9a2d'
LANGUAGE_SHA256 = '7c58c6e3502d5643e92ed754ce7b5bb3bdedfeba1a09534165433c7c36260f2c'
SIZE, CELL, COLS = 128, 32, 4
FRAME_TICKS, FRAME_COUNT, TICK_RATE = 10, 4, 20
compact, write, resource = construction.compact, construction.write, construction.path


def png(image):
    stream = BytesIO()
    image.save(stream, format='PNG')
    return stream.getvalue()


class CommandPack(construction.Pack):
    def __init__(self, archive):
        super().__init__(archive)
        self.sources = {}

    def read(self, name):
        raw = self.jar.read(name)
        self.sources[name] = dict(bytes=len(raw), sha256=sha256(raw).hexdigest())
        return raw

    @lru_cache(None)
    def js(self, name):
        return json.loads(self.read(name))

    @lru_cache(None)
    def strip(self, name):
        original = Image.open(BytesIO(self.read(resource('textures', name, '.png')))).convert('RGBA')
        if name.startswith('block/destroy_stage_'):
            assert original.size == (16, 16), (name, original.size)
        else:
            metadata = self.js(resource('textures', name, '.png.mcmeta'))
            assert original.size == (16, 64), (name, original.size)
            assert metadata == {'animation': {'interpolate': True, 'frametime': FRAME_TICKS}}, name
            assert original.getchannel('A').getextrema() == (255, 255), name
        return original

    @lru_cache(None)
    def image(self, name):
        return self.strip(name).crop((0, 0, 16, 16))

    def frame(self, name, tick):
        source = self.strip(name)
        if source.height == 16:
            return source
        frame, fraction = divmod(tick % (FRAME_TICKS * FRAME_COUNT), FRAME_TICKS)
        current = source.crop((0, frame * 16, 16, (frame + 1) * 16))
        if not fraction:
            return current
        following = (frame + 1) % FRAME_COUNT
        target = source.crop((0, following * 16, 16, (following + 1) * 16))
        # 26.3's animate_sprite_interpolate.fsh mixes RGBA8_UNORM frames at
        # subFrame/frame.time. PNG baking deterministically truncates bytes;
        # GPU render-target quantization can differ by one channel unit.
        return Image.blend(current, target, fraction / FRAME_TICKS)

    def tile(self, name):
        name = name.removeprefix('minecraft:')
        if name not in self.slots:
            assert len(self.slots) < COLS * COLS, 'command-block-atlas-capacity'
            self.image(name)
            self.slots[name] = len(self.slots)
        slot = self.slots[name]
        return ((slot % COLS) * CELL + 8, (slot // COLS) * CELL + 8)

    def atlas(self, tick=0, damage=None):
        atlas = Image.new('RGBA', (SIZE, SIZE))
        crack = self.image('block/destroy_stage_' + str(damage)) if damage is not None else None
        for name in self.slots:
            x, y = self.tile(name)
            tile = self.frame(name, tick)
            if crack is not None:
                multiplied = ImageChops.multiply(tile, crack)
                doubled = ImageChops.add(multiplied, multiplied)
                doubled.putalpha(tile.getchannel('A'))
                tile = Image.composite(doubled, tile, crack.getchannel('A').point(lambda a: 255 if a >= 26 else 0))
            atlas.paste(tile, (x, y))
            atlas.paste(tile.crop((0, 0, 1, 16)), (x - 1, y))
            atlas.paste(tile.crop((15, 0, 16, 16)), (x + 16, y))
            atlas.paste(tile.crop((0, 0, 16, 1)), (x, y - 1))
            atlas.paste(tile.crop((0, 15, 16, 16)), (x, y + 16))
        return atlas


def mesh(pack, quads, world):
    result = construction.mesh(pack, quads, world)
    # The inherited converter normalizes by its own 1024px atlas. The tile
    # coordinates above belong to this independent 128px atlas instead.
    ratio = construction.SIZE / SIZE
    result['uv'] = [(u * ratio, v * ratio) for u, v in result['uv']]
    return result


def convert(jar, language, output, ui):
    jar_digest = sha256(jar.read_bytes()).hexdigest()
    assert jar_digest == CLIENT_SHA256, 'command-block-client-digest'
    language_bytes = language.read_bytes()
    assert sha256(language_bytes).hexdigest() == LANGUAGE_SHA256, 'command-block-language-digest'
    zh = json.loads(language_bytes)
    blob, records, digest_index, blocks, icons = bytearray(), {}, {}, {}, {}

    def store(model):
        raw = mesh_bytes(model)
        digest = sha256(raw).hexdigest()
        if digest not in digest_index:
            index = len(records) + 1
            digest_index[digest] = index
            records[index] = [len(blob), len(raw), digest]
            blob.extend(raw)
        return digest_index[digest]

    with zipfile.ZipFile(jar) as archive:
        pack = CommandPack(archive)
        assert pack.js('version.json')['id'] == '26.3'
        for source in ('assets/minecraft/shaders/core/animate_sprite_interpolate.fsh',
                       'assets/minecraft/shaders/core/animate_sprite.vsh',
                       'net/minecraft/client/renderer/texture/SpriteContents$AnimatedTexture.class',
                       'net/minecraft/client/renderer/texture/SpriteContents$AnimationState.class'):
            pack.read(source)
        for name in NAMES:
            item = pack.js(resource('items', name))['model']
            assert item['type'] == 'minecraft:model'
            quads, sprite, display = construction.faces(pack, item['model'])
            assert sprite is None and len(quads) == 6
            item_id = store(mesh(pack, quads, False))
            icon = construction.icon(pack, quads, display)
            assert icon.getbbox() and icon.size == (64, 64)
            icon_path = 'command-blocks/' + name + '.png'
            icons[name] = dict(path=icon_path, **write(ui / icon_path, png(icon)))
            states, lookup, used = [], {}, {item_id}
            variants = pack.js(resource('blockstates', name))['variants']
            expected = {'conditional=' + conditional + ',facing=' + facing
                        for conditional in ('false', 'true') for facing in FACINGS}
            assert set(variants) == expected, name
            for key, variant in variants.items():
                state = dict(part.split('=') for part in key.split(','))
                quads, sprite, _ = construction.faces(pack, variant['model'], variant.get('x', 0),
                                                      variant.get('y', 0), variant.get('uvlock', False))
                assert sprite is None and len(quads) == 6
                index = store(mesh(pack, quads, True))
                used.add(index)
                # Physical state follows the full-cube command-block registry:
                # collision shape, outline shape, emission, solid, conductor.
                states.append([[[[index, 1]]], 0, 0, 0, True, True])
                lookup[state['conditional'] + ',' + state['facing']] = len(states)
            data = dict(keys=['conditional', 'facing'], defaults={'conditional': 'false', 'facing': 'north'},
                        lookup=lookup, states=states, item=item_id,
                        display={key: display.get(key, display_transform({})) for key in CONTEXTS},
                        meshes={str(index): records[index] for index in sorted(used)})
            record = write(output / 'blocks' / (name + '.json'), compact(data).encode('utf-8'))
            blocks[name] = dict(**record, label=zh['block.minecraft.' + name], icon=icon_path)

        assert len(pack.slots) == 12
        atlases = []
        for stage in range(-1, 10):
            name = 'atlas.png' if stage == -1 else 'crack_' + str(stage) + '.png'
            atlases.append(dict(path=name, **write(output / name, png(pack.atlas(damage=None if stage == -1 else stage)))))
        animation = [dict(tick=0, **atlases[0])]
        for tick in range(1, FRAME_TICKS * FRAME_COUNT):
            name = 'animation/tick_' + str(tick).zfill(2) + '.png'
            animation.append(dict(tick=tick, path=name, **write(output / name, png(pack.atlas(tick)))))
        geometry_record = write(output / 'geometry.bin', bytes(blob))
        manifest = dict(schema=1, vanilla='26.3', atlases=atlases, shapes=[[[0., 0., 0., 1., 1., 1.]]],
                        blocks=blocks, geometry=dict(path='geometry.bin', **geometry_record),
                        animations=dict(tick_rate=TICK_RATE, cycle_ticks=FRAME_TICKS * FRAME_COUNT,
                                        source_frames=FRAME_COUNT, source_frame_ticks=FRAME_TICKS,
                                        interpolate=True, palettes=animation, cracks='static_first_frame'))
        write(output / 'manifest.json', compact(manifest).encode('utf-8'))

        original_records = []
        for name in pack.slots:
            for suffix in ('.png', '.png.mcmeta'):
                source = resource('textures', name, suffix)
                relative = 'original/' + source.removeprefix('assets/minecraft/')
                original_records.append(dict(path=relative, source=source, **write(output / relative, pack.read(source))))
        provenance = dict(schema=1, vanilla='26.3', client=dict(file=jar.name, bytes=jar.stat().st_size,
                          sha256=jar_digest), language=dict(file='minecraft/lang/zh_cn.json',
                          bytes=len(language_bytes), sha256=sha256(language_bytes).hexdigest()),
                          source_files=pack.sources, original_sprites=original_records, icons=icons,
                          atlas=dict(size=[SIZE, SIZE], cell=CELL, sprite=[16, 16], gutter=1,
                                     tiles={name: list(pack.tile(name)) for name in pack.slots}),
                          state_properties=['conditional', 'facing'],
                          enabled_texture_variant=False,
                          interpolation=dict(operation='rgba8_unorm_linear_mix', quantization='truncate_uint8',
                                             gpu_quantization_max_channel_error=1),
                          notes=['Vanilla has separate impulse, repeating and chain texture families.',
                                 'Conditional replaces the four side sprites; front and back remain original.',
                                 'Powered and automatic execution flags do not select different vanilla textures.',
                                 'The 40 palettes retain the original four-frame cycle and 20Hz interpolation.',
                                 'The ten damage palettes use the original destroy-stage blend at frame zero.'])
        write(output / 'source_manifest.json', compact(provenance).encode('utf-8'))
    print(compact(dict(blocks=len(blocks), states=sum(len(json.loads((output / 'blocks' / (n + '.json')).read_bytes())['states'])
                                                      for n in NAMES), meshes=len(records), textures=12,
                       geometry_bytes=len(blob), animation_ticks=len(animation), output=str(output), ui=str(ui))))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--jar', type=Path, default=ROOT / 'inputs/26.3.jar')
    parser.add_argument('--language', type=Path, default=ROOT / 'assets/private/minecraft-original/26.3/indexed-assets/minecraft/lang/zh_cn.json')
    parser.add_argument('--output', type=Path, default=ROOT / 'assets/private/command-blocks')
    parser.add_argument('--ui', type=Path, default=ROOT / 'assets/private/minecraft-1.21.1/ui')
    args = parser.parse_args()
    convert(args.jar, args.language, args.output, args.ui)


if __name__ == '__main__':
    main()
