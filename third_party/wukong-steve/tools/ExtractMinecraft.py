"""Convert the installed Java client resources into a versioned Steve asset bundle."""
from __future__ import annotations
import argparse
import hashlib
import io
import json
import math
from pathlib import Path
import struct
import zipfile
from PIL import Image, ImageDraw

PARTS = [
    ("head", (0, 0, 0), (-4, -8, -4), (8, 8, 8), (0, 0), 0),
    ("body", (0, 0, 0), (-4, 0, -2), (8, 12, 4), (16, 16), 0),
    ("right_arm", (-5, 2, 0), (-3, -2, -2), (4, 12, 4), (40, 16), 0),
    ("left_arm", (5, 2, 0), (-1, -2, -2), (4, 12, 4), (32, 48), 0),
    ("right_leg", (-1.9, 12, 0), (-2, 0, -2), (4, 12, 4), (0, 16), 0),
    ("left_leg", (1.9, 12, 0), (-2, 0, -2), (4, 12, 4), (16, 48), 0),
    ("hat", (0, 0, 0), (-4, -8, -4), (8, 8, 8), (32, 0), .5),
    ("jacket", (0, 0, 0), (-4, 0, -2), (8, 12, 4), (16, 32), .25),
    ("right_sleeve", (-5, 2, 0), (-3, -2, -2), (4, 12, 4), (40, 32), .25),
    ("left_sleeve", (5, 2, 0), (-1, -2, -2), (4, 12, 4), (48, 48), .25),
    ("right_pants", (-1.9, 12, 0), (-2, 0, -2), (4, 12, 4), (0, 32), .25),
    ("left_pants", (1.9, 12, 0), (-2, 0, -2), (4, 12, 4), (0, 48), .25),
]


def cuboid(origin, size, uv, inflate=0):
    x, y, z = origin
    w, h, d = size
    x0, y0, z0 = x-inflate, y-inflate, z-inflate
    x1, y1, z1 = x+w+inflate, y+h+inflate, z+d+inflate
    u, v = uv
    # The Java cube's unfolded texture layout; each quad is outward-facing.
    faces = [
        ([(x0,y0,z0),(x1,y0,z0),(x1,y1,z0),(x0,y1,z0)], (u+d,v+d,w,h)),
        ([(x1,y0,z1),(x0,y0,z1),(x0,y1,z1),(x1,y1,z1)], (u+d+w+d,v+d,w,h)),
        ([(x1,y0,z0),(x1,y0,z1),(x1,y1,z1),(x1,y1,z0)], (u+d+w,v+d,d,h)),
        ([(x0,y0,z1),(x0,y0,z0),(x0,y1,z0),(x0,y1,z1)], (u,v+d,d,h)),
        ([(x0,y0,z1),(x1,y0,z1),(x1,y0,z0),(x0,y0,z0)], (u+d,v,w,d)),
        ([(x0,y1,z0),(x1,y1,z0),(x1,y1,z1),(x0,y1,z1)], (u+d+w,v+d,w,-d)),
    ]
    return faces


def mesh_from_faces(faces, texture):
    positions, normals, uvs, colors, triangles = [], [], [], [], []
    tw, th = texture.size
    for verts, (u,v,w,h) in faces:
        # Subdivision preserves the original skin even with a vertex-colour material.
        cols, rows = int(abs(w)), int(abs(h))
        for iy in range(rows):
            for ix in range(cols):
                rgba = texture.getpixel((math.floor(u+(ix+.5)*w/cols),math.floor(v+(iy+.5)*h/rows)))
                if rgba[3] == 0:
                    continue
                base = len(positions)
                for s,t in [(ix/cols,iy/rows),((ix+1)/cols,iy/rows),((ix+1)/cols,(iy+1)/rows),(ix/cols,(iy+1)/rows)]:
                    positions.append([verts[0][j]+s*(verts[1][j]-verts[0][j])+t*(verts[3][j]-verts[0][j]) for j in range(3)])
                    uvs.append([(u+s*w)/tw,(v+t*h)/th])
                    colors.append([c/255 for c in rgba])
                a=[positions[base+1][j]-positions[base][j] for j in range(3)]
                b=[positions[base+3][j]-positions[base][j] for j in range(3)]
                n=[a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0]]
                length=math.sqrt(sum(c*c for c in n))
                # These UV-ordered quads wind inward; reverse for outward faces.
                normals.extend([[-c/length for c in n]]*4)
                triangles.extend([base,base+2,base+1,base,base+3,base+2])
    return dict(positions=positions,normals=normals,uv=uvs,colors=colors,triangles=triangles)


