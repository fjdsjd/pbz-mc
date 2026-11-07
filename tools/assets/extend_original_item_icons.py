"""Add verified vanilla GUI sprites from the retained versioned MC resources.

Run after extract_item_ui_assets.py. This copies original PNG/JSON bytes; it
does not synthesize block/entity icons, enchantment glint, trims or custom art.
"""
from pathlib import Path
import hashlib
import io
import json
import re
import zipfile
from PIL import Image

from asset_paths import ROOT
OUTPUT=ROOT/'assets/private/minecraft-1.21.1/ui'
PACK_HASHES={
    '1.21.1':'499f6897d1837516680f3114072d8106e11c9adcd933fe5cf051b551089b0c99',
    '26.3':'4508d006323f24fa02876310c192d739af56516eb259000ac50f0909a68c9a2d',
}

def digest(raw): return hashlib.sha256(raw).hexdigest()

def resource_path(kind,name,extension='.json'):
    namespace,identifier=name.split(':',1) if ':' in name else ('minecraft',name)
    assert namespace=='minecraft' and re.fullmatch(r'[a-z0-9_/]+',identifier),name
    return f'assets/{namespace}/{kind}/{identifier}{extension}'

class OriginalPack:
    def __init__(self,version):
        self.version=version
        self.root=ROOT/'assets/private/minecraft-original'/version
        self.manifest=json.loads((self.root/'IMPORT_MANIFEST.json').read_text(encoding='utf-8'))
        assert self.manifest['version']==version and self.manifest['archive_sha256']==PACK_HASHES[version]
        self.entries={entry['path']:entry for entry in self.manifest['files']}
        archive=Path(self.manifest['source_archive'])
        assert digest(archive.read_bytes())==PACK_HASHES[version],'original archive identity changed'
        self.archive=zipfile.ZipFile(archive)

    def read(self,path,dependencies):
        entry=self.entries[path]
        raw=self.archive.read(entry['archive_entry'])
        if digest(raw)!=entry['sha256']:
            raise ValueError('original resource identity changed: '+path)
        dependencies[path]=raw
        return raw

    def sprite(self,item):
        dependencies={};conditions=[]
        model_name='minecraft:item/'+item
        if self.version=='26.3':
            node=json.loads(self.read(resource_path('items','minecraft:'+item),dependencies))['model']
            if node['type']=='minecraft:select' and node['property']=='minecraft:display_context':
                matches=[entry['model'] for entry in node['cases']
                         if 'gui' in (entry['when'] if isinstance(entry['when'],list) else [entry['when']])]
                assert len(matches)==1,'no unambiguous original GUI model'
                node=matches[0]
            if node['type']=='minecraft:select' and node['property']=='minecraft:trim_material':
                node=node['fallback'];conditions.append('untrimmed')
            assert node['type']=='minecraft:model' and set(node)<= {'type','model'},'special or tinted item model'
            model_name=node['model']
        textures={};visited=set()
        while model_name not in ('builtin/generated','minecraft:builtin/generated'):
            assert model_name not in visited and len(visited)<8,'model parent cycle'
            visited.add(model_name)
            model=json.loads(self.read(resource_path('models',model_name),dependencies))
            assert not any(key in model for key in ('elements','overrides')),'non-flat or stateful model'
            assert 'gui' not in model.get('display',{}),'GUI transform requires a rendered icon'
            assert model.get('gui_light','front')=='front','model requires side lighting'
            for key,value in model.get('textures',{}).items(): textures.setdefault(key,value)
            model_name=model['parent']
        assert set(textures)=={'layer0'} and not textures['layer0'].startswith('#'),'layered icon requires composition'
        texture=resource_path('textures',textures['layer0'],'.png')
        raw=self.read(texture,dependencies)
        assert Image.open(io.BytesIO(raw)).size==(16,16),'unexpected sprite extent'
        return texture,dependencies,conditions

