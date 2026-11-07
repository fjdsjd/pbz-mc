"""Build private mace impact sounds, gust/debris atlas and item glint from Minecraft."""
import hashlib
import io
import json
import struct
import zipfile

from PIL import Image

from asset_paths import ROOT
from convert_spear_sounds import convert
from mc_generated_geometry import generated_mesh

EVENTS = {'mace_air': 'item.mace.smash_air', 'mace_ground': 'item.mace.smash_ground',
          'mace_heavy': 'item.mace.smash_ground_heavy', 'mace_wind': 'entity.wind_charge.wind_burst'}


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def metadata(path, value):
    path.write_bytes((json.dumps(value, indent=2) + '\n').encode())


def render(jar, private):
    effects = private / 'effects'
    icons = private / 'minecraft-1.21.1/ui/animations'
    effects.mkdir(parents=True, exist_ok=True)
    icons.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(jar) as pack:
        def texture(name):
            raw = pack.read('assets/minecraft/textures/' + name + '.png')
            return Image.open(io.BytesIO(raw)).convert('RGBA'), digest(raw)

        gusts = json.loads(pack.read('assets/minecraft/particles/gust.json'))['textures']
        names = ['block/stone'] + ['particle/' + name.split(':')[1] for name in gusts]
        atlas = Image.new('RGBA', (32 * len(names), 32))
        sources = {}
        for i, name in enumerate(names):
            im, sources[name] = texture(name)
            atlas.paste(im.resize((32, 32), Image.Resampling.NEAREST), (32 * i, 0))
        atlas.save(effects / 'mace.png')
        metadata(effects / 'mace.json', dict(frames=len(names), source_version='1.21.1', sources=sources,
                                             atlas_sha256=digest((effects / 'mace.png').read_bytes())))
        mace, texture_hash = texture('item/mace')
        glint, glint_hash = texture('misc/enchanted_glint_item')
    assert mace.size == (16, 16)
    mesh, _ = generated_mesh(mace, '1.21.1')
    data = bytearray(b'PBZGLNT1' + struct.pack('<II', len(mesh['positions']), 12))
    atlas = Image.new('RGBA', (64, 48))
    for frame in range(12):
        def intensity(x, y):
            return glint.getpixel(((x*3+y+frame*7) % glint.width, (y*3-x+frame*3) % glint.height))[0]/255

        icon = mace.copy()
        for y in range(16):
            for x in range(16):
                rgb = mace.getpixel((x, y))
                if rgb[3]:
                    g = intensity(x, y)
                    icon.putpixel((x, y), tuple(min(255, round(c + g * d)) for c,d in zip(rgb, (85,45,150))) + (rgb[3],))
        atlas.paste(icon, (frame % 4 * 16, frame // 4 * 16))
        for uv, color in zip(mesh['uv'], mesh['colors']):
            g = intensity(int(uv[0] * 32), int(uv[1] * 32))
            rgb = [min(1, c + g*d) for c,d in zip(color, (.333,.176,.588))]
            data.extend(struct.pack('<ffff', *(c/12.92 if c <= .04045 else ((c+.055)/1.055)**2.4 for c in rgb), color[3]))
    atlas.save(icons / 'enchanted_mace.png')
    (effects / 'enchanted_mace_glint.bin').write_bytes(data)
    metadata(effects / 'enchanted_mace_glint.json', dict(sha256=digest(data), vertices=len(mesh['positions']),
             frames=12, texture_sha256=texture_hash, glint_sha256=glint_hash))


if __name__ == '__main__':
    private = ROOT / 'assets/private'
    render(ROOT / 'inputs/1.21.1.jar', private)
    convert(ROOT / 'inputs/assets', ROOT / 'inputs/ffmpeg', private / 'mace/sounds', EVENTS)
