"""Local MC generated models -> STEVEM01, with separate display/state metadata.

Special/entity/block/layered models remain explicit gaps. Particle textures and
GUI-only models are never substituted for held geometry. Original files stay
private and are verified against both their import manifest and client archive.
"""
from __future__ import annotations
import io
import json
import math
import re
from pathlib import Path
from PIL import Image
from extend_original_item_icons import OriginalPack, PACK_HASHES, ROOT, aliases, digest, resource_path
from mc_generated_geometry import generated_mesh, mesh_bytes

OUTPUT = ROOT/'assets/private/item-models'
CONTEXTS = ('thirdperson_righthand','thirdperson_lefthand','firstperson_righthand',
            'firstperson_lefthand','head','gui','ground','fixed')


class Unsupported(ValueError):
    pass


def display_transform(value):
    result = {}
    for key, default in (('rotation',[0,0,0]),('translation',[0,0,0]),('scale',[1,1,1])):
        values = value.get(key, default)
        if not isinstance(values,list) or len(values) != 3 or any(type(v) not in (int,float) or not math.isfinite(v) for v in values):
            raise ValueError('invalid display vector')
        if key == 'translation':
            values = [max(-5,min(5,v/16))*16 for v in values]
        elif key == 'scale':
            values = [max(-4,min(4,v)) for v in values]
        result[key] = values
    return result


def resolve_model(pack, name, dependencies):
    textures, display, visited, chain = {}, {}, set(), []
    overrides, gui_light = None, None
    while name not in ('builtin/generated','minecraft:builtin/generated'):
        path = resource_path('models',name)
        if path in visited or len(visited) >= 16:
            raise ValueError('model parent cycle/depth')
        visited.add(path)
        value = json.loads(pack.read(path,dependencies))
        chain.append(path)
        if overrides is None:
            # Unlike display/textures, old item overrides belong only to the
            # requested model. Bow pulling children must not inherit the base
            # bow's override list and redirect themselves a second time.
            overrides = value.get('overrides',[])
        if 'elements' in value:
            raise Unsupported('elements geometry requires the block/entity model converter')
        if gui_light is None:
            gui_light = value.get('gui_light')
        for key, texture in value.get('textures',{}).items():
            textures.setdefault(key,texture)
        local_display = dict(value.get('display',{}))
        # Fallback occurs at EACH parent level, before whole-context inheritance.
        # Explicit {} is identity, not the missing sentinel: it blocks ancestors.
        for prefix in ('thirdperson','firstperson'):
            right, left = prefix+'_righthand', prefix+'_lefthand'
            if left not in local_display and right in local_display:
                local_display[left] = local_display[right]
        for key, transform in local_display.items():
            if key in CONTEXTS and key not in display:
                display[key] = display_transform(transform)
        name = value.get('parent')
        if not name:
            raise Unsupported('no generated parent')
        if name in ('builtin/entity','minecraft:builtin/entity'):
            raise Unsupported('special entity geometry required')
    for context in CONTEXTS:
        display.setdefault(context,display_transform({}))
    if any(key.startswith('layer') and key != 'layer0' for key in textures):
        raise Unsupported('multiple texture layers require composition/tints')
    texture, followed = textures.get('layer0'), set()
    while isinstance(texture,str) and texture.startswith('#'):
        if texture in followed:
            raise ValueError('texture alias cycle')
        followed.add(texture)
        texture = textures.get(texture[1:])
    if not texture:
        raise Unsupported('missing layer0')
    texture_path = resource_path('textures',texture,'.png')
    raw = pack.read(texture_path,dependencies)
    if texture_path+'.mcmeta' in pack.entries or texture_path+'.mcmeta' in pack.archive.namelist():
        raise Unsupported('texture metadata/animation requires a separate renderer')
    image = Image.open(io.BytesIO(raw)).convert('RGBA')
    if image.width != image.height:
        raise Unsupported('non-square texture requires explicit sprite metadata')
    try:
        mesh, stats = generated_mesh(image,pack.version)
    except ValueError as error:
        raise Unsupported(str(error)) from error
    return mesh, dict(display=display,gui_light=gui_light or 'front',texture=texture_path,
                      texture_size=list(image.size),parent_chain=chain,
                      overrides=overrides or [],geometry=stats)


def context_model(node, context):
    kind = node['type']
    if kind == 'minecraft:model':
        if set(node)-{'type','model'}:
            raise Unsupported('tinted/extended model definition requires a renderer')
        return node['model'], []
    if kind == 'minecraft:select' and node['property'] == 'minecraft:display_context':
        for case in node['cases']:
            choices = case['when'] if isinstance(case['when'],list) else [case['when']]
            if context in choices:
                return context_model(case['model'],context)
        return context_model(node['fallback'],context)
    if kind == 'minecraft:select' and node['property'] == 'minecraft:trim_material':
        model, conditions = context_model(node['fallback'],context)
        return model, conditions+['untrimmed only']
    raise Unsupported('item definition requires '+kind)