def aliases():
    # MinecraftInventory.Asset() at the pinned wukong-steve commit uses these
    # same base assets. Enchanted variants still need the original glint pass.
    result={'redstone_dust':'redstone','boat':'oak_boat'}
    # Command-only Java mobs have no vanilla egg. Use their closest original sprite.
    result.update({'giant_spawn_egg':'zombie_spawn_egg','illusioner_spawn_egg':'evoker_spawn_egg',
                   'killer_bunny_spawn_egg':'rabbit_spawn_egg'})
    for suffix in ('density','breach','wind_i','wind_ii','wind_iii','density_wind','breach_wind'):
        result['mace_'+suffix]='mace'
    for material in ('wooden','stone','copper','iron','golden','diamond','netherite'):
        result[material+'_spear_lunge_iii']=material+'_spear'
    for level in ('i','ii'): result['netherite_spear_lunge_'+level]='netherite_spear'
    return result

def main():
    manifest_path=OUTPUT/'manifest.json'
    manifest=json.loads(manifest_path.read_text(encoding='utf-8'))
    packs={version:OriginalPack(version) for version in PACK_HASHES}
    outputs={entry['path']:entry for entry in manifest['outputs']}
    by_source={('1.21.1',entry['source'][7:]):entry['path'] for entry in outputs.values()
               if entry['source'].startswith('client:')}
    for entry in outputs.values():
        if entry['source'].startswith('minecraft-original:'):
            _,version,path=entry['source'].split(':',2);by_source[version,path]=entry['path']

    def retain(pack,path,raw):
        key=(pack.version,path)
        if key in by_source:
            target=by_source[key]
            assert (OUTPUT/target).read_bytes()==raw,'existing original copy changed'
            return target
        target=f'original/minecraft/{pack.version}/'+path.removeprefix('assets/minecraft/')
        destination=OUTPUT/target;destination.parent.mkdir(parents=True,exist_ok=True)
        destination.write_bytes(raw)
        entry=dict(path=target,sha256=digest(raw),source=f'minecraft-original:{pack.version}:{path}',
                   source_sha256=digest(raw),operation='byte-copy',minecraft_version=pack.version,namespace='minecraft')
        if target.endswith('.png'): entry['size']=list(Image.open(io.BytesIO(raw)).size)
        outputs[target]=entry;by_source[key]=target
        return target

    bindings=manifest.setdefault('item_icon_sources',{})
    pending=manifest.setdefault('incomplete_item_visuals',{})
    source_aliases=aliases()
    visual_versions={entry['id']:entry['visual_version'] for entry in
        json.loads((ROOT/'src/content/extension_items.json').read_text(encoding='utf-8'))['items']
        if entry.get('visual_version')}
    ids=re.findall(r"\['pbzmc:([^']+)'\]",(ROOT/'src/content/items.lua').read_text(encoding='utf-8'))
    for item in ids:
        content_id='pbzmc:'+item
        if content_id in manifest['item_icons']: continue
        original=source_aliases.get(item,item)
        reasons=[]
        versions=[visual_versions[content_id]] if content_id in visual_versions else list(packs)
        for version in versions:
            pack=packs[version]
            try: texture,dependencies,conditions=pack.sprite(original)
            except (KeyError,AssertionError) as error:
                reasons.append(pack.version+': '+str(error));continue
            paths=[retain(pack,path,raw) for path,raw in dependencies.items()]
            manifest['item_icons'][content_id]=by_source[pack.version,texture]
            bindings[content_id]=dict(minecraft_version=pack.version,resource='minecraft:'+original,
                                     model_dependencies=paths,conditions=conditions)
            pending.pop(content_id,None)
            if item.startswith('mace_') or '_spear_lunge_' in item:
                pending[content_id]=['original enchantment glint is not implemented']
            if conditions: pending.setdefault(content_id,[]).append('trim variants are not implemented')
            break
        else: pending[content_id]=reasons
    manifest['resource_sets']={version:dict(client_sha256=PACK_HASHES[version],namespace='minecraft',
        import_manifest=f'assets/private/minecraft-original/{version}/IMPORT_MANIFEST.json') for version in packs}
    manifest['outputs']=list(outputs.values())
    manifest['missing_item_icons']=['pbzmc:'+item for item in ids if 'pbzmc:'+item not in manifest['item_icons']]
    manifest_path.write_text(json.dumps(manifest,ensure_ascii=False,indent=2),encoding='utf-8')
    for pack in packs.values(): pack.archive.close()
    print(json.dumps(dict(outputs=len(outputs),base_icons=len(manifest['item_icons']),
                         missing_icons=len(manifest['missing_item_icons']),new_bindings=len(bindings),
                         incomplete_visuals=len(pending)),ensure_ascii=False))

if __name__=='__main__': main()
