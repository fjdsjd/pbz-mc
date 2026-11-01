"""Retain the original dirt cube, inherited MC display transforms and GUI render.

World geometry/cracks are the existing pinned ExtractMinecraft conversion.
No substitute textures, fonts or hand-drawn icons are introduced.
"""
import io
import json
import math
import struct
import zipfile
from pathlib import Path
import json5
from PIL import Image, ImageDraw
from extend_original_item_icons import OriginalPack, ROOT, digest, resource_path
from convert_original_item_models import CONTEXTS, display_transform


def main():
    pack=OriginalPack('1.21.1'); dependencies={}; display={}; chain=[]; name='item/dirt'
    while name:
        path=resource_path('models',name); original=json.loads(pack.read(path,dependencies));chain.append(path)
        local=dict(original.get('display',{}))
        for prefix in ('thirdperson','firstperson'):
            right,left=prefix+'_righthand',prefix+'_lefthand'
            if left not in local and right in local: local[left]=local[right]
        for key,value in local.items(): display.setdefault(key,display_transform(value))
        name=original.get('parent')
    for context in CONTEXTS: display.setdefault(context,display_transform({}))
    texture='assets/minecraft/textures/block/dirt.png';pack.read(texture,dependencies)
    source=ROOT/'assets/private/minecraft-1.21.1/dirt.mesh';binary=source.read_bytes()
    world_manifest=json.loads(source.with_name('sources.json').read_text('utf-8'))
    assert digest(binary)==next(r['sha256'] for r in world_manifest['meshes'] if r['name']=='dirt')
    assert binary[:8]==b'STEVEM01' and binary[16:20]==b'dirt'
    binary=binary[:16]+b'item'+binary[20:]
    vertices,indices=struct.unpack_from('<II',binary,32)
    root=ROOT/'assets/private/item-models';target='minecraft/1.21.1/block/dirt.mesh'
    output=root/target;output.parent.mkdir(parents=True,exist_ok=True);output.write_bytes(binary)
    mp=root/'manifest.json';manifest=json.loads(mp.read_text('utf-8'));key='1.21.1/assets/minecraft/models/item/dirt.json'
    manifest['models'][key]=dict(path=target,minecraft_version='1.21.1',model='minecraft:item/dirt',
        geometry='original_cube',vertices=vertices,indices=indices,display=display,gui_light='side',texture=texture,
        parent_chain=chain,overrides=[],dependencies=['1.21.1/'+p for p in dependencies])
    manifest['items']['pbzmc:dirt']=dict(resource='minecraft:dirt',minecraft_version='1.21.1',
        contexts={c:dict(model=key,conditions=[]) for c in CONTEXTS},variants=[],item_dependencies=[])
    manifest['unavailable'].pop('pbzmc:dirt',None)
    outputs={r['path']:r for r in manifest['outputs']};outputs[target]=dict(path=target,sha256=digest(binary),bytes=len(binary))
    manifest['outputs']=list(outputs.values());sources={r['version']+'/'+r['path']:r for r in manifest['sources']}
    for path,raw in dependencies.items(): sources['1.21.1/'+path]=dict(version='1.21.1',path=path,sha256=digest(raw))
    manifest['sources']=list(sources.values());manifest.setdefault('recipe_sha256',{})[Path(__file__).name]=digest(Path(__file__).read_bytes())
    mp.write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n','utf-8')

    points=[];colors=[];d=display['gui']
    for i in range(vertices):
        x,y,z,nx,ny,nz,u,v,r,g,b,a=struct.unpack_from('<12f',binary,40+i*48)
        x,y,z=x*d['scale'][0],-y*d['scale'][1],-z*d['scale'][2]
        for axis in (2,1,0):
            c,s=math.cos(math.radians(d['rotation'][axis])),math.sin(math.radians(d['rotation'][axis]))
            if axis==2: x,y=x*c-y*s,x*s+y*c
            elif axis==1: x,z=x*c+z*s,-x*s+z*c
            else: y,z=y*c-z*s,y*s+z*c
        points.append((x,y,z));shade=1 if ny<-.5 else .5 if ny>.5 else .8 if abs(nz)>.5 else .6
        colors.append((round(r*shade*255),round(g*shade*255),round(b*shade*255),round(a*255)))
    icon=Image.new('RGBA',(64,64));draw=ImageDraw.Draw(icon)
    for i in sorted(range(0,vertices,4),key=lambda i:sum(points[j][2] for j in range(i,i+4))):
        draw.polygon([(32+points[j][0]*4,32-points[j][1]*4) for j in range(i,i+4)],fill=colors[i])
    ui=ROOT/'assets/private/minecraft-1.21.1/ui';up=ui/'manifest.json';data=json.loads(up.read_text('utf-8'))
    records={r['path']:r for r in data['outputs']}
    def save(path,image,source,source_raw,operation,**extra):
        file=ui/path;file.parent.mkdir(parents=True,exist_ok=True);image.save(file)
        records[path]=dict(path=path,sha256=digest(file.read_bytes()),source=source,source_sha256=digest(source_raw),
                           operation=operation,size=list(image.size),**extra)
    icon_path='original/minecraft/1.21.1/rendered/dirt.png'
    save(icon_path,icon,'minecraft-original:1.21.1:'+texture,dependencies[texture],'original-block-model-gui-render')
    data['item_icons']['pbzmc:dirt']=icon_path
    data['item_icon_sources']['pbzmc:dirt']=dict(minecraft_version='1.21.1',resource='minecraft:dirt',
        geometry='block/cube_all',display='block/block.json#display.gui',conditions=[])
    data['missing_item_icons']=[v for v in data['missing_item_icons'] if v!='pbzmc:dirt']
    data['incomplete_item_visuals'].pop('pbzmc:dirt',None)
    resource='assets/minecraft/textures/gui/recipe_book.png';raw=pack.read(resource,{})
    panel='original/minecraft/1.21.1/recipe_book_panel.png'
    save(panel,Image.open(io.BytesIO(raw)).crop((0,0,147,166)),'client:'+resource,raw,'lossless-crop',crop=[0,0,147,166])
    data['block_catalogue']=dict(panel=panel,profile='java-recipe-book-147x166')
    needed={ord(c):c for c in '方块目录无限取用泥土' if c not in data['glyphs']}
    raw=(ui/'original/font/unifont.zip').read_bytes()
    config=json5.loads((ui/'original/font/include/unifont.json').read_text('utf-8'))
    config=next(p for p in config['providers'] if p.get('hex_file')=='minecraft:font/unifont.zip')
    with zipfile.ZipFile(io.BytesIO(raw)) as archive:
        for member in archive.namelist():
            if not member.endswith('.hex'): continue
            for line in archive.read(member).decode('ascii').splitlines():
                code,bits=line.split(':',1);point=int(code,16)
                if point not in needed: continue
                char=needed.pop(point);packed=bytes.fromhex(bits);width=len(packed)//2
                bitmap=Image.frombytes('1',(width,16),packed);bbox=bitmap.getbbox()
                left,right=(bbox[0],bbox[2]-1) if bbox else (0,width-1)
                for override in config.get('size_overrides',[]):
                    if ord(override['from'])<=point<=ord(override['to']): left,right=override['left'],override['right'];break
                rgba=Image.new('RGBA',(width,16),(255,255,255,0));rgba.putalpha(bitmap.convert('L'))
                glyph=rgba.crop((left,0,right+1,16));path=f'glyphs/{point:06x}.png'
                save(path,glyph,'asset:minecraft/font/unifont.zip#'+member+':'+code,raw,'decode-original-unihex-bits',crop=[left,0,right+1,16])
                data['glyphs'][char]=dict(path=path,width=glyph.width/2,height=8,advance=glyph.width/2+1,ascent=7)
    assert not needed,needed
    data['outputs']=list(records.values());up.write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n','utf-8')
    pack.archive.close();print(json.dumps(dict(vertices=vertices,indices=indices,model=target,icon=icon_path)))


if __name__=='__main__': main()
