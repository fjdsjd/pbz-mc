"""Original building blocks and shared crack masks; incremental UI/models.

Only local assets are changed. Minecraft 1.21.1 JSON/geometry references are
source-verified. Existing dirt sources and existing tools remain untouched.
"""
from __future__ import annotations
import io
import json
import math
from pathlib import Path
import struct
from PIL import Image, ImageDraw
from extend_original_item_icons import OriginalPack, ROOT, digest, resource_path
from convert_original_item_models import CONTEXTS, display_transform, resolve_model
from mc_generated_geometry import mesh_bytes
from extend_original_item_labels import language

OUT=ROOT/'assets/private/building-blocks'
UI=ROOT/'assets/private/minecraft-1.21.1/ui'
ITEMS=ROOT/'assets/private/item-models'
NAMES=('dirt','stone','tnt','oak_log','stripped_oak_log','oak_planks','cobblestone','glass','spawner')
CUTOUT={'glass','spawner'}
SCALE=6.25
EXTRACTOR=ROOT/'third_party/wukong-steve/tools/ExtractMinecraft.py'
PIN='9f213556519dca4498fd46f02af6236ae121ecae'
CORNERS={
 'down':[(0,0,1),(0,0,0),(1,0,0),(1,0,1)],
 'up':[(0,1,0),(0,1,1),(1,1,1),(1,1,0)],
 'north':[(1,1,0),(1,0,0),(0,0,0),(0,1,0)],
 'south':[(0,1,1),(0,0,1),(1,0,1),(1,1,1)],
 'west':[(0,1,0),(0,0,0),(0,0,1),(0,1,1)],
 'east':[(1,1,1),(1,0,1),(1,0,0),(1,1,0)],
}
NORMALS={'down':(0,-1,0),'up':(0,1,0),'north':(0,0,-1),'south':(0,0,1),'west':(-1,0,0),'east':(1,0,0)}


def rotation(point,x=0,y=0):
    # Original ModelRotation: Quaternionf.rotateYXZ(-y,-x,0), about cube center.
    a,b,c=point;rx,ry=math.radians(-x),math.radians(-y)
    b,c=b*math.cos(rx)-c*math.sin(rx),b*math.sin(rx)+c*math.cos(rx)
    a,c=a*math.cos(ry)+c*math.sin(ry),-a*math.sin(ry)+c*math.cos(ry)
    return [round(a,10),round(b,10),round(c,10)]


