"""Incremental 29-item vanilla armor assets; no deployment or game execution.

Original humanoid geometry uses bone-local model pixels, not item-model axes.
Identical RGBA rectangles are merged offline within each original cube face.
"""
from __future__ import annotations
import bisect
import importlib.util
import io
import json
import math
from pathlib import Path
import re
import struct
import subprocess
from PIL import Image, ImageDraw
from extend_original_item_icons import OriginalPack, PACK_HASHES, ROOT, digest, resource_path
from convert_original_item_models import CONTEXTS, display_transform, resolve_model
from mc_generated_geometry import generated_mesh, mesh_bytes
from extend_original_item_labels import language
from convert_original_boat import combine, merged_mesh

OUT=ROOT/'assets/private/armor'
UI=ROOT/'assets/private/minecraft-1.21.1/ui'
ITEMS=ROOT/'assets/private/item-models'
EXTRACTOR=ROOT/'third_party/wukong-steve/tools/ExtractMinecraft.py'
PIN='9f213556519dca4498fd46f02af6236ae121ecae'
SCALE=100*.9375/16
MATERIALS=('leather','copper','chainmail','iron','golden','diamond','netherite')
PIECES={'helmet':('head',('head',),'outer'),'chestplate':('chest',('body','right_arm','left_arm'),'outer'),
        'leggings':('legs',('body','right_leg','left_leg'),'inner'),'boots':('feet',('right_leg','left_leg'),'outer')}
PARTS={
    'head':dict(origin=[-4,-8,-4],size=[8,8,8],uv=[0,0],joint=[0,0,0],mirror=False),
    'body':dict(origin=[-4,0,-2],size=[8,12,4],uv=[16,16],joint=[0,0,0],mirror=False),
    'right_arm':dict(origin=[-3,-2,-2],size=[4,12,4],uv=[40,16],joint=[-5,2,0],mirror=False),
    'left_arm':dict(origin=[-1,-2,-2],size=[4,12,4],uv=[40,16],joint=[5,2,0],mirror=True),
    'right_leg':dict(origin=[-2,0,-2],size=[4,12,4],uv=[0,16],joint=[-1.9,12,0],mirror=False),
    'left_leg':dict(origin=[-2,0,-2],size=[4,12,4],uv=[0,16],joint=[1.9,12,0],mirror=True),
}


def png(image):
    stream=io.BytesIO();image.save(stream,format='PNG');return stream.getvalue()


def default_leather(base,overlay,tint):
    assert base.size==overlay.size
    result=Image.new('RGBA',base.size)
    # Original layer0 receives the original default dye; overlay is untinted.
    # A one-time RGBA8 composition, no palette substitution or resampling.
    for y in range(base.height):
        for x in range(base.width):
            b=base.getpixel((x,y));o=overlay.getpixel((x,y))
            assert b[3] in (0,255) and o[3] in (0,255)
            result.putpixel((x,y),o if o[3] else tuple(round(b[i]*tint[i]/255) for i in range(3))+(b[3],))
    return result


def layered_item(pack,item,dependencies,tint):
    textures={};display={};chain=[];overrides=[];name='minecraft:item/'+item
    while name not in ('builtin/generated','minecraft:builtin/generated'):
        path=resource_path('models',name);assert path not in chain and len(chain)<16
        model=json.loads(pack.read(path,dependencies));chain.append(path)
        if len(chain)==1:overrides=model.get('overrides',[])
        assert 'elements' not in model and model.get('gui_light','front')=='front'
        for key,value in model.get('textures',{}).items():textures.setdefault(key,value)
        local=dict(model.get('display',{}))
        for prefix in ('thirdperson','firstperson'):
            if prefix+'_lefthand' not in local and prefix+'_righthand' in local:local[prefix+'_lefthand']=local[prefix+'_righthand']
        for key,value in local.items():
            if key in CONTEXTS and key not in display:display[key]=display_transform(value)
        name=model['parent']
    assert set(textures)=={'layer0','layer1'}
    images=[];paths=[]
    for key in ('layer0','layer1'):
        path=resource_path('textures',textures[key],'.png');paths.append(path)
        images.append(Image.open(io.BytesIO(pack.read(path,dependencies))).convert('RGBA'))
    image=default_leather(*images,tint);assert image.size==(16,16)
    mesh,stats=generated_mesh(image,pack.version)
    return image,mesh,dict(display={c:display.get(c,display_transform({})) for c in CONTEXTS},gui_light='front',
        texture=paths[0],texture_layers=paths,texture_size=list(image.size),parent_chain=chain,overrides=overrides,
        geometry=stats,default_dye_rgb=list(tint),composition='original layer0 * default dye; original layer1 untinted')


