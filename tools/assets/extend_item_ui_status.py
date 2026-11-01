"""Byte-copy original heart/armor sprites; hunger is outside current scope."""
import io
import json
from PIL import Image
from extend_original_item_icons import OriginalPack, OUTPUT, digest


def main():
    path=OUTPUT/'manifest.json'
    manifest=json.loads(path.read_text(encoding='utf-8'))
    outputs={entry['path']:entry for entry in manifest['outputs']}
    pack=OriginalPack('1.21.1')
    prefix='assets/minecraft/textures/gui/sprites/hud/'
    selected=sorted(source for source in pack.entries if source.startswith(prefix) and source.endswith('.png') and
                    (source.startswith(prefix+'heart/') or source[len(prefix):] in ('armor_empty.png','armor_half.png','armor_full.png')))
    assert len(selected)==50,'original heart/armor source set changed'
    bindings={}
    try:
        for source in selected:
            raw=pack.read(source,{})
            assert Image.open(io.BytesIO(raw)).size==(9,9)
            short=source[len(prefix):].removesuffix('.png')
            target='original/minecraft/1.21.1/'+source.removeprefix('assets/minecraft/')
            destination=OUTPUT/target
            if destination.exists():
                assert target in outputs and digest(destination.read_bytes())==outputs[target]['sha256']
                assert destination.read_bytes()==raw
            else:
                destination.parent.mkdir(parents=True,exist_ok=True)
                destination.write_bytes(raw)
            outputs[target]=dict(path=target,sha256=digest(raw),source='minecraft-original:1.21.1:'+source,
                source_sha256=digest(raw),operation='byte-copy',minecraft_version='1.21.1',namespace='minecraft',size=[9,9])
            bindings[short]=target
    finally:
        pack.archive.close()
    manifest['player_status']=bindings
    manifest['outputs']=list(outputs.values())
    path.write_text(json.dumps(manifest,ensure_ascii=False,indent=2),encoding='utf-8')
    print(json.dumps(dict(status_sprites=len(bindings),all_outputs=len(outputs),hunger_included=False)))


if __name__=='__main__':
    main()
