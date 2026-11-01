"""Copy original local MC 1.21.1 UI assets; do not redraw interface artwork.

Private outputs are excluded from releases. Derived PNGs are exact source crops
or direct decoding of Minecraft's supplied unihex glyph bits, never substitute
fonts or generated artwork. Every output retains source and conversion identity.
"""
from __future__ import annotations
import argparse
import hashlib
import io
import json
from pathlib import Path
import re
import zipfile
from PIL import Image
import json5

from asset_paths import ROOT
EXPECTED_CLIENT = '499f6897d1837516680f3114072d8106e11c9adcd933fe5cf051b551089b0c99'
LABELS = '物品栏合成配方书末影箱上一页下一页全部可合成搜索关闭快捷栏副手背包创造自由冒险当前武器等待切换原版选择装备头盔胸甲护腿靴子主槽煞空未就绪：'

def sha256(raw):
    return hashlib.sha256(raw).hexdigest()

def glyph_values(path):
    """Read display values only; IDs, localization keys and other fields are not names."""
    raw = path.read_bytes()
    assert len(raw) <= 1024 * 1024, 'Glyph request JSON exceeds 1 MiB'
    value = json.loads(raw.decode('utf-8-sig'))
    assert isinstance(value, dict) and isinstance(value.get('rows'), list), 'Glyph request needs rows[]'
    assert len(value['rows']) <= 4096, 'Glyph request has too many rows'
    labels = []
    for row in value['rows']:
        assert isinstance(row, dict), 'Glyph request row must be an object'
        label = row.get('value')
        if label is None:
            continue
        assert isinstance(label, str) and len(label) <= 4096, 'Glyph request value must be bounded text'
        labels.append(label)
    text = ''.join(labels)
    return text, dict(path=str(path.resolve()), sha256=sha256(raw), value_rows=len(labels),
                      codepoints=[f'U+{code:04X}' for code in sorted(set(map(ord, text)))])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--client', required=True, type=Path)
    parser.add_argument('--assets', required=True, type=Path)
    parser.add_argument('--output', type=Path, default=ROOT / 'assets/private/minecraft-1.21.1/ui')
    parser.add_argument('--glyphs-only', action='store_true',
                        help='Add missing original glyphs while preserving the extended UI manifest and assets')
    parser.add_argument('--glyphs-from-json', type=Path,
                        help='Include only rows[].value text from a native-name readback JSON')
    args = parser.parse_args()
    output = args.output.resolve()
    if args.client.resolve().parent in output.parents or args.assets.resolve() in output.parents:
        raise ValueError('Output must be outside the source Minecraft installation')
    raw_client = args.client.read_bytes()
    assert sha256(raw_client) == EXPECTED_CLIENT, 'Unreviewed client identity'
    version = json.loads(args.client.with_suffix('.json').read_text(encoding='utf-8'))
    index_path = args.assets / 'indexes' / (version['assetIndex']['id'] + '.json')
    index_raw = index_path.read_bytes()
    index = json.loads(index_raw)['objects']
    output.mkdir(parents=True, exist_ok=True)
    manifest = dict(schema=1, minecraft_version='1.21.1', layout_profile='java-inventory-176x166-v1', private_local_assets=True,
                    client_sha256=sha256(raw_client), asset_index_sha256=sha256(index_raw),
                    outputs=[], glyphs={}, labels={}, item_icons={}, missing_item_icons=[])
    if args.glyphs_only:
        manifest = json.loads((output / 'manifest.json').read_text(encoding='utf-8'))
        assert manifest['client_sha256'] == sha256(raw_client), 'UI manifest uses a different MC client'
        assert manifest['asset_index_sha256'] == sha256(index_raw), 'UI manifest uses a different asset index'
    dynamic_text = ''
    if args.glyphs_from_json:
        dynamic_text, request = glyph_values(args.glyphs_from_json)
        requests = manifest.setdefault('glyph_request_sources', [])
        if request not in requests:
            requests.append(request)

    def external(name):
        item = index[name]
        raw = (args.assets / 'objects' / item['hash'][:2] / item['hash']).read_bytes()
        assert len(raw) == item['size'] and hashlib.sha1(raw).hexdigest() == item['hash']
        return raw

    def save(name, raw, source, source_raw, operation, **metadata):
        path = output / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(raw)
        assert path.read_bytes() == raw
        record = dict(path=name, sha256=sha256(raw), source=source,
                      source_sha256=sha256(source_raw), operation=operation, **metadata)
        if name.endswith('.png'):
            image = Image.open(io.BytesIO(raw))
            record['size'] = list(image.size)
        manifest['outputs'].append(record)
        return name

    def image_bytes(image):
        buffer = io.BytesIO(); image.save(buffer, format='PNG'); return buffer.getvalue()

    with zipfile.ZipFile(io.BytesIO(raw_client)) as jar:
        assert json.loads(jar.read('version.json'))['id'] == '1.21.1'
        names = set(jar.namelist())
        exact = [
            'textures/gui/container/inventory.png', 'textures/gui/container/generic_54.png',
            'textures/gui/recipe_book.png', 'textures/gui/sprites/hud/hotbar.png',
            'textures/gui/sprites/hud/hotbar_selection.png',
            'textures/gui/sprites/hud/hotbar_offhand_left.png',
            'textures/gui/sprites/hud/hotbar_offhand_right.png',
            'font/default.json', 'font/include/default.json', 'font/include/space.json',
            'textures/font/ascii.png', 'textures/font/nonlatin_european.png',
            'textures/font/accented.png',
        ]
        exact += sorted(name.removeprefix('assets/minecraft/') for name in names
                        if name.startswith('assets/minecraft/textures/gui/sprites/recipe_book/'))
        exact += sorted(name.removeprefix('assets/minecraft/') for name in names
                        if name.startswith('assets/minecraft/textures/item/empty_'))
        for resource in ([] if args.glyphs_only else exact):
            source = 'assets/minecraft/' + resource
            raw = jar.read(source)
            save('original/' + resource, raw, 'client:' + source, raw, 'byte-copy')

        # InventoryScreen uses this exact top-left region of the vanilla sheet.
        source = 'assets/minecraft/textures/gui/container/inventory.png'
        raw = jar.read(source); original = Image.open(io.BytesIO(raw)).convert('RGBA')
        crop = original.crop((0, 0, 176, 166))
        encoded = image_bytes(crop)
        assert Image.open(io.BytesIO(encoded)).convert('RGBA').tobytes() == crop.tobytes()
        if not args.glyphs_only:
            save('inventory_panel.png', encoded, 'client:' + source, raw,
                 'lossless-crop', crop=[0, 0, 176, 166])

        # Item textures remain the actual MC images. Models needing a rendered
        # block/entity icon are reported, never replaced by invented 2D symbols.
        ids = re.findall(r"\['pbzmc:([^']+)'\]", (ROOT / 'src/content/items.lua').read_text(encoding='utf-8'))
        translations_raw = external('minecraft/lang/zh_cn.json')
        translations = json.loads(translations_raw)
        if not args.glyphs_only:
            save('original/lang/zh_cn.json', translations_raw, 'asset:minecraft/lang/zh_cn.json',
                 translations_raw, 'byte-copy')
        text = LABELS + dynamic_text + ''.join(chr(code) for code in range(32, 127))
        for item in ids:
            key = next((prefix + item for prefix in ('item.minecraft.', 'block.minecraft.')
                        if prefix + item in translations), None)
            if key and not args.glyphs_only:
                manifest['labels']['pbzmc:' + item] = translations[key]
            if key:
                text += translations[key]
            if args.glyphs_only:
                continue
            source = 'assets/minecraft/textures/item/' + item + '.png'
            if source not in names:
                manifest['missing_item_icons'].append('pbzmc:' + item)
                continue
            raw = jar.read(source)
            path = save('items/' + item + '.png', raw, 'client:' + source, raw, 'byte-copy')
            manifest['item_icons']['pbzmc:' + item] = path
        selected = set(text)
        # Preserve the bitmap providers' order and original per-glyph pixels.
        providers = json.loads(jar.read('assets/minecraft/font/include/default.json'))['providers']
        for provider in providers:
            if provider['type'] != 'bitmap':
                continue
            source = 'assets/minecraft/textures/' + provider['file'].split(':', 1)[1]
            raw = jar.read(source)
            image = Image.open(io.BytesIO(raw)).convert('RGBA')
            rows = provider['chars']; cols = len(rows[0])
            cell_w, cell_h = image.width // cols, image.height // len(rows)
            height = provider.get('height', 8)
            for y, row in enumerate(rows):
                for x, char in enumerate(row):
                    if char not in selected or char in manifest['glyphs'] or char in ('\x00', ' '):
                        continue
                    box = (x * cell_w, y * cell_h, (x + 1) * cell_w, (y + 1) * cell_h)
                    glyph = image.crop(box)
                    bbox = glyph.getchannel('A').getbbox()
                    advance = int((bbox[2] if bbox else 0) * height / cell_h + 0.5) + 1
                    path = save(f'glyphs/{ord(char):06x}.png', image_bytes(glyph),
                                'client:' + source, raw, 'lossless-crop', crop=list(box))
                    manifest['glyphs'][char] = dict(path=path, width=cell_w * height / cell_h,
                                                   height=height, advance=advance,
                                                   ascent=provider['ascent'])

        uni_source = 'minecraft/font/unifont.zip'
        uni_raw = external(uni_source)
        if not args.glyphs_only:
            save('original/font/unifont.zip', uni_raw, 'asset:' + uni_source, uni_raw, 'byte-copy')
        config_raw = external('minecraft/font/include/unifont.json')
        if not args.glyphs_only:
            save('original/font/include/unifont.json', config_raw,
                 'asset:minecraft/font/include/unifont.json', config_raw, 'byte-copy')
        # The installed MC asset contains a trailing comma in a __ranges array;
        # keep its bytes intact and use the already installed lenient parser.
        config = next(p for p in json5.loads(config_raw.decode('utf-8'))['providers']
                      if p.get('hex_file') == 'minecraft:font/unifont.zip')
        needed = {ord(char): char for char in selected if char not in manifest['glyphs'] and char != ' '}
        with zipfile.ZipFile(io.BytesIO(uni_raw)) as font:
            for member in font.namelist():
                if not member.endswith('.hex'):
                    continue
                for line in font.read(member).decode('ascii').splitlines():
                    code, bits = line.split(':', 1); point = int(code, 16)
                    if point not in needed:
                        continue
                    char = needed.pop(point)
                    packed = bytes.fromhex(bits); width = len(packed) // 2
                    assert width in (8, 16, 24, 32)
                    bitmap = Image.frombytes('1', (width, 16), packed)
                    bbox = bitmap.getbbox()
                    left, right = (bbox[0], bbox[2] - 1) if bbox else (0, width - 1)
                    for override in config.get('size_overrides', []):
                        if ord(override['from']) <= point <= ord(override['to']):
                            left, right = override['left'], override['right']; break
                    rgba = Image.new('RGBA', (width, 16), (255, 255, 255, 0))
                    rgba.putalpha(bitmap.convert('L'))
                    glyph = rgba.crop((left, 0, right + 1, 16))
                    path = save(f'glyphs/{point:06x}.png', image_bytes(glyph),
                                'asset:' + uni_source + '#' + member + ':' + code,
                                uni_raw, 'decode-original-unihex-bits', crop=[left, 0, right + 1, 16])
                    manifest['glyphs'][char] = dict(path=path, width=glyph.width / 2,
                                                   height=8, advance=glyph.width / 2 + 1, ascent=7)
        assert not needed, ('Required MC font glyph missing', needed)
        manifest['glyphs'][' '] = dict(width=0, height=0, advance=4, ascent=7)
    (output / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps(dict(outputs=len(manifest['outputs']), glyphs=len(manifest['glyphs']),
                         original_item_icons=len(manifest['item_icons']),
                         model_or_custom_icons_pending=len(manifest['missing_item_icons']),
                         client_sha256=manifest['client_sha256']), ensure_ascii=False))

if __name__ == '__main__':
    main()