def runtime(v):return [-v[2]*SCALE,-v[0]*SCALE,-v[1]*SCALE]


def bounds(mesh):return [[min(v[i] for v in mesh['positions']),max(v[i] for v in mesh['positions'])] for i in range(3)]


def worn_mesh(bone,texture,layer,extract):
    part=PARTS[bone];dilation=(.5 if layer=='inner' else 1)-(.1 if bone.endswith('_leg') else 0)
    faces=extract.cuboid(part['origin'],part['size'],part['uv'],dilation)
    mesh=merged_mesh(faces,texture,extract)
    source_count=sum(sum(texture.getpixel((math.floor(u+(x+.5)*w/abs(w)),math.floor(v+(y+.5)*h/abs(h))))[3]>0
                         for x in range(int(abs(w))) for y in range(int(abs(h)))) for _,(u,v,w,h) in faces)
    if part['mirror']:
        cx=part['origin'][0]+part['size'][0]/2
        mesh['positions']=[[2*cx-x,y,z] for x,y,z in mesh['positions']]
        mesh['normals']=[[-x,y,z] for x,y,z in mesh['normals']]
        indices=mesh['triangles'];mesh['triangles']=[indices[i+j] for i in range(0,len(indices),3) for j in (0,2,1)]
    # Vanilla armor uses armorCutoutNoCull. Keep the backface index pass, without
    # duplicating vertex buffers; PBZ's original opaque font material is culled.
    front=list(mesh['triangles']);mesh['triangles'] += [front[i+j] for i in range(0,len(front),3) for j in (0,2,1)]
    return mesh,dict(dilation=dilation,source_opaque_texels=source_count,merged_quads=len(mesh['positions'])//4,
        vertices_before_merge=source_count*4,vertices=len(mesh['positions']),indices=len(mesh['triangles']),
        double_sided_indices=True)


def preview(full_sets,path):
    image=Image.new('RGB',(1600,680),'#e8e8e8');draw=ImageDraw.Draw(image)
    for row,degrees in enumerate((24,204)):
        for col,(material,mesh) in enumerate(full_sets.items()):
            angle=math.radians(degrees)
            def project(p):
                x,y,z=p;return x*math.cos(angle)-z*math.sin(angle),y,(x*math.sin(angle)+z*math.cos(angle))
            points=list(map(project,mesh['positions']));scale=7
            for i in sorted(range(0,len(points),4),key=lambda i:sum(points[j][2] for j in range(i,i+4)),reverse=True):
                color=tuple(round(c*255) for c in mesh['colors'][i][:3])
                draw.polygon([(col*200+100+points[j][0]*scale,row*325+100+points[j][1]*scale) for j in range(i,i+4)],fill=color)
            draw.text((col*200+20,row*325+15),material+(' / front' if row==0 else ' / back'),fill='#111111')
    draw.text((20,645),'Evidence-only rendering of generated original armor quads. No PBZ runtime capture.',fill='#111111')
    image.save(path)