def write_gltf(bundle, out):
    blob=bytearray()
    views, accessors, meshes, nodes = [], [], [], []
    def add(data, kind, dims, component=5126):
        while len(blob)%4: blob.append(0)
        offset=len(blob)
        flat=[x for row in data for x in row] if dims>1 else data
        blob.extend(struct.pack('<'+('f' if component==5126 else 'I')*len(flat),*flat))
        views.append(dict(buffer=0,byteOffset=offset,byteLength=len(blob)-offset))
        acc=dict(bufferView=len(views)-1,componentType=component,count=len(data),type=kind)
        if kind=='VEC3' and data:
            acc['min']=[min(row[i] for row in data) for i in range(3)]
            acc['max']=[max(row[i] for row in data) for i in range(3)]
        accessors.append(acc)
        return len(accessors)-1
    scale=.9375/16
    for part in bundle['parts']:
        m=part['mesh']
        p=[[x*scale,-y*scale,-z*scale] for x,y,z in m['positions']]
        n=[[x,-y,-z] for x,y,z in m['normals']]
        attrs={'POSITION':add(p,'VEC3',3),'NORMAL':add(n,'VEC3',3),'TEXCOORD_0':add(m['uv'],'VEC2',2)}
        indices=add(m['triangles'],'SCALAR',1,5125)
        meshes.append(dict(name=part['name'],primitives=[dict(attributes=attrs,indices=indices,material=0)]))
        x,y,z=part['pivot']
        nodes.append(dict(name=part['name'],mesh=len(meshes)-1,translation=[x*scale,(24-y)*scale,-z*scale]))
    gltf=dict(asset=dict(version='2.0',generator='Wukong Steve local resource converter'),
        buffers=[dict(uri='steve.bin',byteLength=len(blob))],bufferViews=views,accessors=accessors,
        images=[dict(uri='textures/steve.png')],samplers=[dict(magFilter=9728,minFilter=9728,wrapS=33071,wrapT=33071)],
        textures=[dict(sampler=0,source=0)],materials=[dict(name='SteveSkin',pbrMetallicRoughness=dict(baseColorTexture=dict(index=0),metallicFactor=0,roughnessFactor=1),alphaMode='MASK',alphaCutoff=.1)],
        meshes=meshes,nodes=nodes,scenes=[dict(nodes=list(range(len(nodes))))],scene=0)
    (out/'steve.bin').write_bytes(blob)
    (out/'steve.gltf').write_text(json.dumps(gltf,separators=(',',':')),encoding='utf-8')


def write_binary(path, parts):
    with path.open('wb') as stream:
        stream.write(b'STEVEM01')
        stream.write(struct.pack('<I', len(parts)))
        for part in parts:
            name=part['name'].encode('ascii')
            stream.write(struct.pack('<I',len(name))+name)
            stream.write(struct.pack('<3f',*part['pivot']))
            mesh=part['mesh']
            stream.write(struct.pack('<II',len(mesh['positions']),len(mesh['triangles'])))
            for p,n,uv,c in zip(mesh['positions'],mesh['normals'],mesh['uv'],mesh['colors']):
                stream.write(struct.pack('<12f',*(list(p)+list(n)+list(uv)+list(c))))
            stream.write(struct.pack('<'+'I'*len(mesh['triangles']),*mesh['triangles']))


def write_sword(texture, out, name='diamond_sword', held=True, display=None):
    positions, normals, uv, colors, triangles = [], [], [], [], []
    width, height = texture.size
    def opaque(x,y):
        return 0 <= x < width and 0 <= y < height and texture.getpixel((x,y))[3] > 0
    for y in range(height):
        for x in range(width):
            if not opaque(x,y): continue
            faces = cuboid((x-8,y-8,-.5),(1,1,1),(0,0))
            # Front and back are retained; internal pixel boundaries are omitted.
            keep = [True,True,not opaque(x+1,y),not opaque(x-1,y),not opaque(x,y-1),not opaque(x,y+1)]
            rgba = texture.getpixel((x,y))
            for (verts,_),visible in zip(faces,keep):
                if not visible: continue
                base=len(positions)
                positions.extend(verts)
                a=[verts[1][j]-verts[0][j] for j in range(3)]
                b=[verts[3][j]-verts[0][j] for j in range(3)]
                n=[a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0]]
                length=math.sqrt(sum(v*v for v in n))
                normals.extend([[-v/length for v in n]]*4)
                uv.extend([[(x+.5)/width,(y+.5)/height]]*4)
                colors.extend([[v/255 for v in rgba]]*4)
                triangles.extend([base,base+2,base+1,base,base+3,base+2])
    mesh=dict(positions=positions,normals=normals,uv=uv,colors=colors,triangles=triangles)
    # Java ItemInHandLayer + item/handheld thirdperson_righthand transform.
    display = display or dict(rotation=[0,-90,55],translation=[0,4,.5],scale=[.85,.85,.85])
    def hand(p,normal=False):
        x,y,z=p[0],-p[1],p[2]
        if not normal:
            x,y,z=[v*k for v,k in zip((x,y,z),display['scale'])]
        for axis in [2,1,0]:
            c,s=math.cos(math.radians(display['rotation'][axis])),math.sin(math.radians(display['rotation'][axis]))
            if axis==2: x,y=x*c-y*s,x*s+y*c
            elif axis==1: x,z=x*c+z*s,-x*s+z*c
            else: y,z=y*c-z*s,y*s+z*c
        if not normal:
            x+=display['translation'][0]+1
            y+=display['translation'][1]+2
            z+=display['translation'][2]-10
        return [-x,-z,-y]
    if held:
        mesh['positions']=[hand(p) for p in positions]
        mesh['normals']=[hand(n,True) for n in normals]
        mesh['triangles']=[v for i in range(0,len(triangles),3) for v in (triangles[i],triangles[i+2],triangles[i+1])]
    (out/(name+'.mesh.json')).write_text(json.dumps(mesh,separators=(',',':')),encoding='utf-8')
    write_binary(out/(name+'.mesh'),[dict(name=name,pivot=[0,0,0],mesh=mesh)])


