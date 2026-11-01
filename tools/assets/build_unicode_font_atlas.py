"""Pack every retained MC unihex glyph into paged, original-pixel UI atlases.

No weapon-name input is accepted. Existing explicit MC glyphs retain priority;
the sorted 12-byte binary index provides a complete fallback for the source font.
"""
from __future__ import annotations
from collections import Counter
import hashlib
import io
import json
from pathlib import Path
import struct
import zipfile

import json5
from PIL import Image

from asset_paths import ROOT
UI = ROOT / 'assets/private/minecraft-1.21.1/ui'
PAGE = 2048
CELL_W, CELL_H = 32, 16
COLS, ROWS = PAGE // CELL_W, PAGE // CELL_H
PER_PAGE = COLS * ROWS
RECORD = struct.Struct('<IHHHBB')


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def main():
    manifest_path = UI / 'manifest.json'
    manifest_raw = manifest_path.read_bytes()
    manifest = json.loads(manifest_raw)
    old_records = {record['path']: record for record in manifest['outputs']}
    assert len(old_records) == len(manifest['outputs'])
    font_path = 'original/font/unifont.zip'
    config_path = 'original/font/include/unifont.json'
    font_raw, config_raw = (UI / font_path).read_bytes(), (UI / config_path).read_bytes()
    assert sha(font_raw) == old_records[font_path]['sha256'] == old_records[font_path]['source_sha256']
    assert sha(config_raw) == old_records[config_path]['sha256'] == old_records[config_path]['source_sha256']
    config = next(provider for provider in json5.loads(config_raw.decode('utf-8'))['providers']
                  if provider.get('hex_file') == 'minecraft:font/unifont.zip')
    explicit = set(json.loads((ROOT/'recipes/font-explicit.json').read_text('utf8')))
    source, members = {}, []
    invalid = 0
    with zipfile.ZipFile(io.BytesIO(font_raw)) as font:
        for member in font.namelist():
            if not member.endswith('.hex'):
                continue
            rows = font.read(member).decode('ascii').splitlines()
            members.append(dict(path=member, lines=len(rows)))
            for row in rows:
                code, bits = row.split(':', 1)
                point = int(code, 16)
                assert point not in source, f'Duplicate unihex codepoint: {code}'
                if point > 0x10FFFF or 0xD800 <= point <= 0xDFFF:
                    invalid += 1
                    continue
                packed = bytes.fromhex(bits)
                assert len(packed) // 2 in (8, 16, 24, 32) and len(packed) % 2 == 0
                source[point] = packed
    selected = sorted(set(source) - explicit)
    assert selected and len(selected) <= 0x110000
    outputs, pages, index = [], [], bytearray()
    widths, crops = Counter(), Counter()
    dependencies = [dict(path=font_path, sha256=sha(font_raw)), dict(path=config_path, sha256=sha(config_raw))]

    def save(path, raw, operation, **metadata):
        assert path == 'unicode_font.json' or path.startswith('fonts/unicode/')
        destination = UI / path
        if path in old_records and destination.exists():
            assert sha(destination.read_bytes()) == old_records[path]['sha256'], f'Modified previous font output: {path}'
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(raw)
        assert sha(destination.read_bytes()) == sha(raw)
        outputs.append(dict(path=path, sha256=sha(raw), bytes=len(raw), source='asset:minecraft/font/unifont.zip',
                            source_sha256=sha(font_raw), sources=dependencies, operation=operation, **metadata))

    for start in range(0, len(selected), PER_PAGE):
        page_number = len(pages) + 1
        atlas = Image.new('RGBA', (PAGE, PAGE), (255, 255, 255, 0))
        for cell, point in enumerate(selected[start:start + PER_PAGE]):
            packed = source[point]
            width = len(packed) // 2
            widths[width] += 1
            bitmap = Image.frombytes('1', (width, CELL_H), packed)
            bbox = bitmap.getbbox()
            left, right = (bbox[0], bbox[2] - 1) if bbox else (0, width - 1)
            for override in config.get('size_overrides', []):
                if ord(override['from']) <= point <= ord(override['to']):
                    left, right = override['left'], override['right']
                    break
            rgba = Image.new('RGBA', (width, CELL_H), (255, 255, 255, 0))
            rgba.putalpha(bitmap.convert('L'))
            glyph = rgba.crop((left, 0, right + 1, CELL_H))
            assert 0 < glyph.width <= CELL_W and glyph.height == CELL_H
            x, y = (cell % COLS) * CELL_W, (cell // COLS) * CELL_H
            atlas.paste(glyph, (x, y))
            index.extend(RECORD.pack(point, page_number, x, y, glyph.width, glyph.height))
            crops[glyph.width] += 1
        page_path = f'fonts/unicode/page_{page_number:03d}.png'
        encoded = io.BytesIO()
        atlas.save(encoded, format='PNG')
        save(page_path, encoded.getvalue(), 'pack-original-unihex-pixels', size=[PAGE, PAGE],
             cell=[CELL_W, CELL_H], glyphs=min(PER_PAGE, len(selected) - start))
        pages.append(page_path)
    assert len(index) == len(selected) * RECORD.size
    binary_path = 'fonts/unicode/glyphs.bin'
    save(binary_path, bytes(index), 'index-original-unihex-regions', record_format='<IHHHBB', record_bytes=RECORD.size)
    header = dict(schema=1, count=len(selected), record_bytes=RECORD.size, index=binary_path, pages=pages)
    save('unicode_font.json', json.dumps(header, ensure_ascii=False, separators=(',', ':')).encode('utf-8'),
         'describe-original-unihex-atlases')
    owned = {record['path'] for record in outputs}
    manifest['outputs'] = [record for record in manifest['outputs'] if record['path'] not in owned] + outputs
    manifest['unicode_font'] = dict(index='unicode_font.json', count=len(selected))
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding='utf-8')
    before = ROOT / 'conversion-reports/unicode-font-ui-before-20261101.json'
    if not before.exists():
        before.write_bytes(manifest_raw)
    report = dict(source_glyphs=len(source), explicit_glyphs_preserved=len(explicit), source_explicit_overlap=len(set(source) & explicit),
                  indexed_glyphs=len(selected), invalid_unicode_scalars_skipped=invalid, source_members=members,
                  source_pixel_widths=dict(widths), crop_widths=dict(crops), pages=len(pages), atlas_size=[PAGE, PAGE],
                  record_format='<IHHHBB', record_bytes=RECORD.size, index_bytes=len(index),
                  atlas_png_bytes=sum(record['bytes'] for record in outputs if record['path'].endswith('.png')),
                  bytes_per_loaded_rgba_page=PAGE * PAGE * 4,
                  bytes_if_all_pages_loaded=len(pages) * PAGE * PAGE * 4,
                  sources=dependencies, generated_outputs=outputs, weapon_name_dependency=False,
                  production_lua_changed=False, runtime_verified=False)
    (ROOT / 'conversion-reports/unicode-font-build-20261101.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps({key: report[key] for key in ('source_glyphs', 'indexed_glyphs', 'pages', 'index_bytes', 'atlas_png_bytes',
                                                 'bytes_per_loaded_rgba_page', 'bytes_if_all_pages_loaded', 'weapon_name_dependency')}))


if __name__ == '__main__':
    main()
