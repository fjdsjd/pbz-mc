"""Original 1.21.1 TNT/fire/particles; no runtime or deployment writes.

The pinned upstream STEVEM01 encoder and cube topology are reused under its
PolyForm Noncommercial license. Equal-color texel runs preserve source pixels.
"""
from __future__ import annotations
import importlib.util
import io
import json
import math
from pathlib import Path
from PIL import Image
from extend_original_item_icons import OriginalPack, ROOT, digest

OUT = ROOT/'assets/private/tnt'
EXTRACTOR = ROOT/'third_party/wukong-steve/tools/ExtractMinecraft.py'
COMMIT = '9f213556519dca4498fd46f02af6236ae121ecae'

def blank():
    return {key: [] for key in ('positions', 'normals', 'uv', 'colors', 'triangles')}

def runs(image):
    result = []
    for y in range(image.height):
        x = 0
        while x < image.width:
            color = image.getpixel((x, y)); end = x+1
            while end < image.width and image.getpixel((end, y)) == color:
                end += 1
            if color[3]:
                result.append([x, y, end-x, *color])
            x = end
    return result

def quad(mesh, points, normal, color, uv=None, double=False, reverse=False):
    base = len(mesh['positions'])
    mesh['positions'].extend(points)
    mesh['normals'].extend([normal]*4)
    mesh['uv'].extend(uv or [[0,0],[1,0],[1,1],[0,1]])
    mesh['colors'].extend([[c/255 for c in color]]*4)
    faces = [0,2,1,0,3,2] if reverse else [0,1,2,0,2,3]
    mesh['triangles'].extend(base+i for i in faces)
    if double:
        mesh['triangles'].extend(base+i for i in reversed(faces))

def cube(extract, textures, white=False):
    result = blank()
    for face, (vertices, _) in enumerate(extract.cuboid((-8,-8,-8), (16,16,16), (0,0))):
        texture = textures['top' if face==4 else 'bottom' if face==5 else 'side']
        # Same outward normal and UV orientation as the pinned upstream cube.
        a = [vertices[1][j]-vertices[0][j] for j in range(3)]
        b = [vertices[3][j]-vertices[0][j] for j in range(3)]
        cross = [a[1]*b[2]-a[2]*b[1], a[2]*b[0]-a[0]*b[2], a[0]*b[1]-a[1]*b[0]]
        length = math.sqrt(sum(v*v for v in cross)); normal = [-v/length for v in cross]
        rectangles = [[0,0,16,16,255,255,255,255]] if white else [[x,y,w,1,*c] for x,y,w,*c in runs(texture)]
        for x,y,w,h,*color in rectangles:
            coords = [(x/16,y/16),((x+w)/16,y/16),((x+w)/16,(y+h)/16),(x/16,(y+h)/16)]
            points = [[vertices[0][j]+s*a[j]+t*b[j] for j in range(3)] for s,t in coords]
            quad(result, points, normal, color, coords, reverse=True)
    return result

def fire_mesh(image, textured=False):
    mesh = blank()
    rectangles = [[0,0,16,16,255,255,255,255]] if textured else [[x,y,w,1,*c] for x,y,w,*c in runs(image)]
    for angle in (math.pi/4, 3*math.pi/4):
        c, s = math.cos(angle), math.sin(angle)
        for x,y,w,h,*color in rectangles:
            uv = [(x/16,y/16),((x+w)/16,y/16),((x+w)/16,(y+h)/16),(x/16,(y+h)/16)]
            points = [[-(u-.5)*16*s, -(0.5-v)*16, -(u-.5)*16*c] for u,v in uv]
            quad(mesh, points, [-c,0,s], color, uv, double=True)
    return mesh

