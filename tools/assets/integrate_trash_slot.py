"""Keep vanilla creative inventory's delete slot as an original texture region."""
from pathlib import Path
import hashlib
import json
import io
from PIL import Image

from asset_paths import ROOT
from extend_original_item_icons import OriginalPack
PACK_PATH = 'assets/minecraft/textures/gui/container/creative_inventory/tab_inventory.png'
pack = OriginalPack('1.21.1')
raw = pack.read(PACK_PATH,{})
pack.archive.close()
assert Image.open(io.BytesIO(raw)).size == (256, 256)
digest = hashlib.sha256(raw).hexdigest()
directory = ROOT / 'assets/private/minecraft-1.21.1/ui'
path = 'original/minecraft/1.21.1/textures/gui/container/creative_inventory/tab_inventory.png'
target = directory / path
target.parent.mkdir(parents=True, exist_ok=True)
target.write_bytes(raw)
manifest_path = directory / 'manifest.json'
manifest = json.loads(manifest_path.read_text('utf-8'))
entry = dict(path=path, sha256=digest, size=[256, 256],
             source='minecraft-original:1.21.1:' + PACK_PATH,
             source_sha256=digest, operation='byte-copy', minecraft_version='1.21.1', namespace='minecraft')
manifest['outputs'] = [row for row in manifest['outputs'] if row['path'] != path] + [entry]
manifest['trash_slot'] = dict(texture=path, region=dict(x=172, y=111, w=18, h=18, tw=256, th=256))
manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2), 'utf-8')
print(json.dumps(dict(texture=path, sha256=digest, operation='byte-copy')))
