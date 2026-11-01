"""Copy the local vanilla MC crosshair byte-for-byte, retaining its provenance."""
import json, io
from PIL import Image
from extend_original_item_icons import OriginalPack, OUTPUT, digest
pack=OriginalPack('1.21.1')
source='assets/minecraft/textures/gui/sprites/hud/crosshair.png'
raw=pack.read(source,{})
pack.archive.close()
size=list(Image.open(io.BytesIO(raw)).size)
assert size==[15,15]
manifest_path=OUTPUT/'manifest.json'
manifest=json.loads(manifest_path.read_text(encoding='utf-8'))
target='original/minecraft/1.21.1/textures/gui/sprites/hud/crosshair.png'
outputs={entry['path']:entry for entry in manifest['outputs']}
destination=OUTPUT/target
if destination.exists():
    assert target in outputs and digest(destination.read_bytes())==outputs[target]['sha256']
destination.parent.mkdir(parents=True,exist_ok=True)
destination.write_bytes(raw)
outputs[target]=dict(path=target,sha256=digest(raw),source='minecraft-original:1.21.1:'+source,
    source_sha256=digest(raw),operation='byte-copy',minecraft_version='1.21.1',namespace='minecraft',size=size)
manifest['outputs']=list(outputs.values());manifest['crosshair']=target
manifest_path.write_text(json.dumps(manifest,ensure_ascii=False,indent=2),encoding='utf-8')
print('Original MC crosshair copied; SHA256='+digest(raw))