def main():
    spec=importlib.util.spec_from_file_location('pinned_mc_armor_extract',EXTRACTOR)
    extract=importlib.util.module_from_spec(spec);spec.loader.exec_module(extract)
    references=[]
    # The default dye is verified from the original item definition, not a custom palette.
    packs={v:OriginalPack(v) for v in PACK_HASHES};dependencies={v:{} for v in packs}
    dye_definition=json.loads(packs['26.3'].read('assets/minecraft/items/leather_helmet.json',dependencies['26.3']))
    default_dye=dye_definition['model']['fallback']['tints'][0]['default']
    assert default_dye==-6265536
    tint=tuple(((default_dye & 0xffffff)>>s)&255 for s in (16,8,0))
    OUT.mkdir(parents=True,exist_ok=True);outputs={};textures={};items={};full_sets={};all_stats=[]
    skin_texture=Image.open(io.BytesIO(packs['1.21.1'].read('assets/minecraft/textures/entity/player/wide/steve.png',dependencies['1.21.1']))).convert('RGBA')
    skin=[]
    for name,joint,origin,size,uv,dilation in extract.PARTS[:6]:
        mesh=merged_mesh(extract.cuboid(origin,size,uv,dilation),skin_texture,extract)
        skin.append(dict(mesh,positions=[[a+b for a,b in zip(p,joint)] for p in mesh['positions']]))
    def write(relative,raw,**extra):
        file=OUT/relative;file.parent.mkdir(parents=True,exist_ok=True);file.write_bytes(raw)
        outputs[relative]=dict(path=relative,sha256=digest(raw),bytes=len(raw),**extra)
    for material in MATERIALS+('turtle',):
        version='26.3' if material=='copper' else '1.21.1';pack=packs[version];dep=dependencies[version]
        source_material='gold' if material=='golden' else material
        for layer in (('outer',) if material=='turtle' else ('outer','inner')):
            number=1 if layer=='outer' else 2
            source=(f'assets/minecraft/textures/entity/equipment/{"humanoid" if number==1 else "humanoid_leggings"}/copper.png'
                    if material=='copper' else f'assets/minecraft/textures/models/armor/{source_material}_layer_{number}.png')
            raw=pack.read(source,dep);texture=Image.open(io.BytesIO(raw)).convert('RGBA');assert texture.size==(64,32)
            assert set(texture.getchannel('A').get_flattened_data())<={0,255}
            retained=f'original/{version}/'+source.removeprefix('assets/minecraft/')
            write(retained,raw,source=source,minecraft_version=version,operation='byte-copy')
            source_layers=[dict(path=source,sha256=digest(raw),retained=retained,tinted=material=='leather')]
            if material=='leather':
                overlay_source=source.removesuffix('.png')+'_overlay.png';overlay_raw=pack.read(overlay_source,dep)
                overlay=Image.open(io.BytesIO(overlay_raw)).convert('RGBA')
                overlay_retained=f'original/{version}/'+overlay_source.removeprefix('assets/minecraft/')
                write(overlay_retained,overlay_raw,source=overlay_source,minecraft_version=version,operation='byte-copy')
                source_layers.append(dict(path=overlay_source,sha256=digest(overlay_raw),retained=overlay_retained,tinted=False))
                texture=default_leather(texture,overlay,tint)
                retained=f'default/leather_{layer}.png';write(retained,png(texture),operation='original-default-dye-plus-overlay',default_dye_rgb=list(tint))
            # Original head hat cube is included by visibility rules but empty in all these layers.
            assert not texture.crop((32,0,64,16)).getchannel('A').getbbox(),'new opaque hat layer requires a separate original cube'
            textures[material,layer]=(texture,retained,source_layers)
        complete=[]
        for piece,(slot,bones,layer) in PIECES.items():
            if material=='turtle' and piece!='helmet':continue
            item=f'{material}_{piece}';content_id='pbzmc:'+item;texture,retained,source_layers=textures[material,layer];entries=[]
            for bone in bones:
                mesh,stats=worn_mesh(bone,texture,layer,extract);assert mesh['positions']
                path=f'minecraft/{version}/{material}/{piece}_{bone}.mesh';target=OUT/path;target.parent.mkdir(parents=True,exist_ok=True)
                extract.write_binary(target,[dict(name=bone,pivot=[0,0,0],mesh=mesh)])
                write(path,target.read_bytes(),bone=bone,local_bounds_model_pixels=bounds(mesh),**stats)
                entry=dict(bone=bone,path=path,layer=layer,dilation=stats['dilation'],pivot=[0,0,0],
                    original_joint_pivot=PARTS[bone]['joint'],mirror=PARTS[bone]['mirror'],texture=retained,
                    source_layers=source_layers,local_bounds_model_pixels=bounds(mesh))
                entries.append(entry);all_stats.append(stats)
                joint=PARTS[bone]['joint'];complete.append(dict(mesh,positions=[[a+b for a,b in zip(p,joint)] for p in mesh['positions']]))
            items[content_id]=dict(slot=slot,material=material,minecraft_version=version,parts=entries,
                default_dye_rgb=list(tint) if material=='leather' else None,untrimmed=True,hat_cube_empty=piece=='helmet')
        full_sets[material]=combine(skin+complete)

    # Incremental original GUI + held assets. Preserve every unrelated binding.
    mp=ITEMS/'manifest.json';models=json.loads(mp.read_text(encoding='utf8'));old_items={k:v for k,v in models['items'].items() if k not in items}
    model_outputs={r['path']:r for r in models['outputs']};model_sources={r['version']+'/'+r['path']:r for r in models['sources']}
    up=UI/'manifest.json';ui=json.loads(up.read_text(encoding='utf8'));old_icons={k:v for k,v in ui['item_icons'].items() if k not in items};old_font=dict(ui['unicode_font'])
    ui_outputs={r['path']:r for r in ui['outputs']};translations={};glyphs={};labels={}
    for version in packs:translations[version]=language(version)
    for content_id,item_info in items.items():
        item=content_id.split(':')[1];version=item_info['minecraft_version'];pack=packs[version];dep={}
        if item_info['material']=='leather':image,mesh,info=layered_item(pack,item,dep,tint);icon=f'original/minecraft/{version}/rendered/{item}_default.png';icon_raw=png(image)
        else:
            mesh,info=resolve_model(pack,'minecraft:item/'+item,dep)
            icon=f'original/minecraft/{version}/'+info['texture'].removeprefix('assets/minecraft/');icon_raw=dep[info['texture']]
        key=version+'/'+resource_path('models','minecraft:item/'+item)
        model_path=f'minecraft/{version}/item/{item}.mesh';binary=mesh_bytes(mesh)
        target=ITEMS/model_path;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(binary)
        model_outputs[model_path]=dict(path=model_path,sha256=digest(binary),bytes=len(binary))
        models['models'][key]=dict(path=model_path,minecraft_version=version,model='minecraft:item/'+item,
            dependencies=[version+'/'+p for p in dep],vertices=len(mesh['positions']),indices=len(mesh['triangles']),**info)
        # Trim variants outside this task are explicit; normal armor now has all eight contexts.
        models['items'][content_id]=dict(resource='minecraft:'+item,minecraft_version=version,
            contexts={c:dict(model=key,conditions=['untrimmed only']) for c in CONTEXTS},
            variants=[],item_dependencies=[],armor_default=True,
            default_dye_rgb=list(tint) if item_info['material']=='leather' else None)
        models['unavailable'].pop(content_id,None)
        for path,raw in dep.items():model_sources[version+'/'+path]=dict(version=version,path=path,sha256=digest(raw))
        dependencies[version].update(dep);retained=[]
        for path,raw in dep.items():
            relative='original/minecraft/'+version+'/'+path.removeprefix('assets/minecraft/')
            file=UI/relative;file.parent.mkdir(parents=True,exist_ok=True);file.write_bytes(raw)
            source_record=dict(path=relative,sha256=digest(raw),bytes=len(raw),source='minecraft-original:'+version+':'+path,
                source_sha256=digest(raw),operation='byte-copy',minecraft_version=version,namespace='minecraft')
            if relative.endswith('.png'):source_record['size']=list(Image.open(io.BytesIO(raw)).size)
            ui_outputs[relative]=source_record;retained.append(relative)
        file=UI/icon;file.parent.mkdir(parents=True,exist_ok=True);file.write_bytes(icon_raw)
        ui_outputs[icon]=dict(path=icon,sha256=digest(icon_raw),bytes=len(icon_raw),size=[16,16],
            source='minecraft-original:'+version+':'+info['texture'],source_sha256=digest(dep[info['texture']]),
            operation='original-layer0-default-dye-layer1-overlay' if item_info['material']=='leather' else 'byte-copy',
            minecraft_version=version,namespace='minecraft')
        ui['item_icons'][content_id]=icon
        ui.setdefault('item_icon_sources',{})[content_id]=dict(minecraft_version=version,resource='minecraft:'+item,
            model_dependencies=retained+([icon] if icon not in retained else []),conditions=['untrimmed'],
            default_dye_rgb=list(tint) if item_info['material']=='leather' else None)
        ui['missing_item_icons']=[v for v in ui['missing_item_icons'] if v!=content_id];ui['incomplete_item_visuals'].pop(content_id,None)
        lang,provenance=translations[version];translation='item.minecraft.'+item;label=lang[translation]
        ui['labels'][content_id]=label;ui.setdefault('label_sources',{})[content_id]=dict(provenance,kind='minecraft-translation',key=translation)
        labels[content_id]=dict(text=label,**ui['label_sources'][content_id]);item_info.update(icon=icon,held_model=model_path,label=label)
    if 'missing_item_labels' in ui:ui['missing_item_labels']=[v for v in ui['missing_item_labels'] if (v.get('id') if isinstance(v,dict) else v) not in items]
    # Use the existing source-verified complete font. No global atlas regeneration.
    header_path=ui['unicode_font']['index'];header_raw=(UI/header_path).read_bytes();assert digest(header_raw)==ui_outputs[header_path]['sha256']
    header=json.loads(header_raw);raw=(UI/header['index']).read_bytes();assert digest(raw)==ui_outputs[header['index']]['sha256']
    rows=list(struct.iter_unpack('<IHHHBB',raw));codes=[r[0] for r in rows]
    for character in sorted(set(''.join(v['text'] for v in labels.values()))):
        if character in ui['glyphs']:
            g=ui['glyphs'][character];path=g['path'];glyphs[character]=dict(character=character,codepoint=ord(character),path=path,sha256=ui_outputs[path]['sha256'],kind='existing-explicit-glyph')
        else:
            index=bisect.bisect_left(codes,ord(character));assert index<len(rows) and rows[index][0]==ord(character)
            _,page,x,y,w,h=rows[index];path=header['pages'][page-1]
            glyphs[character]=dict(character=character,codepoint=ord(character),path=path,sha256=ui_outputs[path]['sha256'],region=[x,y,w,h],kind='existing-original-unihex-atlas')
        assert digest((UI/path).read_bytes())==ui_outputs[path]['sha256']
    recipe=digest(Path(__file__).read_bytes());models['outputs']=list(model_outputs.values());models['sources']=list(model_sources.values());models.setdefault('recipe_sha256',{})[Path(__file__).name]=recipe
    ui['outputs']=list(ui_outputs.values());ui.setdefault('recipe_sha256',{})[Path(__file__).name]=recipe
    assert old_items=={k:v for k,v in models['items'].items() if k not in items}
    assert old_icons=={k:v for k,v in ui['item_icons'].items() if k not in items} and old_font==ui['unicode_font']
    mp.write_text(json.dumps(models,ensure_ascii=False,indent=2)+'\n',encoding='utf8');up.write_text(json.dumps(ui,ensure_ascii=False,indent=2)+'\n',encoding='utf8')
    preview(full_sets,OUT/'preview.png')
    sounds={m:'item.armor.equip_'+('gold' if m=='golden' else 'chain' if m=='chainmail' else m) for m in MATERIALS+('turtle',)}
    write('LICENSE-NOTICE.txt',b'Minecraft textures and models: original private local client resources, Mojang/Microsoft; not relicensed.\nConverter shares the pinned Wukong Steve STEVEM01 encoder and cuboid layout under PolyForm Noncommercial 1.0.0.\nSee third_party/wukong-steve/LICENSE and NOTICE, source hashes and original client archive hashes in manifest.json.\nNo decompiled Minecraft source is included in runtime assets.\n')
    sources=[dict(minecraft_version=v,path=p,sha256=digest(raw)) for v,dep in dependencies.items() for p,raw in dep.items()]
    manifest=dict(schema=1,format='STEVEM01',private_local_assets=True,items=items,outputs=list(outputs.values()),
        units=dict(scale_for_mesh_bundle=SCALE,pixel_cm=SCALE,base_block_cm=100,steve_scale=.9375),
        coordinate_contract='Original bone-local MC(x,y,z) -> mesh_bundle UE(-z,-x,-y)*scale; pivot is zero; attach to render_pose[bone]. Do not add original_joint_pivot twice.',
        original_parts=PARTS,optimization='Offline exact RGBA greedy rectangles within each original cube face; mirrored geometry and reversed winding; original no-cull backface index pass; cache decoded geometry by path+scale.',
        material_contract='Hard alpha holes omitted; original default leather dye and untinted overlay composed once at RGBA8 precision; original sRGB colors, white-texture vertex-color renderer; no filtering or relighting parity claim.',
        totals=dict(items=len(items),meshes=len(all_stats),vertices=sum(s['vertices'] for s in all_stats),
            vertices_before_merge=sum(s['vertices_before_merge'] for s in all_stats),indices=sum(s['indices'] for s in all_stats)),
        sources=sources,references=references,archives=PACK_HASHES,labels=labels,glyphs=list(glyphs.values()),font_regenerated=False,
        sound_events=sounds,
        audio_added=False,recipe_sha256={Path(__file__).name:recipe,'convert_original_boat.py':digest((ROOT/'tools/convert_original_boat.py').read_bytes())},
        upstream=dict(commit=PIN,extractor=EXTRACTOR.relative_to(ROOT).as_posix(),sha256=digest(EXTRACTOR.read_bytes()),license='third_party/wukong-steve/LICENSE',notice='third_party/wukong-steve/NOTICE'),
        limitations=['29 default undyed/untrimmed player armor items; arbitrary leather dyes, trims and enchantment glint variants not generated by this converter.',
                     'Host lifecycle, animation attachment, first-person visibility and runtime performance require integration checks.'],
        evidence_preview=dict(path='preview.png',sha256=digest((OUT/'preview.png').read_bytes()),runtime_capture=False),deployed=False,runtime_tested=False)
    (OUT/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n',encoding='utf8')
    for pack in packs.values():pack.archive.close()
    print(json.dumps(dict(**manifest['totals'],font_glyphs=len(glyphs),preview=str(OUT/'preview.png'),deployed=False)))


if __name__=='__main__':main()