def main():
    ui = json.loads((ROOT/'assets/private/minecraft-1.21.1/ui/manifest.json').read_text(encoding='utf-8'))
    ids = re.findall(r"\['(pbzmc:[^']+)'\]",(ROOT/'src/content/items.lua').read_text(encoding='utf-8'))
    extensions = json.loads((ROOT/'src/content/extension_items.json').read_text(encoding='utf-8'))['items']
    versions = {entry['id']:entry['visual_version'] for entry in extensions if 'visual_version' in entry}
    packs = {version:OriginalPack(version) for version in PACK_HASHES}
    source_aliases = aliases()
    outputs, models, bindings, unavailable, dependencies, failures = {}, {}, {}, {}, {}, {}
    OUTPUT.mkdir(parents=True,exist_ok=True)

    def retain(pack, retained):
        for path, raw in retained.items():
            dependencies[pack.version+'/'+path] = dict(version=pack.version,path=path,sha256=digest(raw))

    def convert(pack, name):
        key = pack.version+'/'+resource_path('models',name)
        if key in models:
            return key
        if key in failures:
            raise Unsupported(failures[key])
        retained = {}
        try:
            mesh, info = resolve_model(pack,name,retained)
        except (KeyError,Unsupported) as error:
            failures[key] = str(error)
            raise Unsupported(str(error)) from error
        finally:
            retain(pack,retained)
        path = 'minecraft/'+pack.version+'/'+resource_path('models',name).removeprefix('assets/minecraft/models/').removesuffix('.json')+'.mesh'
        raw = mesh_bytes(mesh)
        target = OUTPUT/path
        target.parent.mkdir(parents=True,exist_ok=True)
        target.write_bytes(raw)
        outputs[path] = dict(path=path,sha256=digest(raw),bytes=len(raw))
        models[key] = dict(path=path,minecraft_version=pack.version,model=name,
                          dependencies=[pack.version+'/'+p for p in retained],
                          vertices=len(mesh['positions']),indices=len(mesh['triangles']),**info)
        return key

    try:
        for content_id in ids:
            item = content_id.split(':',1)[1]
            if item.startswith(('potion_','splash_potion_','lingering_potion_')):
                continue  # prepare_potions composes the original two tinted layers.
            original = source_aliases.get(item,item)
            version = versions.get(content_id,ui.get('item_icon_sources',{}).get(content_id,{}).get('minecraft_version','1.21.1'))
            pack = packs[version]
            nodes, item_dependencies, contexts, issues = {}, {}, {}, {}
            definition = None
            if version == '26.3':
                definition = json.loads(pack.read(resource_path('items','minecraft:'+original),item_dependencies))
                for context in CONTEXTS:
                    try:
                        nodes[context] = context_model(definition['model'],context)
                    except Unsupported as error:
                        issues[context] = str(error)
            else:
                nodes = {context:('minecraft:item/'+original,[]) for context in CONTEXTS}
            for context, (name,conditions) in nodes.items():
                try:
                    key = convert(pack,name)
                    contexts[context] = dict(model=key,conditions=conditions)
                    if conditions:
                        issues[context] = '; '.join(conditions)
                except Unsupported as error:
                    issues[context] = str(error)
            variants = []
            for key in sorted({entry['model'] for entry in contexts.values()}):
                for override in models[key]['overrides']:
                    entry = dict(base_model=key,predicate=override['predicate'],model_resource=override['model'])
                    try:
                        entry['model'] = convert(pack,override['model'])
                    except Unsupported as error:
                        entry['unavailable'] = str(error)
                        issues['variants'] = 'some original override models need additional conversion'
                    variants.append(entry)
            retain(pack,item_dependencies)
            bindings[content_id] = dict(resource='minecraft:'+original,minecraft_version=version,
                                       contexts=contexts,variants=variants,
                                       item_dependencies=[version+'/'+path for path in item_dependencies])
            if definition is not None:
                # Preserve original state tree and root settings, including
                # spear swap_animation_scale, for the action/render consumer.
                # Retained source metadata does not enable gameplay features.
                bindings[content_id]['original_item_definition'] = definition
            if item.startswith('mace_') or '_spear_lunge_' in item:
                issues['enchantment_glint'] = 'base geometry only; original glint pass still required'
            if issues:
                unavailable[content_id] = issues
        manifest = dict(schema=1,private_local_assets=True,format='STEVEM01',
            coordinate_contract='MC centered at (8,8,8) -> recipe(x,-y,-z) -> UE(z,-x,y); 6.25 cm/model unit',
            display_contract='No display/holder transforms baked; translation in MC model units; left-hand signs applied by consumer',
            material_contract='hard alpha per-texel sRGB colors; opaque PBZ material; not MC atlas filtering/lighting/animation parity',
            recipe_sha256={p.name:digest(p.read_bytes()) for p in (Path(__file__),Path(__file__).with_name('mc_generated_geometry.py'))},
            archives=PACK_HASHES,models=models,items=bindings,unavailable=unavailable,
            sources=list(dependencies.values()),outputs=list(outputs.values()))
        (OUTPUT/'manifest.json').write_text(json.dumps(manifest,indent=2,ensure_ascii=False)+'\n',encoding='utf-8')
        print(json.dumps(dict(meshes=len(models),items=len(bindings),items_with_all_contexts=sum(len(v['contexts'])==len(CONTEXTS) for v in bindings.values()),
                             incomplete_items=len(unavailable),source_files=len(dependencies))))
    finally:
        for pack in packs.values():
            pack.archive.close()


if __name__ == '__main__':
    main()