def main():
    OUT.mkdir(parents=True, exist_ok=True)
    for sub in ('original', 'particles', 'fire'):
        (OUT/sub).mkdir(exist_ok=True)
    pack = OriginalPack('1.21.1'); dependencies = {}; retained = {}; outputs = []
    spec = importlib.util.spec_from_file_location('pinned_tnt_encoder', EXTRACTOR)
    extract = importlib.util.module_from_spec(spec); spec.loader.exec_module(extract)
    def source(member, destination=None):
        raw = pack.read(member, dependencies)
        if destination:
            path = OUT/destination; path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(raw)
            retained[member] = destination
        return raw
    def texture(name, destination=None):
        raw = source('assets/minecraft/textures/'+name+'.png', destination)
        return Image.open(io.BytesIO(raw)).convert('RGBA')
    def write_mesh(name, mesh, scale):
        path = OUT/(name+'.mesh'); path.parent.mkdir(exist_ok=True)
        part_name = path.stem
        extract.write_binary(path, [dict(name=part_name, pivot=[0,0,0], mesh=mesh)])
        points = [[-p[2]*scale,-p[0]*scale,-p[1]*scale] for p in mesh['positions']]
        outputs.append(dict(path=path.relative_to(OUT).as_posix(), sha256=digest(path.read_bytes()),
                            bytes=path.stat().st_size, vertices=len(points), indices=len(mesh['triangles']),
                            scale=scale, bounds_cm=[[min(p[i] for p in points),max(p[i] for p in points)] for i in range(3)]))

    # Retain exact original model/parents and unmodified texture PNGs.
    for model in ('tnt', 'cube_bottom_top', 'cube', 'block'):
        source('assets/minecraft/models/block/'+model+'.json', 'original/model_'+model+'.json')
    textures = {face:texture('block/tnt_'+face,'original/tnt_'+face+'.png') for face in ('top','bottom','side')}
    assert all(im.size==(16,16) for im in textures.values())
    write_mesh('tnt', cube(extract,textures), 6.25)
    write_mesh('tnt_flash', cube(extract,textures,True), 6.25)

    strip = texture('block/fire_0','original/fire_0.png')
    texture('block/fire_1','original/fire_1.png')
    metadata = json.loads(source('assets/minecraft/textures/block/fire_0.png.mcmeta','original/fire_0.png.mcmeta'))
    source('assets/minecraft/textures/block/fire_1.png.mcmeta','original/fire_1.png.mcmeta')
    assert strip.size==(16,512)
    for frame in range(32):
        write_mesh('fire/fire_'+str(frame), fire_mesh(strip.crop((0,16*frame,16,16*(frame+1)))),5.625)
    write_mesh('fire/fire_textured', fire_mesh(None,True),5.625)
    # One original strip texture and a two-plane, double-sided quad mesh enable
    # an optional 8-vertex UV frame update. Colored runs remain a ready fallback.
    fire = dict(lifetime_seconds=8, frame_count=32, tick_rate=20, scale=5.625,
                origin='center; spawn at support surface +45 cm for bottom Z=0',
                primary_mesh_pattern='fire/fire_{frame}.mesh',
                source_frame_order=metadata['animation']['frames'], baseline_frame_order=list(range(32)),
                textured=dict(texture='original/fire_0.png', mesh='fire/fire_textured.mesh',
                              vertices=8, indices=24, material='masked unlit, SpriteTexture, nearest filter',
                              uv_rule='u unchanged, v=(source_frame+local_v)/32; do not interpolate between frames'))

    # Atlas copies pixels without resampling; one texture/section can batch all
    # smoke and explosion quads. Runs are retained for the current color path.
    atlas = Image.new('RGBA',(256,128)); sprites = {}; animations = {}; index = 0
    for kind in ('smoke','explosion'):
        definition = json.loads(source('assets/minecraft/particles/'+kind+'.json','particles/'+kind+'.json'))
        animations[kind] = []
        for identifier in definition['textures']:
            name = identifier.split(':',1)[1]
            im = texture('particle/'+name,'particles/'+name+'.png')
            assert im.width<=32 and im.height<=32 and im.width==im.height
            x,y = (index%8)*32,(index//8)*32
            atlas.paste(im,(x,y))
            sprites[name] = dict(width=im.width,height=im.height,runs=runs(im),
                                 png='particles/'+name+'.png',
                                 source='assets/minecraft/textures/particle/'+name+'.png',
                                 source_sha256=digest((OUT/'particles'/(name+'.png')).read_bytes()),
                                 atlas_pixels=[x,y,im.width,im.height],
                                 atlas_uv=[x/256,y/128,(x+im.width)/256,(y+im.height)/128])
            animations[kind].append(name); index+=1
    atlas.save(OUT/'particles/atlas.png')
    particle_data = dict(schema=1,version='1.21.1',run_format='x,y,width,r,g,b,a; exact original sRGB 0..255',
        atlas=dict(path='particles/atlas.png',width=256,height=128,sha256=digest((OUT/'particles/atlas.png').read_bytes()),
                   filter='nearest',padding='unused transparent pixels; per-sprite UV rect'),
        animations=animations,sprites=sprites)
    raw=json.dumps(particle_data,separators=(',',':')).encode();(OUT/'particles.json').write_bytes(raw)

    item_manifest = json.loads((ROOT/'assets/private/item-models/manifest.json').read_text(encoding='utf8'))
    item_key = '1.21.1/assets/minecraft/models/item/flint_and_steel.json'
    flint = item_manifest['models'][item_key]
    flint_path = ROOT/'assets/private/item-models'/flint['path']
    manifest = dict(schema=1,format='STEVEM01',minecraft_version='1.21.1',namespace='minecraft',
        resource='minecraft:tnt',origin_sha256=pack.manifest['archive_sha256'],
        units=dict(tnt_scale=6.25,fire_scale=5.625,block_cm=100),
        geometry='TNT centered +/-8 recipe units; mesh_bundle maps (-z,-x,-y). Original per-face UV and colors; horizontal identical RGBA run merging.',
        tnt=dict(mesh='tnt.mesh',flash='tnt_flash.mesh',flash_note='Pinned black-monkey white geometry variant; Minecraft uses overlay UV instead.'),
        fire=fire,particles=dict(path='particles.json',sha256=digest(raw),frames=24),
        flint_and_steel=dict(path=flint_path.relative_to(ROOT).as_posix(),sha256=digest(flint_path.read_bytes()),
                             manifest='assets/private/item-models/manifest.json',key=item_key,display=flint['display'],copied=False),
        sources=[dict(path=k,sha256=digest(v),retained=retained.get(k)) for k,v in dependencies.items()],
        upstream=dict(commit=COMMIT,path=EXTRACTOR.relative_to(ROOT).as_posix(),sha256=digest(EXTRACTOR.read_bytes()),
                      license='PolyForm Noncommercial 1.0.0',notice='third_party/wukong-steve/NOTICE'),
        recipe_sha256=digest(Path(__file__).read_bytes()),outputs=outputs,
        private_local_only=True,runtime_tested=False,deployed=False)
    (OUT/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n',encoding='utf8')
    pack.archive.close()
    print(json.dumps(dict(meshes=len(outputs),mesh_bytes=sum(r['bytes'] for r in outputs),
        tnt_vertices=outputs[0]['vertices'],flash_vertices=outputs[1]['vertices'],particle_frames=24,
        atlas_size=atlas.size,fire_vertices_range=[min(r['vertices'] for r in outputs[2:-1]),max(r['vertices'] for r in outputs[2:-1])],
        manifest=str(OUT/'manifest.json'))))

if __name__=='__main__':
    main()
