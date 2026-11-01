"""Bind the verified original TNT cube to held/display contexts and its GUI icon.

Uses the same inherited vanilla display and orthographic pixel-color renderer
as convert_original_dirt.py; no substitute texture or hand-painted icon.
"""
import json
import math
import struct
from pathlib import Path
from PIL import Image, ImageDraw
from extend_original_item_icons import OriginalPack, ROOT, digest, resource_path
from convert_original_item_models import CONTEXTS, display_transform

ID='pbzmc:tnt'
KEY='1.21.1/assets/minecraft/models/item/tnt.json'
ICON='original/minecraft/1.21.1/rendered/tnt.png'
TARGET='minecraft/1.21.1/block/tnt.mesh'

def main():
    pack=OriginalPack('1.21.1');dependencies={};display={};chain=[];name='item/tnt'
    while name:
        path=resource_path('models',name);original=json.loads(pack.read(path,dependencies));chain.append(path)
        local=dict(original.get('display',{}))
        for prefix in ('thirdperson','firstperson'):
            right,left=prefix+'_righthand',prefix+'_lefthand'
            if left not in local and right in local:local[left]=local[right]
        for key,value in local.items():display.setdefault(key,display_transform(value))
        name=original.get('parent')
    for context in CONTEXTS:display.setdefault(context,display_transform({}))
    textures=['assets/minecraft/textures/block/tnt_'+face+'.png' for face in ('top','bottom','side')]
    for texture in textures:pack.read(texture,dependencies)
    source=ROOT/'assets/private/tnt/tnt.mesh';binary=source.read_bytes()
    source_manifest=json.loads(source.with_name('manifest.json').read_text(encoding='utf8'))
    record=next(r for r in source_manifest['outputs'] if r['path']=='tnt.mesh')
    assert digest(binary)==record['sha256'] and binary[:8]==b'STEVEM01'
    assert struct.unpack_from('<I',binary,8)[0]==1
    length=struct.unpack_from('<I',binary,12)[0]
    assert binary[16:16+length]==b'tnt'
    binary=binary[:12]+struct.pack('<I',4)+b'item'+binary[16+length:]
    vertices,indices=struct.unpack_from('<II',binary,32)
    assert (vertices,indices)==(record['vertices'],record['indices'])
    model_root=ROOT/'assets/private/item-models';target=model_root/TARGET
    target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(binary)
    path=model_root/'manifest.json';manifest=json.loads(path.read_text(encoding='utf8'))
    manifest['models'][KEY]=dict(path=TARGET,minecraft_version='1.21.1',model='minecraft:item/tnt',
        geometry='original_cube',vertices=vertices,indices=indices,display=display,gui_light='side',
        texture=textures[2],textures=textures,parent_chain=chain,overrides=[],
        dependencies=['1.21.1/'+p for p in dependencies],
        geometry_source=dict(path=source.relative_to(ROOT).as_posix(),sha256=record['sha256'],operation='rename-part-tnt-to-item-only'))
    manifest['items'][ID]=dict(resource='minecraft:tnt',minecraft_version='1.21.1',
        contexts={c:dict(model=KEY,conditions=[]) for c in CONTEXTS},variants=[],item_dependencies=[])
    manifest['unavailable'].pop(ID,None)
    outputs={r['path']:r for r in manifest['outputs']}
    outputs[TARGET]=dict(path=TARGET,sha256=digest(binary),bytes=len(binary))
    manifest['outputs']=list(outputs.values())
    sources={r['version']+'/'+r['path']:r for r in manifest['sources']}
    for member,raw in dependencies.items():sources['1.21.1/'+member]=dict(version='1.21.1',path=member,sha256=digest(raw))
    manifest['sources']=list(sources.values())
    recipe=digest(Path(__file__).read_bytes());manifest.setdefault('recipe_sha256',{})[Path(__file__).name]=recipe
    path.write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n',encoding='utf8')

    # Same original GUI display, projection and face lighting as dirt.
    points=[];colors=[];d=display['gui']
    for i in range(vertices):
        x,y,z,nx,ny,nz,u,v,r,g,b,a=struct.unpack_from('<12f',binary,40+i*48)
        x,y,z=x*d['scale'][0],-y*d['scale'][1],-z*d['scale'][2]
        for axis in (2,1,0):
            c,s=math.cos(math.radians(d['rotation'][axis])),math.sin(math.radians(d['rotation'][axis]))
            if axis==2:x,y=x*c-y*s,x*s+y*c
            elif axis==1:x,z=x*c+z*s,-x*s+z*c
            else:y,z=y*c-z*s,y*s+z*c
        points.append((x+d['translation'][0],y+d['translation'][1],z+d['translation'][2]))
        shade=1 if ny<-.5 else .5 if ny>.5 else .8 if abs(nz)>.5 else .6
        colors.append((round(r*shade*255),round(g*shade*255),round(b*shade*255),round(a*255)))
    icon=Image.new('RGBA',(64,64));draw=ImageDraw.Draw(icon)
    for i in sorted(range(0,vertices,4),key=lambda i:sum(points[j][2] for j in range(i,i+4))):
        draw.polygon([(32+points[j][0]*4,32-points[j][1]*4) for j in range(i,i+4)],fill=colors[i])
    ui=ROOT/'assets/private/minecraft-1.21.1/ui';target=ui/ICON;target.parent.mkdir(parents=True,exist_ok=True);icon.save(target)
    path=ui/'manifest.json';manifest=json.loads(path.read_text(encoding='utf8'))
    outputs={r['path']:r for r in manifest['outputs']}
    outputs[ICON]=dict(path=ICON,sha256=digest(target.read_bytes()),size=[64,64],
        source='minecraft-original:1.21.1:assets/minecraft/models/item/tnt.json',
        source_sha256=digest(dependencies['assets/minecraft/models/item/tnt.json']),
        operation='original-block-model-gui-render',
        source_dependencies=[dict(version='1.21.1',path=p,sha256=digest(raw)) for p,raw in dependencies.items()],
        geometry_source=dict(path=source.relative_to(ROOT).as_posix(),sha256=record['sha256']))
    manifest['outputs']=list(outputs.values());manifest['item_icons'][ID]=ICON
    manifest['item_icon_sources'][ID]=dict(minecraft_version='1.21.1',resource='minecraft:tnt',
        geometry='block/cube_bottom_top',display='block/block.json#display.gui',conditions=[])
    manifest['missing_item_icons']=[v for v in manifest['missing_item_icons'] if v!=ID]
    manifest['incomplete_item_visuals'].pop(ID,None)
    manifest.setdefault('recipe_sha256',{})[Path(__file__).name]=recipe
    path.write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n',encoding='utf8')
    pack.archive.close()
    print(json.dumps(dict(icon=str(target),model=str(model_root/TARGET),vertices=vertices,indices=indices,
        contexts=list(CONTEXTS),parent_chain=chain,icon_sha256=digest(target.read_bytes()))))

if __name__=='__main__':main()