def write_spell_icon(skin, out):
    face_uv, hat_uv = (8, 8, 16, 16), (40, 8, 48, 16)
    face = Image.alpha_composite(skin.crop(face_uv), skin.crop(hat_uv))
    icon = Image.new('RGBA', (256, 256))
    icon.alpha_composite(face.resize((224, 224), Image.Resampling.NEAREST), (16, 16))
    icon_path = out/'textures/steve_spell.png'
    icon.save(icon_path)
    # The native spell material supplies its own frame. Its glyph occupies the
    # centre of a larger canvas, so leave padding and clip inside that frame.
    small = Image.new('RGBA', (256, 256))
    small.alpha_composite(face.resize((152, 152), Image.Resampling.NEAREST), (52, 52))
    mask = Image.new('L', (1024, 1024))
    points = [(128,52),(194,90),(194,166),(128,204),(62,166),(62,90)]
    ImageDraw.Draw(mask).polygon([(x*4,y*4) for x,y in points], fill=255)
    small.putalpha(mask.resize((256,256), Image.Resampling.LANCZOS))
    small_path = out/'textures/steve_spell_glyph.png'
    small.save(small_path)
    manifest = dict(source='textures/steve.png',
        source_sha256=hashlib.sha256((out/'textures/steve.png').read_bytes()).hexdigest(),
        face_uv=face_uv, hat_uv=hat_uv, size=icon.size, filter='nearest',
        sha256=hashlib.sha256(icon_path.read_bytes()).hexdigest(),
        glyph=dict(file=small_path.name, hexagon=points,
                   sha256=hashlib.sha256(small_path.read_bytes()).hexdigest()))
    (out/'spell-icon-source.json').write_text(json.dumps(manifest, indent=2), encoding='utf-8')


def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('client',type=Path)
    ap.add_argument('output',type=Path)
    args=ap.parse_args()
    out=args.output
    (out/'textures').mkdir(parents=True,exist_ok=True)
    sources=[]
    with zipfile.ZipFile(args.client) as jar:
        version=json.loads(jar.read('version.json'))['id']
        def extract(path,target):
            data=jar.read('assets/minecraft/'+path)
            (out/target).write_bytes(data)
            sources.append(dict(resource=path,sha256=hashlib.sha256(data).hexdigest()))
            return data
        skin=Image.open(io.BytesIO(extract('textures/entity/player/wide/steve.png','textures/steve.png'))).convert('RGBA')
        if skin.size!=(64,64): raise ValueError('Expected the modern 64x64 Steve skin')
        write_spell_icon(skin,out)
        for item in ['diamond_sword','bow','bow_pulling_0','bow_pulling_1','bow_pulling_2','diamond_pickaxe','flint_and_steel','ender_pearl','arrow']:
            extract('textures/item/'+item+'.png','textures/'+item+'.png')
        write_sword(Image.open(out/'textures/diamond_sword.png').convert('RGBA'),out)
        for block in ['tnt_side','tnt_top','tnt_bottom','fire_0','fire_1']:
            extract('textures/block/'+block+'.png','textures/'+block+'.png')
        parts=[]
        for name,pivot,origin,size,uv,inflate in PARTS:
            mesh=mesh_from_faces(cuboid(origin,size,uv,inflate),skin)
            parts.append(dict(name=name,pivot=pivot,mesh=mesh))
        bundle=dict(schema=1,minecraftVersion=version,coordinateSystem='Minecraft model: X right, Y down, front -Z; feet at Y=24',pixelsPerBlock=16,playerRenderScale=.9375,parts=parts)
        (out/'steve.mesh.json').write_text(json.dumps(bundle,separators=(',',':')),encoding='utf-8')
        write_binary(out/'steve.mesh',parts)
        write_gltf(bundle,out)
        manifest=dict(minecraftVersion=version,clientSha256=hashlib.file_digest(args.client.open('rb'),'sha256').hexdigest(),resources=sources,geometryReference='Java 1.21.1 HumanoidModel and PlayerModel',parts=len(parts),vertices=sum(len(p['mesh']['positions']) for p in parts))
        (out/'sources.json').write_text(json.dumps(manifest,indent=2),encoding='utf-8')
        print(json.dumps(dict(version=version,parts=len(parts),vertices=manifest['vertices'],output=str(out))))


if __name__=='__main__': main()
