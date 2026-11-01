"""Incremental original chorus fruit icon/model/name; preserves other items.

The complete existing MC unicode atlas already supplies the name's glyphs.
No full model/icon/font regeneration, game deployment or DLL change occurs.
"""
from pathlib import Path
import bisect
import io
import json
import struct
from PIL import Image
from extend_original_item_icons import OriginalPack, ROOT, digest
from convert_original_item_models import CONTEXTS, resolve_model
from mc_generated_geometry import mesh_bytes
from extend_original_item_labels import language

ID='pbzmc:chorus_fruit'
KEY='1.21.1/assets/minecraft/models/item/chorus_fruit.json'
MODEL='minecraft/1.21.1/item/chorus_fruit.mesh'
UI=ROOT/'assets/private/minecraft-1.21.1/ui'
ITEMS=ROOT/'assets/private/item-models'
OUT=ROOT/'assets/private/chorus'

def main():
    pack=OriginalPack('1.21.1');dependencies={}
    mesh,info=resolve_model(pack,'minecraft:item/chorus_fruit',dependencies)
    binary=mesh_bytes(mesh);target=ITEMS/MODEL;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(binary)
    mp=ITEMS/'manifest.json';models=json.loads(mp.read_text(encoding='utf8'))
    old_items={k:v for k,v in models['items'].items() if k!=ID}
    models['models'][KEY]=dict(path=MODEL,minecraft_version='1.21.1',model='minecraft:item/chorus_fruit',
        dependencies=['1.21.1/'+p for p in dependencies],vertices=len(mesh['positions']),indices=len(mesh['triangles']),**info)
    models['items'][ID]=dict(resource='minecraft:chorus_fruit',minecraft_version='1.21.1',
        contexts={context:dict(model=KEY,conditions=[]) for context in CONTEXTS},variants=[],item_dependencies=[])
    models['unavailable'].pop(ID,None)
    outputs={r['path']:r for r in models['outputs']};outputs[MODEL]=dict(path=MODEL,sha256=digest(binary),bytes=len(binary))
    models['outputs']=list(outputs.values());sources={r['version']+'/'+r['path']:r for r in models['sources']}
    for path,raw in dependencies.items():sources['1.21.1/'+path]=dict(version='1.21.1',path=path,sha256=digest(raw))
    models['sources']=list(sources.values());recipe=digest(Path(__file__).read_bytes())
    models.setdefault('recipe_sha256',{})[Path(__file__).name]=recipe
    assert old_items=={k:v for k,v in models['items'].items() if k!=ID}
    mp.write_text(json.dumps(models,ensure_ascii=False,indent=2)+'\n',encoding='utf8')

    up=UI/'manifest.json';ui=json.loads(up.read_text(encoding='utf8'));outputs={r['path']:r for r in ui['outputs']}
    old_icons={k:v for k,v in ui['item_icons'].items() if k!=ID};old_font=dict(ui['unicode_font'])
    retained=[]
    for source,raw in dependencies.items():
        relative='original/minecraft/1.21.1/'+source.removeprefix('assets/minecraft/')
        file=UI/relative
        if relative in outputs:
            assert file.read_bytes()==raw and digest(raw)==outputs[relative]['sha256']
        else:
            file.parent.mkdir(parents=True,exist_ok=True);file.write_bytes(raw)
            record=dict(path=relative,sha256=digest(raw),source='minecraft-original:1.21.1:'+source,
                source_sha256=digest(raw),operation='byte-copy',minecraft_version='1.21.1',namespace='minecraft')
            if relative.endswith('.png'):record['size']=list(Image.open(io.BytesIO(raw)).size)
            outputs[relative]=record
        retained.append(relative)
    icon='original/minecraft/1.21.1/'+info['texture'].removeprefix('assets/minecraft/')
    assert Image.open(UI/icon).size==(16,16)
    ui['item_icons'][ID]=icon
    ui.setdefault('item_icon_sources',{})[ID]=dict(minecraft_version='1.21.1',resource='minecraft:chorus_fruit',
        model_dependencies=retained,conditions=[])
    ui['missing_item_icons']=[v for v in ui['missing_item_icons'] if v!=ID]
    ui['incomplete_item_visuals'].pop(ID,None)
    translations,provenance=language('1.21.1');key='item.minecraft.chorus_fruit';label=translations[key]
    ui['labels'][ID]=label;ui.setdefault('label_sources',{})[ID]=dict(provenance,kind='minecraft-translation',key=key)
    if 'missing_item_labels' in ui:
        ui['missing_item_labels']=[v for v in ui['missing_item_labels'] if (v.get('id') if isinstance(v,dict) else v)!=ID]

    # Resolve required characters through the unchanged, source-verified index.
    header_path=ui['unicode_font']['index'];header_raw=(UI/header_path).read_bytes()
    assert digest(header_raw)==outputs[header_path]['sha256']
    header=json.loads(header_raw);raw=(UI/header['index']).read_bytes()
    assert digest(raw)==outputs[header['index']]['sha256'] and len(raw)==12*header['count']
    rows=list(struct.iter_unpack('<IHHHBB',raw));codes=[r[0] for r in rows];glyphs=[]
    for character in label:
        if character in ui['glyphs']:
            glyph=ui['glyphs'][character];path=glyph['path']
            glyphs.append(dict(character=character,codepoint=ord(character),path=path,sha256=outputs[path]['sha256'],kind='existing-explicit-glyph'))
        else:
            index=bisect.bisect_left(codes,ord(character));assert index<len(rows) and rows[index][0]==ord(character)
            _,page,x,y,w,h=rows[index];path=header['pages'][page-1]
            assert digest((UI/path).read_bytes())==outputs[path]['sha256']
            glyphs.append(dict(character=character,codepoint=ord(character),path=path,sha256=outputs[path]['sha256'],
                region=[x,y,w,h],kind='existing-original-unihex-atlas'))
    assert old_icons=={k:v for k,v in ui['item_icons'].items() if k!=ID} and ui['unicode_font']==old_font
    ui['outputs']=list(outputs.values());ui.setdefault('recipe_sha256',{})[Path(__file__).name]=recipe
    up.write_text(json.dumps(ui,ensure_ascii=False,indent=2)+'\n',encoding='utf8')

    # Vanilla uses the same portal clips as the already installed pearl event.
    cache=(ROOT / 'inputs/assets')
    index_raw=(cache/'indexes/1.21.1-17.json').read_bytes();index=json.loads(index_raw)['objects']
    row=index['minecraft/sounds.json'];sounds_raw=(cache/'objects'/row['hash'][:2]/row['hash']).read_bytes()
    import hashlib
    assert hashlib.sha1(sounds_raw).hexdigest()==row['hash']
    sounds=json.loads(sounds_raw)
    assert sounds['item.chorus_fruit.teleport']['sounds']==sounds['entity.player.teleport']['sounds']
    bank_path=ROOT/'assets/private/minecraft-1.21.1/sounds/manifest.json';bank=json.loads(bank_path.read_text(encoding='utf8'))
    sound_links={k:dict(event=bank['event_names'][k],clips=bank['events'][k]) for k in ('eat','burp','pearl_teleport')}
    OUT.mkdir(parents=True,exist_ok=True)
    receipt=dict(schema=1,content_id=ID,minecraft_version='1.21.1',origin_sha256=pack.manifest['archive_sha256'],
        model=dict(path=target.relative_to(ROOT).as_posix(),sha256=digest(binary),contexts=list(CONTEXTS),
            vertices=len(mesh['positions']),indices=len(mesh['triangles'])),
        icon=dict(path=(UI/icon).relative_to(ROOT).as_posix(),sha256=digest((UI/icon).read_bytes()),operation='byte-copy',size=[16,16]),
        label=dict(text=label,**ui['label_sources'][ID]),glyphs=glyphs,font_regenerated=False,
        sounds=dict(reuse=sound_links,manifest=bank_path.relative_to(ROOT).as_posix(),manifest_sha256=digest(bank_path.read_bytes()),
            sounds_json_sha256=digest(sounds_raw),asset_index_sha256=digest(index_raw),
            original_chorus_event='item.chorus_fruit.teleport',identical_installed_event='entity.player.teleport',new_audio=False),
        sources=[dict(path=p,sha256=digest(r)) for p,r in dependencies.items()],recipe_sha256=recipe,
        preserved_other_item_bindings=len(old_items),preserved_other_icons=len(old_icons),deployed=False,runtime_tested=False)
    (OUT/'manifest.json').write_text(json.dumps(receipt,ensure_ascii=False,indent=2)+'\n',encoding='utf8')
    pack.archive.close()
    print(json.dumps(dict(model=receipt['model'],icon=receipt['icon'],label=label,glyphs=glyphs,sounds=sound_links)))

if __name__=='__main__':main()
