"""Retain vanilla hover sprites and the vanilla white fill texture, unchanged."""
from pathlib import Path
import io
import json
from PIL import Image
from extend_original_item_icons import OriginalPack, OUTPUT, digest

manifest_path = OUTPUT / 'manifest.json'
manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
outputs = {entry['path']: entry for entry in manifest['outputs']}
feedback = {}
for version, name, resource in (
    ('26.3', 'hover_back', 'textures/gui/sprites/container/slot_highlight_back.png'),
    ('26.3', 'hover_front', 'textures/gui/sprites/container/slot_highlight_front.png'),
    ('1.21.1', 'drag_fill', 'textures/misc/white.png'),
):
    pack = OriginalPack(version)
    paths = [resource] if name == 'drag_fill' else [resource, resource + '.mcmeta']
    for path in paths:
        source = 'assets/minecraft/' + path
        raw = pack.read(source, {})
        target = f'original/minecraft/{version}/' + path
        destination = OUTPUT / target
        if destination.exists():
            assert target in outputs and digest(destination.read_bytes()) == outputs[target]['sha256']
            assert destination.read_bytes() == raw
        else:
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(raw)
        record = dict(path=target, sha256=digest(raw), source=f'minecraft-original:{version}:{source}',
                      source_sha256=digest(raw), operation='byte-copy', minecraft_version=version, namespace='minecraft')
        if path.endswith('.png'):
            im = Image.open(io.BytesIO(raw)).convert('RGBA')
            record['size'] = list(im.size)
            if name == 'drag_fill':
                assert set(im.get_flattened_data()) == {(255, 255, 255, 255)}
            else:
                assert im.size == (24, 24)
            feedback[name] = target
        else:
            assert json.loads(raw)['gui']['scaling'] == dict(type='nine_slice', width=24, height=24, border=4)
        outputs[target] = record
    pack.archive.close()
manifest['feedback'] = dict(**feedback, hover_profile='java-26.3-slot-minus-4-24x24', drag_profile='java-1.21.1-white-0x80FFFFFF')
manifest['outputs'] = list(outputs.values())
manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding='utf-8')
print(json.dumps(dict(outputs=len(outputs), feedback=manifest['feedback']), ensure_ascii=False))