def resolve(pack,name,deps):
    textures,display,chain={}, {}, [];elements=None;light=None
    while name:
        path=resource_path('models',name);assert path not in chain and len(chain)<16
        model=json.loads(pack.read(path,deps));chain.append(path)
        if elements is None and 'elements' in model:elements=model['elements']
        if light is None:light=model.get('gui_light')
        for key,value in model.get('textures',{}).items():textures.setdefault(key,value)
        local=dict(model.get('display',{}))
        for prefix in ('thirdperson','firstperson'):
            if prefix+'_lefthand' not in local and prefix+'_righthand' in local:local[prefix+'_lefthand']=local[prefix+'_righthand']
        for key,value in local.items():
            if key in CONTEXTS and key not in display:display[key]=display_transform(value)
        name=model.get('parent')
    if 'assets/minecraft/models/block/cube_all_inner_faces.json' in chain:
        # The reversed, inset copy exposes the same texels from inside the cage.
        # Share the outside vertices and emit reversed indices in merge().
        outer,inner=elements
        assert all(face.get('uv')==[16,0,0,16] and face['texture']=='#all' for face in inner['faces'].values())
        assert inner['from']==[15.998,.002,.002] and inner['to']==[.002,15.998,15.998]
        elements=[outer]
    assert elements and len(elements)==1,'unsupported original cube geometry'
    element=elements[0];assert element['from']==[0,0,0] and element['to']==[16,16,16] and 'rotation' not in element
    assert set(element['faces'])==set(CORNERS)
    faces=[]
    for side,value in element['faces'].items():
        texture=value['texture'];seen=set()
        while texture.startswith('#'):
            assert texture not in seen;seen.add(texture);texture=textures[texture[1:]]
        path=resource_path('textures',texture,'.png');image=Image.open(io.BytesIO(pack.read(path,deps))).convert('RGBA')
        assert image.size==(16,16) and set(image.getchannel('A').get_flattened_data())<={0,255}
        assert value.get('uv',[0,0,16,16])==[0,0,16,16] and value.get('tintindex',-1)==-1
        angle=value.get('rotation',0);assert angle in (0,90,180,270)
        # Original ModelElementTexture maps corners (0,1,2,3) to UV
        # (0,0),(0,1),(1,1),(1,0), then rotates that index by angle/90.
        points=[[c*16-8 for c in CORNERS[side][(i-angle//90)%4]] for i in (0,3,2,1)]
        faces.append(dict(side=side,points=points,normal=NORMALS[side],image=image,texture=path,uv_rotation=angle))
    return faces,dict(parent_chain=chain,display={c:display.get(c,display_transform({})) for c in CONTEXTS},gui_light=light or 'side',textures=textures)


def posed(faces,state):
    assert not state.get('uvlock',False),'UV-locked variants require a separate proven path'
    x,y=state.get('x',0),state.get('y',0);assert x in (0,90,180,270) and y in (0,90,180,270)
    return [dict(f,points=[rotation(p,x,y) for p in f['points']],normal=rotation(f['normal'],x,y)) for f in faces]


def point_at(face,u,v):
    p=face['points'];return [p[0][i]+u*(p[1][i]-p[0][i])+v*(p[3][i]-p[0][i]) for i in range(3)]


def crack_uv(side,point):
    # OverlayVertexConsumer ignores base UV, then applies Ry(pi), Rx(-pi/2),
    # Direction.getRotationQuaternion. Whole-block offset wraps in the sprite.
    x,y,z=(v+8 for v in point)
    return {'down':(x,16-z),'up':(x,z),'north':(16-x,16-y),'south':(x,16-y),
            'west':(16-z,16-y),'east':(z,16-y)}[side]


def cracked(faces,texture):
    result=[]
    for face in faces:
        side=next(k for k,n in NORMALS.items() if all(abs(a-b)<1e-8 for a,b in zip(n,face['normal'])))
        image=face['image'].copy()
        for y in range(16):
            for x in range(16):
                base=image.getpixel((x,y));u,v=crack_uv(side,point_at(face,(x+.5)/16,(y+.5)/16))
                damage=texture.getpixel((min(15,max(0,math.floor(u))),min(15,max(0,math.floor(v)))))
                if damage[3]>=26 and base[3]:
                    # Original CRUMBLING RGB uses DST_COLOR + SRC_COLOR.
                    image.putpixel((x,y),tuple(min(255,round(2*base[i]*damage[i]/255)) for i in range(3))+(base[3],))
        result.append(dict(face,image=image))
    return result


def merge(faces,space='world',double=False,inflate=1):
    mesh={k:[] for k in ('positions','normals','uv','colors','triangles')};texels=0
    def recipe(p):
        x,y,z=p;return [z,-y,-x] if space=='world' else [x,-y,-z]
    for face in faces:
        im=face['image'];pixels=[[im.getpixel((x,y)) for x in range(16)] for y in range(16)];used=set()
        for y in range(16):
            for x in range(16):
                color=pixels[y][x]
                if color[3]==0 or (x,y) in used:continue
                width=1
                while x+width<16 and (x+width,y) not in used and pixels[y][x+width]==color:width+=1
                height=1
                while y+height<16 and all((xx,y+height) not in used and pixels[y+height][xx]==color for xx in range(x,x+width)):height+=1
                used.update((xx,yy) for xx in range(x,x+width) for yy in range(y,y+height));texels+=width*height
                st=[(x/16,y/16),((x+width)/16,y/16),((x+width)/16,(y+height)/16),(x/16,(y+height)/16)]
                points=[[v*inflate for v in recipe(point_at(face,s,t))] for s,t in st];normal=recipe(face['normal']);offset=len(mesh['positions'])
                a=[points[1][i]-points[0][i] for i in range(3)];b=[points[2][i]-points[0][i] for i in range(3)]
                cross=(a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0])
                order=(0,1,2,0,2,3) if sum(c*n for c,n in zip(cross,normal))>0 else (0,2,1,0,3,2)
                mesh['positions'].extend(points);mesh['normals'].extend([normal]*4);mesh['uv'].extend(st);mesh['colors'].extend([tuple(c/255 for c in color)]*4)
                mesh['triangles'].extend(offset+i for i in order)
                if double:mesh['triangles'].extend(offset+i for i in reversed(order))
    return mesh,dict(opaque_texels=texels,vertices_before_merge=texels*4,vertices=len(mesh['positions']),indices=len(mesh['triangles']),double_sided=double)


def original_gui(mesh,display):
    points=[];colors=[];d=display['gui']
    for p,n,color in zip(mesh['positions'],mesh['normals'],mesh['colors']):
        x,y,z=p[0]*d['scale'][0],-p[1]*d['scale'][1],-p[2]*d['scale'][2]
        for axis in (2,1,0):
            c,s=math.cos(math.radians(d['rotation'][axis])),math.sin(math.radians(d['rotation'][axis]))
            if axis==2:x,y=x*c-y*s,x*s+y*c
            elif axis==1:x,z=x*c+z*s,-x*s+z*c
            else:y,z=y*c-z*s,y*s+z*c
        points.append((x+d['translation'][0],y+d['translation'][1],z+d['translation'][2]))
        shade=1 if n[1]<-.5 else .5 if n[1]>.5 else .8 if abs(n[2])>.5 else .6
        colors.append(tuple(round(c*shade*255) for c in color[:3])+(round(color[3]*255),))
    image=Image.new('RGBA',(64,64));draw=ImageDraw.Draw(image)
    for i in sorted(range(0,len(points),4),key=lambda k:sum(points[j][2] for j in range(k,k+4))):
        draw.polygon([(32+points[j][0]*4,32-points[j][1]*4) for j in range(i,i+4)],fill=colors[i])
    return image


def binary(mesh,name):
    raw=mesh_bytes(mesh);return raw[:12]+struct.pack('<I',len(name))+name.encode('ascii')+raw[20:]


def main():
    OUT.mkdir(parents=True,exist_ok=True);pack=OriginalPack('1.21.1');deps={};references=[]
    original_dirt=ROOT/'assets/private/minecraft-1.21.1/sources.json';dirt_digest=digest(original_dirt.read_bytes())
    outputs={};models={};items={};all_faces={};icons={};pending={};base_stats=[];raw_bytes=0
    def write(path,raw,**metadata):
        target=OUT/path;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(raw)
        record=dict(path=path,sha256=digest(raw),bytes=len(raw),**metadata);outputs[path]=record;return record
    def model_record(key,mesh,stats,**metadata):
        name=key.split('/')[-1];path='meshes/'+name+'.mesh';raw=binary(mesh,name)
        points=[[-p[2]*SCALE,-p[0]*SCALE,-p[1]*SCALE] for p in mesh['positions']]
        row=write(path,raw,scale=SCALE,pivot=[0,0,0],bounds_cm=[[min(v[i] for v in points),max(v[i] for v in points)] for i in range(3)],**stats)
        models[key]=dict(row,**metadata);return row
    for name in NAMES:
        state_path='assets/minecraft/blockstates/'+name+'.json';states=json.loads(pack.read(state_path,deps))['variants'];variants={}
        axes=('y','x','z') if name.endswith('_log') else (None,)
        for axis in axes:
            choices=states['axis='+axis if axis else ''];state=choices[0] if isinstance(choices,list) else choices
            faces,info=resolve(pack,state['model'],deps);faces=posed(faces,state)
            key='building-blocks/'+name+('_axis_'+axis if axis and axis!='y' else '')
            mesh,stats=merge(faces,double=name in CUTOUT);model_record(key,mesh,stats,content_id='pbzmc:'+name,axis=axis,original_state=state)
            all_faces[key]=faces;base_stats.append(stats);variants[axis or 'default']=key
        default=variants.get('y',variants.get('default'));item_faces,info=resolve(pack,'minecraft:item/'+name,deps)
        item_mesh,stats=merge(item_faces,'item',double=name in CUTOUT);icon=original_gui(item_mesh,info['display']);icons[name]=icon
        items['pbzmc:'+name]=dict(default_model=default,variants=variants,collision=dict(shape='box',half_cm=[50,50,50]),
            original_blockstates='original/'+state_path,original_random_variants_retained_not_selected=isinstance(states.get(''),list),
            alpha_mode='cutout-holes-double-sided' if name in CUTOUT else 'opaque',item_mesh=item_mesh,item_model_info=info)

    crack_images=[];cracks=[]
    for shader in ('rendertype_crumbling.fsh','rendertype_crumbling.json'):
        path='assets/minecraft/shaders/core/'+shader
        try:pack.read(path,deps)
        except KeyError:deps[path]=pack.archive.read(path) # exact pinned archive, not all shaders were in the earlier retained subset
    assert 'color.a < 0.1' in deps['assets/minecraft/shaders/core/rendertype_crumbling.fsh'].decode()
    for stage in range(10):
        path=f'assets/minecraft/textures/block/destroy_stage_{stage}.png';raw=pack.read(path,deps);texture=Image.open(io.BytesIO(raw)).convert('RGBA');crack_images.append(texture)
        assert set(texture.getchannel('A').get_flattened_data())=={1,255}
        mask=texture.copy()
        for y in range(16):
            for x in range(16):
                rgba=mask.getpixel((x,y))
                if rgba[3]<26:mask.putpixel((x,y),rgba[:3]+(0,))
        faces=[]
        for side,corners in CORNERS.items():
            pts=[[c*16-8 for c in p] for p in corners]
            by_uv={tuple(round(v) for v in crack_uv(side,p)):p for p in pts}
            faces.append(dict(side=side,points=[by_uv[uv] for uv in ((0,0),(16,0),(16,16),(0,16))],normal=NORMALS[side],image=mask))
        mesh,stats=merge(faces,inflate=1.002)
        record=write(f'cracks/destroy_stage_{stage}.mesh',binary(mesh,'destroy_stage_'+str(stage)),scale=SCALE,pivot=[0,0,0],inflate=1.002,**stats)
        cracks.append(dict(stage=stage,**record,source=path,source_alpha=[1,255],discard_alpha_below=.1,
            material='MC crumbling: RGB=2*src*dst; shared opaque gray overlay is not equivalent'))
    # Compute all 12 model orientations * ten stages first. Parent authorized
    # baking only under 32 MiB. Keep glass holes; scene-behind-glass is unknown.
    for key,faces in all_faces.items():
        for stage,texture in enumerate(crack_images):
            mesh,stats=merge(cracked(faces,texture),double=key.rsplit('/',1)[-1] in CUTOUT)
            raw=binary(mesh,key.split('/')[-1]+'_crack_'+str(stage));raw_bytes+=len(raw)
            pending[key+'_crack_'+str(stage)]=(mesh,stats,stage)
    assert raw_bytes<32*1024*1024,'baked cracks exceed authorized budget; no crack meshes written'
    for key,(mesh,stats,stage) in pending.items():model_record(key,mesh,stats,base_model=key.rsplit('_crack_',1)[0],crack_stage=stage,baked_crumbling=True)

    mp=ITEMS/'manifest.json';im=json.loads(mp.read_text(encoding='utf8'));old_bindings={k:v for k,v in im['items'].items() if k not in items}
    model_outputs={r['path']:r for r in im['outputs']};model_sources={r['version']+'/'+r['path']:r for r in im['sources']}
    up=UI/'manifest.json';ui=json.loads(up.read_text(encoding='utf8'));old_icons={k:v for k,v in ui['item_icons'].items() if k not in items};old_font=dict(ui['unicode_font']);ui_outputs={r['path']:r for r in ui['outputs']}
    labels,lang_source=language('1.21.1')
    for id,item in items.items():
        name=id.split(':')[1];mesh=item.pop('item_mesh');info=item.pop('item_model_info')
        # Dirt/TNT already have working original GUI/held bindings. Preserve them.
        if name not in ('dirt','tnt'):
            model_path=f'minecraft/1.21.1/block/{name}.mesh';raw=mesh_bytes(mesh);file=ITEMS/model_path;file.parent.mkdir(parents=True,exist_ok=True);file.write_bytes(raw)
            model_outputs[model_path]=dict(path=model_path,sha256=digest(raw),bytes=len(raw));key='1.21.1/assets/minecraft/models/item/'+name+'.json'
            im['models'][key]=dict(path=model_path,minecraft_version='1.21.1',model='minecraft:item/'+name,geometry='original_full_cube_json',
                vertices=len(mesh['positions']),indices=len(mesh['triangles']),dependencies=['1.21.1/'+p for p in deps],overrides=[],**info)
            im['items'][id]=dict(resource='minecraft:'+name,minecraft_version='1.21.1',contexts={c:dict(model=key,conditions=[]) for c in CONTEXTS},variants=[],item_dependencies=[])
            im['unavailable'].pop(id,None)
            icon=f'original/minecraft/1.21.1/rendered/{name}.png';file=UI/icon;file.parent.mkdir(parents=True,exist_ok=True);icons[name].save(file)
            ui_outputs[icon]=dict(path=icon,sha256=digest(file.read_bytes()),bytes=file.stat().st_size,size=[64,64],
                source='minecraft-original:1.21.1:assets/minecraft/models/item/'+name+'.json',source_sha256=digest(deps['assets/minecraft/models/item/'+name+'.json']),
                operation='original-block-model-gui-render',source_dependencies=[dict(version='1.21.1',path=p,sha256=digest(raw)) for p,raw in deps.items()])
            ui['item_icons'][id]=icon;ui['item_icon_sources'][id]=dict(minecraft_version='1.21.1',resource='minecraft:'+name,
                geometry='original_full_cube_json',display='block/block.json#display.gui',model_dependencies=[icon],conditions=[])
            ui['missing_item_icons']=[v for v in ui['missing_item_icons'] if v!=id];ui['incomplete_item_visuals'].pop(id,None)
        translation='block.minecraft.'+name;ui['labels'][id]=labels[translation];ui.setdefault('label_sources',{})[id]=dict(lang_source,kind='minecraft-translation',key=translation)
        item.update(icon=ui['item_icons'][id],label=ui['labels'][id],label_source=ui['label_sources'][id],item_model=im['items'][id]['contexts']['gui']['model'])
    tools=[];packs={'1.21.1':pack}
    for material in ('wooden','stone','copper','iron','golden','diamond','netherite'):
        for tool in ('pickaxe','shovel','axe'):
            id='pbzmc:'+material+'_'+tool;binding=im['items'][id];version=binding['minecraft_version']
            if version not in packs:packs[version]=OriginalPack(version)
            source_pack=packs[version];tool_deps={};expected,info=resolve_model(source_pack,'minecraft:item/'+id.split(':')[1],tool_deps)
            assert len(binding['contexts'])==8
            records={r['path']:r for r in im['outputs']}
            for context in CONTEXTS:
                model=im['models'][binding['contexts'][context]['model']];assert model['display']==info['display']
                actual=(ITEMS/model['path']).read_bytes();assert actual==mesh_bytes(expected) and digest(actual)==records[model['path']]['sha256']
            icon='original/minecraft/'+version+'/'+info['texture'].removeprefix('assets/minecraft/')
            icon_file=UI/icon;icon_file.parent.mkdir(parents=True,exist_ok=True)
            icon_file.write_bytes(tool_deps[info['texture']]);ui['item_icons'][id]=icon
            ui_outputs[icon]=dict(path=icon,sha256=digest(icon_file.read_bytes()),size=[16,16],
                source='minecraft-original:'+version+':'+info['texture'],
                source_sha256=digest(tool_deps[info['texture']]),operation='byte-copy')
            lang,provenance=language(version);key='item.minecraft.'+id.split(':')[1];assert ui['labels'][id]==lang[key]
            tools.append(dict(id=id,minecraft_version=version,contexts=list(CONTEXTS),model=model['path'],sha256=digest(actual),icon=icon,
                icon_sha256=digest((UI/icon).read_bytes()),label=lang[key],label_source=dict(provenance,key=key),
                source_dependencies=[dict(path=p,sha256=digest(raw)) for p,raw in tool_deps.items()],rewritten=False))
    recipe=digest(Path(__file__).read_bytes())
    for p,raw in deps.items():
        write('original/'+p,raw,source=p,source_sha256=digest(raw),operation='byte-copy')
        model_sources['1.21.1/'+p]=dict(version='1.21.1',path=p,sha256=digest(raw))
    im['outputs']=list(model_outputs.values());im['sources']=list(model_sources.values());im.setdefault('recipe_sha256',{})[Path(__file__).name]=recipe
    ui['outputs']=list(ui_outputs.values());ui.setdefault('recipe_sha256',{})[Path(__file__).name]=recipe
    if 'missing_item_labels' in ui:ui['missing_item_labels']=[r for r in ui['missing_item_labels'] if (r.get('id') if isinstance(r,dict) else r) not in items]
    assert old_bindings=={k:v for k,v in im['items'].items() if k not in items}
    tool_ids={r['id'] for r in tools}
    assert all(ui['item_icons'][k]==v for k,v in old_icons.items() if k not in tool_ids) and old_font==ui['unicode_font']
    mp.write_text(json.dumps(im,ensure_ascii=False,indent=2)+'\n',encoding='utf8');up.write_text(json.dumps(ui,ensure_ascii=False,indent=2)+'\n',encoding='utf8')
    assert digest(original_dirt.read_bytes())==dirt_digest,'legacy dirt sources must not be rewritten'
    write('LICENSE-NOTICE.txt',b'Private original Minecraft textures/models: Mojang/Microsoft. Not relicensed.\nOffline format follows STEVEM01 from nicedoctors/wukong-steve commit 9f213556519dca4498fd46f02af6236ae121ecae, PolyForm Noncommercial 1.0.0. See third_party/wukong-steve/LICENSE and NOTICE.\nNo decompiled source is copied to runtime assets.\n')
    contact=Image.new('RGBA',(128*len(NAMES),200),'#dadada');draw=ImageDraw.Draw(contact)
    for i,name in enumerate(NAMES):
        contact.alpha_composite(icons[name].resize((128,128),Image.Resampling.NEAREST),(i*128,24));draw.text((i*128+4,170),name,fill='#101010')
    contact.save(OUT/'preview.png')
    manifest=dict(schema=1,format='STEVEM01',private_local_assets=True,minecraft_version='1.21.1',origin_sha256=pack.manifest['archive_sha256'],
        archives={v:p.manifest['archive_sha256'] for v,p in packs.items()},
        units=dict(scale_for_mesh_bundle=6.25,block_cm=100,pivot=[0,0,0]),
        coordinate_contract='World MC(x,y,z)-8 -> recipe(z,-y,-x) -> UE(x,-z,y)*6.25. axis x -> UE X, y -> UE Z, z -> UE Y. Item geometry retains its established recipe(x,-y,-z).',
        models=models,items=items,cracks=cracks,outputs=list(outputs.values()),tools=tools,references=references,
        legacy_dirt_sources=dict(path=original_dirt.relative_to(ROOT).as_posix(),sha256=dirt_digest,rewritten=False),
        optimization='Exact RGBA rectangles within each source face. No per-frame generation. Share decoded buffers by model key; bounded crack cache should not preload all stages each frame.',
        baked_cracks=dict(models=len(pending),bytes=raw_bytes,megabytes=raw_bytes/1024/1024,
            largest_vertices=max(s['vertices'] for _,s,_ in pending.values()),formula='clamp(2 * original_face_rgb * original_crack_rgb / 255); alpha<.1 discarded',
            overlay_inflate=1.002,baked_full_cube_inflate=1,
            glass_limit='Original glass holes are retained. Exact multiplication of the unknown scene behind transparent holes requires a real framebuffer crumbling material; offline colors cannot reproduce that part.'),
        glass=dict(alpha_values=[0,255],opaque_texels=sum(a>0 for a in next(f['image'] for f in all_faces['building-blocks/glass']).getchannel('A').get_flattened_data()),
            transparent_filled=False,double_sided=True,collision='full 100 cm box'),
        source_dependencies=[dict(path=p,sha256=digest(raw)) for p,raw in deps.items()],recipe_sha256=recipe,
        evidence_preview=dict(path='preview.png',sha256=digest((OUT/'preview.png').read_bytes()),runtime_capture=False),deployed=False,runtime_tested=False)
    (OUT/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n',encoding='utf8')
    for p in packs.values():p.archive.close()
    print(json.dumps(dict(blocks=len(items),base_models=len(all_faces),models=len(models),baked_cracks=manifest['baked_cracks'],tools=len(tools),shared_masks=len(cracks),
        base_vertices=sum(s['vertices'] for s in base_stats),base_vertices_before_merge=sum(s['vertices_before_merge'] for s in base_stats),preview=str(OUT/'preview.png'))))


if __name__=='__main__':main()
