"""Bake vanilla 26.3 blockstates into shared, textured quads; shapes come from the game registry."""
from functools import lru_cache
from hashlib import sha256
from io import BytesIO
import json
import math
from pathlib import Path
import zipfile
from PIL import Image, ImageChops
from asset_paths import ROOT
from convert_building_blocks import CORNERS, NORMALS, rotation
from convert_mechanism_blocks import default_uv, element_transform
from convert_original_item_models import CONTEXTS, display_transform
from mc_generated_geometry import mesh_bytes, generated_mesh

BASE = ROOT/'assets/private/construction'
UI = ROOT/'assets/private/minecraft-1.21.1/ui'
SIZE, CELL, COLS = 1024, 32, 32


def compact(value):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':'))


def write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    return dict(bytes=len(data), sha256=sha256(data).hexdigest())


def path(kind, name, ext='.json'):
    return 'assets/minecraft/'+kind+'/'+name.removeprefix('minecraft:')+ext


class Pack:
    def __init__(self, jar):
        self.jar=jar
        self.slots={}

    @lru_cache(None)
    def js(self, filename):
        return json.loads(self.jar.read(filename))

    @lru_cache(None)
    def image(self, name):
        image=Image.open(BytesIO(self.jar.read(path('textures',name,'.png')))).convert('RGBA')
        # Original animation starts on its first sprite frame.
        if image.height>image.width:
            image=image.crop((0,0,image.width,image.width))
        assert image.size==(16,16), (name,image.size)
        return image

    @lru_cache(None)
    def model(self,name):
        name=name.removeprefix('minecraft:')
        if name=='builtin/generated':return [],{}, {},True
        row=self.js(path('models',name))
        elements,textures,display,generated=self.model(row['parent']) if 'parent' in row else ([],{},{},False)
        display=dict(display)
        for k,v in row.get('display',{}).items():
            display[k]=display_transform(v)
            if k.endswith('_righthand') and k.replace('_righthand','_lefthand') not in row['display']:
                display[k.replace('_righthand','_lefthand')]=display[k]
        return row.get('elements',elements),{**textures,**row.get('textures',{})},display,generated

    def tile(self, name):
        name=name.removeprefix('minecraft:')
        if name not in self.slots:
            assert len(self.slots)<COLS*COLS
            self.image(name)
            self.slots[name]=len(self.slots)
        i=self.slots[name]
        return ((i%COLS)*CELL+8,(i//COLS)*CELL+8)

    @lru_cache(None)
    def layer(self, name):
        # A transparent hole is alpha test, not alpha blend. Only original
        # partial-alpha pixels (e.g. stained glass) need transparent sorting.
        return 'translucent' if any(0<a<255 for a in self.image(name).getchannel('A').getdata()) else 'cutout'

    def atlases(self):
        images=[Image.new('RGBA',(SIZE,SIZE)) for _ in range(11)]
        damage=[self.image('block/destroy_stage_'+str(n)) for n in range(10)]
        for name in self.slots:
            x,y=self.tile(name)
            original=self.image(name)
            for n,atlas in enumerate(images):
                tile=original
                if n:
                    crack=damage[n-1]
                    doubled=ImageChops.add(ImageChops.multiply(original,crack),ImageChops.multiply(original,crack))
                    doubled.putalpha(original.getchannel('A'))
                    tile=Image.composite(doubled,original,crack.getchannel('A').point(lambda a:255 if a>=26 else 0))
                # One pixel of extruded gutter protects the outer texel of each sprite.
                atlas.paste(tile,(x,y));atlas.paste(tile.crop((0,0,1,16)),(x-1,y))
                atlas.paste(tile.crop((15,0,16,16)),(x+16,y));atlas.paste(tile.crop((0,0,16,1)),(x,y-1))
                atlas.paste(tile.crop((0,15,16,16)),(x,y+16))
        records=[]
        for i,img in enumerate(images):
            rel='atlas.png' if not i else 'crack_'+str(i-1)+'.png'
            stream=BytesIO();img.save(stream,format='PNG')
            records.append(dict(path=rel,**write(BASE/rel,stream.getvalue())))
        return records


def texture(value,textures):
    while True:
        if isinstance(value,dict):value=value['sprite']
        elif value.startswith('#'):value=textures[value[1:]]
        else:break
    return value.removeprefix('minecraft:')


def basis_uv(side,p):
    x,y,z=p
    return {'north':(-x,-y),'south':(x,-y),'east':(-z,-y),'west':(z,-y),'up':(x,z),'down':(x,-z)}[side]


def faces(pack,name,rx=0,ry=0,lock=False):
    elements,textures,display,generated=pack.model(name)
    if generated:return [],texture(textures['layer0'],textures),display
    result=[]
    for element in elements:
        lo,hi=element['from'],element['to']
        for side,f in element['faces'].items():
            image=texture(f['texture'],textures)
            uv=f.get('uv',default_uv(side,lo,hi))
            if uv[0]==uv[2] or uv[1]==uv[3]:continue
            normal=rotation(element_transform(NORMALS[side],element.get('rotation'),True),rx,ry)
            st=[(uv[0],uv[1]),(uv[2],uv[1]),(uv[2],uv[3]),(uv[0],uv[3])]
            points=[]
            for i in (0,3,2,1):
                c=CORNERS[side][(i-f.get('rotation',0)//90)%4]
                p=element_transform([lo[j]+c[j]*(hi[j]-lo[j]) for j in range(3)],element.get('rotation'))
                points.append(rotation([v-8 for v in p],rx,ry))
            if lock and (rx or ry):
                rotated=rotation(NORMALS[side],rx,ry)
                new_side=max(NORMALS,key=lambda k:sum(a*b for a,b in zip(NORMALS[k],rotated)))
                # Transform UV around the sprite centre into the rotated face's basis.
                src=[basis_uv(side,c) for c in CORNERS[side]]
                dst=[basis_uv(new_side,rotation(c,rx,ry)) for c in CORNERS[side]]
                sx,sy=src[1][0]-src[0][0],src[1][1]-src[0][1]
                dx,dy=dst[1][0]-dst[0][0],dst[1][1]-dst[0][1]
                co,si=sx*dx+sy*dy,sx*dy-sy*dx
                st=[(8+co*(u-8)-si*(v-8),8+si*(u-8)+co*(v-8)) for u,v in st]
            result.append((points,normal,st,image))
    assert result, name
    return result,None,display


def mesh(pack,quads,world):
    m={k:[] for k in ('positions','normals','uv','colors','triangles')}
    m['render_layer']='translucent' if any(pack.layer(q[3])=='translucent' for q in quads) else 'cutout'
    def pose(p):
        x,y,z=p
        return (z,-y,-x) if world else (x,-y,-z)
    for points,normal,uv,name in quads:
        x,y=pack.tile(name)
        pts=[pose(p) for p in points];n=pose(normal)
        i=len(m['positions']);m['positions'].extend(pts);m['normals'].extend([n]*4)
        m['uv'].extend([((x+u)/SIZE,(y+v)/SIZE) for u,v in uv]);m['colors'].extend([(1,1,1,1)]*4)
        a=[pts[1][j]-pts[0][j] for j in range(3)];b=[pts[2][j]-pts[0][j] for j in range(3)]
        cross=(a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0])
        forward=sum(v*w for v,w in zip(cross,n))>0
        m['triangles'].extend(i+k for k in ((0,1,2,0,2,3) if forward else (0,2,1,0,3,2)))
    return m


def icon(pack,quads,display):
    d=display.get('gui',display_transform({}));polys=[]
    for points,n,uv,name in quads:
        projected=[]
        for p in points:
            x,y,z=[p[i]*d['scale'][i] for i in range(3)]
            for axis in (2,1,0):
                c=math.cos(math.radians(d['rotation'][axis]));s=math.sin(math.radians(d['rotation'][axis]))
                if axis==2:x,y=x*c-y*s,x*s+y*c
                elif axis==1:x,z=x*c+z*s,-x*s+z*c
                else:y,z=y*c-z*s,y*s+z*c
            projected.append((32+(x+d['translation'][0])*4,32-(y+d['translation'][1])*4,z))
        p,q,_,r=projected;ax,ay=q[0]-p[0],q[1]-p[1];bx,by=r[0]-p[0],r[1]-p[1]
        det=ax*by-ay*bx
        if abs(det)<1.e-4:continue
        transforms=[]
        for j in (0,1):
            du,dv=uv[1][j]-uv[0][j],uv[3][j]-uv[0][j]
            a,b=(du*by-dv*ay)/det,(-du*bx+dv*ax)/det
            transforms.extend((a,b,uv[0][j]-a*p[0]-b*p[1]))
        tile=pack.image(name)
        shade=1 if n[1]>.5 else .5 if n[1]<-.5 else .8 if abs(n[2])>.5 else .6
        rgb=tile.convert('RGB').point([round(v*shade) for v in range(256)]*3).convert('RGBA')
        rgb.putalpha(tile.getchannel('A'))
        layer=rgb.transform((64,64),Image.Transform.AFFINE,transforms,resample=Image.Resampling.NEAREST)
        from PIL import ImageDraw
        mask=Image.new('L',(64,64));ImageDraw.Draw(mask).polygon([(x,y) for x,y,_ in projected],fill=255)
        layer.putalpha(ImageChops.multiply(layer.getchannel('A'),mask))
        polys.append((sum(p[2] for p in projected),layer))
    out=Image.new('RGBA',(64,64))
    for _,layer in sorted(polys,key=lambda p:p[0]):out.alpha_composite(layer)
    return out


def matches(condition,s):
    for k,v in condition.items():
        if k=='OR':
            if not any(matches(c,s) for c in v):return False
        elif k=='AND':
            if not all(matches(c,s) for c in v):return False
        elif s[k] not in v.split('|'):return False
    return True


def main():
    ref=json.loads((ROOT/'src/content/construction_reference.json').read_bytes())
    archive=zipfile.ZipFile(ROOT/'inputs/26.3.jar')
    pack=Pack(archive);BASE.mkdir(parents=True,exist_ok=True)
    blob=bytearray();records={};digest_index={};output_blocks={};layers={}
    def store(m):
        raw=mesh_bytes(m);h=sha256(raw).hexdigest()
        if h not in digest_index:
            digest_index[h]=len(records)+1;records[digest_index[h]]=[len(blob),len(raw),h];blob.extend(raw)
        layers[digest_index[h]]=m.get('render_layer','cutout')
        return digest_index[h]
    @lru_cache(None)
    def geometry(name,x,y,lock):
        quads,sprite,_=faces(pack,name,x,y,lock);assert not sprite
        return store(mesh(pack,quads,True))
    def alternatives(variant):
        seq=variant if isinstance(variant,list) else [variant]
        return [[geometry(v['model'],v.get('x',0),v.get('y',0),v.get('uvlock',False)),v.get('weight',1)] for v in seq]
    zh=json.loads((ROOT/'assets/private/minecraft-original/26.3/indexed-assets/minecraft/lang/zh_cn.json').read_bytes())
    profiles=list(ref['profiles'])
    profiles.append([{}, {'':[0,0,0,True,True]}])
    blocks=list(ref['blocks'])+[[n,'Block',len(profiles)-1] for n in ('dirt','tnt','spawner')]
    for name,_,profile,*unused in blocks:
        model=pack.js(path('items',name))['model'];assert model['type']=='minecraft:model'
        quads,sprite,display=faces(pack,model['model'])
        if sprite:
            tex=pack.image(sprite);silhouette=tex.copy()
            silhouette.putalpha(tex.getchannel('A').point(lambda a:255 if a else 0))
            m,_=generated_mesh(silhouette,'26.3');x,y=pack.tile(sprite)
            m['uv']=[((x+16*u)/SIZE,(y+16*v)/SIZE) for u,v in m['uv']]
            m['colors']=[(1,1,1,1)]*len(m['uv'])
            m['render_layer']=pack.layer(sprite)
            gui=tex
        else:
            m=mesh(pack,quads,False);gui=icon(pack,quads,display)
        assert gui.getbbox(),name
        item=store(m)
        iconpath='construction/'+name+'.png'
        (UI/'construction').mkdir(exist_ok=True,parents=True);gui.save(UI/iconpath)
        states=pack.js(path('blockstates',name));conditional=[]
        for cond,v in states.get('variants',{}).items():
            conditional.append((dict(t.split('=') for t in cond.split(',') if t),alternatives(v)))
        for part in states.get('multipart',[]):
            conditional.append((part.get('when',{}),alternatives(part['apply'])))
        defaults,physical=profiles[profile];keys=sorted(defaults)
        used={item};unique={};props={};all_states=[]
        for values,physical_state in physical.items():
            state=dict(zip(keys,values.split(',')))
            components=[v for c,v in conditional if matches(c,state)]
            assert components or ('multipart' in states and not ref['shapes'][physical_state[1]]),(name,state)
            for choices in components:used.update(v[0] for v in choices)
            entry=[components,*physical_state]
            skey=compact(entry)
            if skey not in unique:unique[skey]=len(all_states)+1;all_states.append(entry)
            props[values]=unique[skey]
        data=dict(keys=keys,defaults=defaults,lookup=props,states=all_states,item=item,
                  render_layer='translucent' if any(layers[i]=='translucent' for i in used) else 'cutout',
                  display={k:display.get(k,display_transform({})) for k in CONTEXTS},meshes={str(i):records[i] for i in sorted(used)})
        rel='blocks/'+name+'.json';record=write(BASE/rel,compact(data).encode())
        output_blocks[name]=dict(**record,label=zh['block.minecraft.'+name],icon=iconpath)
    write(BASE/'geometry.bin',blob)
    write(BASE/'manifest.json',compact(dict(schema=1,vanilla='26.3',atlases=pack.atlases(),shapes=ref['shapes'],blocks=output_blocks)).encode())
    print('Construction:',len(output_blocks),'blocks,',len(records),'unique meshes,',len(pack.slots),'textures,',len(blob),'geometry bytes')


if __name__=='__main__':main()
