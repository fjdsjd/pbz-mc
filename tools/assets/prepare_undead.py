"""Bake the pinned Bedrock adult models into small articulated, textured meshes.

Preserve the vanilla bone hierarchy and layer inheritance. Each source cube
costs at most six quads, independent of the resolution of its original skin.
"""
import hashlib
import importlib.util
import io
import json
import math
from pathlib import Path
import zipfile
from copy import deepcopy

from PIL import Image
from asset_paths import ROOT
from vanilla_mob_assets import MOB_LAYERS, PARENT_MODELS
from molang_compile import read_json

LAYERS = {
    'zombie': [('zombie', 'zombie/zombie.png')],
    'husk': [('husk', 'zombie/husk.png')],
    'drowned': [('drowned', 'zombie/drowned.tga')],
    'zombie_villager': [('zombie_villager_v2', 'zombie_villager2/zombie-villager.png')],
    'zombified_piglin': [('piglin', 'piglin/zombie_piglin.png')],
    'skeleton': [('skeleton', 'skeleton/skeleton.png')],
    'stray': [('stray', 'skeleton/stray.png'), ('stray_armor', 'skeleton/stray_overlay.png')],
    'bogged': [('bogged', 'skeleton/bogged.png'), ('bogged_armor', 'skeleton/bogged_clothes.png')],
    'parched': [('parched', 'parched/parched.png')],
    'wither_skeleton': [('wither_skeleton', 'skeleton/wither_skeleton.png')],
    'zoglin': [('hoglin', 'zoglin/zoglin.png')],
    'zombie_horse': [('horse_v3', 'horse2/horse_zombie.png')],
    'skeleton_horse': [('horse_v3', 'horse2/horse_skeleton.png')],
    'camel_husk': [('camel_husk', 'camel_husk/camel_husk.png')],
    'zombie_nautilus': [('nautilus', 'nautilus/zombie_nautilus.png')],
    'phantom': [('phantom', 'phantom.tga')],
    'wither': [('wither_boss', 'wither_boss/wither.png')],
    'trident': [('trident', 'trident.png')],
    'skull': [('wither_skull', 'wither_boss/wither.png')],
}
VILLAGER_CLOTH = 'textures/entity/zombie_villager2/biomes/biome-plains-zombie.png'
GEAR = {'skeleton': 'bow', 'stray': 'bow', 'bogged': 'bow', 'parched': 'bow',
        'zombified_piglin': 'golden_sword', 'wither_skeleton': 'stone_sword',
        'pillager':'crossbow_standby', 'piglin':'crossbow_standby', 'vindicator':'iron_axe',
        'piglin_brute':'golden_axe', 'vex':'iron_sword', 'illusioner':'bow'}
JOINTS = {}
for joint, aliases in {
    'right_arm': 'rightarm right_arm arm_right', 'left_arm': 'leftarm left_arm arm_left',
    'right_leg': 'rightleg legbr leg_back_right right_hind_leg right_leg leg0 leg1 hindleg1 legbackright',
    'left_leg': 'leftleg legbl leg_back_left left_hind_leg left_leg leg2 hindleg2 legbackleft',
    'front_right': 'legfr leg_front_right right_front_leg leg3 frontleg1 legfrontright',
    'front_left': 'legfl leg_front_left left_front_leg leg4 frontleg2 legfrontleft',
    'wing_left': 'wing0 leftwing left_wing wingl wing_left', 'wing_right': 'wing1 rightwing right_wing wingr wing_right',
    'tail': 'tail tail1 tail_fin tailfin', 'head': 'head neck head1',
}.items():
    JOINTS.update(dict.fromkeys(aliases.split(), joint))
HIDDEN = set('saddle reins reinsl reinsr bridle bitl bitr bagl bagr muleearl muleearr'.split())


def geometry_path(name):
    return 'models/entity/' + name + '.geo.json'


def texture_path(name):
    return 'textures/entity/' + name


def inputs():
    return sorted({geometry_path(g) for layers in LAYERS.values() for g, _ in layers}
                  | {texture_path(t) for layers in LAYERS.values() for _, t in layers}
                  | {p for layers in MOB_LAYERS.values() for g,_,t in layers for p in (g,t) if not p.startswith('@')}
                  | set(PARENT_MODELS.values()) | {VILLAGER_CLOTH,'textures/entity/villager2/biomes/biome_plains.png'})


def layout_at(source, path, ident):
    data=read_json((source/path).read_bytes())
    if 'minecraft:geometry' in data:
        return next(row for row in data['minecraft:geometry'] if not ident or row['description']['identifier']==ident)
    key=next(k for k in data if k.startswith('geometry.') and (not ident or k.split(':')[0]==ident))
    child=data[key]
    if ':' not in key:
        return child
    parent_id=key.split(':')[1]
    same=any(k.split(':')[0]==parent_id for k in data)
    parent=layout_at(source,path if same else PARENT_MODELS[parent_id],parent_id)
    bones={b['name']:b for b in parent.get('bones',[])}
    for bone in child.get('bones',[]):
        before=bones.get(bone['name'],{})
        bones[bone['name']]={**before,**bone,'cubes':before.get('cubes',[])+bone.get('cubes',[])}
    return {**parent,**child,'bones':list(bones.values())}


def faces(geometry,cube,bone,origin):
    uv=cube['uv']
    quads=geometry.cuboid(origin,cube['size'],[0,0] if isinstance(uv,dict) else uv,cube.get('inflate',bone.get('inflate',0)))
    if not isinstance(uv,dict):
        yield from quads
        return
    for side,(points,(_,_,w,h)) in zip(('north','south','east','west','up','down'),quads):
        if side in uv:
            face=uv[side]
            yield points, (*face['uv'],*face.get('uv_size',[w,h]))


def rotate(p, pivot, angles):
    if not any(angles):
        return p
    x, y, z = [a-b for a, b in zip(p, pivot)]
    # Bedrock's rotation convention, before our coordinate basis conversion.
    ax, ay, az = map(math.radians, (-angles[0],angles[1],-angles[2]))
    y, z = y*math.cos(ax)-z*math.sin(ax), y*math.sin(ax)+z*math.cos(ax)
    x, z = x*math.cos(ay)+z*math.sin(ay), -x*math.sin(ay)+z*math.cos(ay)
    x, y = x*math.cos(az)-y*math.sin(az), x*math.sin(az)+y*math.cos(az)
    return [x+pivot[0], y+pivot[1], z+pivot[2]]


def mesh():
    return {k: [] for k in ('positions', 'normals', 'uv', 'colors', 'triangles')}


def quad(part, points, uvs):
    a, b = [[q[i]-points[0][i] for i in range(3)] for q in (points[1], points[3])]
    normal = [a[(i+1)%3]*b[(i+2)%3]-a[(i+2)%3]*b[(i+1)%3] for i in range(3)]
    length = math.sqrt(sum(n*n for n in normal))
    if length < 1e-7:
        return
    i = len(part['positions'])
    part['positions'].extend(points)
    part['normals'].extend([[n/length for n in normal]]*4)
    part['uv'].extend(uvs)
    part['colors'].extend([(1, 1, 1, 1)]*4)
    part['triangles'].extend(i+x for x in (0,1,2,0,2,3,2,1,0,3,2,0))


SPRITES={'flame':'item/fire_charge','fireball':'item/fire_charge','dragon_breath':'entity/enderdragon/dragon_fireball',
         'snowball':'item/snowball','potion':'item/splash_potion','sonic':'particle/sonic_boom_0',
         'beam':'entity/guardian/guardian_beam'}


def sprite(name,jar,texture,geometry,out):
    im=Image.open(io.BytesIO(jar.read('assets/minecraft/textures/'+texture+'.png'))).convert('RGBA')
    if name=='potion':
        overlay=Image.open(io.BytesIO(jar.read('assets/minecraft/textures/item/potion_overlay.png'))).convert('RGBA')
        tint=Image.new('RGBA',overlay.size,(89,58,143,0));tint.putalpha(overlay.getchannel('A'))
        tint.alpha_composite(im);im=tint
    # The host now rebuilds the GPU resource with point sampling. Keep the
    # original pixel density instead of spending 16x texels to mask filtering.
    im.save(out/(name+'.png'))
    part=mesh();uv=[(0,0),(1,0),(1,1),(0,1)]
    if name=='beam':
        quad(part,[(-.5,0,0),(.5,0,0),(.5,0,-1),(-.5,0,-1)],uv)
        quad(part,[(0,-.5,0),(0,.5,0),(0,.5,-1),(0,-.5,-1)],uv)
    else:
        quad(part,[(-.5,-.5,0),(.5,-.5,0),(.5,.5,0),(-.5,.5,0)],uv)
        quad(part,[(0,-.5,-.5),(0,-.5,.5),(0,.5,.5),(0,.5,-.5)],uv)
    geometry.write_binary(out/(name+'.mesh'),[{'name':'body','pivot':(0,0,0),'mesh':part}])
    def record(ext):
        file=out/(name+ext);raw=file.read_bytes()
        return {'path':file.name,'bytes':len(raw),'sha256':hashlib.sha256(raw).hexdigest()}
    return {'mesh':record('.mesh'),'texture':record('.png'),'bottom':-.5,'top':.5}


def build(kind, source, jar, geometry, out,reference=None):
    def picture(path):
        if path.startswith('@'):
            return Image.open(io.BytesIO(jar.read('assets/minecraft/textures/'+path[1:]))).convert('RGBA')
        return Image.open(source/path).convert('RGBA')
    images, layers = [], []
    chosen=MOB_LAYERS[kind] if kind in MOB_LAYERS else [(geometry_path(g),None,texture_path(t)) for g,t in LAYERS[kind]]
    if reference and kind in reference['mobs']:chosen=reference['mobs'][kind]['layers']
    for geo,ident,tex in chosen:
        layout=layout_at(source,geo,ident)
        if kind=='ender_dragon':
            # DragonModel's native renderer instantiates the same spine mesh
            # five times for the neck and twelve times for the tail. Bedrock's
            # source controllers address these instances, not the template.
            layout=deepcopy(layout);bones={b['name']:b for b in layout['bones']}
            spine=bones.pop('neck')
            for prefix,count in (('neck',5),('tail',12)):
                for i in range(1,count+1):
                    bone=deepcopy(spine);bone['name']=prefix+str(i);bone['parent']='root';bones[bone['name']]=bone
            for name,bone in bones.items():
                if name=='root':
                    bone['rotation']=[0,180,0] # native dragon renderer's facing basis
                elif name in ('head','body'):bone['parent']='root'
                elif name.startswith(('wing','rear','front')):
                    side='1'if name.endswith('1')else '';part=name[:-1]if side else name
                    parent={'wing':'body','wingtip':'wing','rearleg':'body','rearlegtip':'rearleg',
                            'rearfoot':'rearlegtip','frontleg':'body','frontlegtip':'frontleg','frontfoot':'frontlegtip'}[part]
                    bone['parent']=parent+side if parent!='body'else parent
            layout['bones']=list(bones.values())
        img=picture(tex)
        # Bedrock color-mask materials use alpha for dye selection, not
        # transparency. Sheep's face/hooves have alpha=3 and must stay opaque.
        # Keep cutouts intact for ordinary skins and separate overlay layers.
        material=(reference or {}).get('mobs',{}).get(kind,{}).get('material')
        if not layers and material in ('entity','entity_nocull','entity_change_color','sheep'):
            img.putalpha(255)
        if kind == 'zombie_villager':
            img.alpha_composite(picture(VILLAGER_CLOTH))
        if kind=='villager':
            img.alpha_composite(picture('textures/entity/villager2/biomes/biome_plains.png'))
        layers.append(layout)
        images.append(img)
    if kind=='sulfur_cube':
        # Spawn the vanilla hot archetype with a magma block visible inside its outer shell.
        original=picture('@block/magma.png')
        tile=original.crop((0,0,original.width,original.width))
        faces_uv={side:{'uv':[0,0],'uv_size':[16,16]} for side in ('north','south','west','east','up','down')}
        layers.append({'texturewidth':16,'textureheight':16,'bones':[{'name':'magma','cubes':[
            {'origin':[-6,3,-6],'size':[12,12,12],'uv':faces_uv}]}]})
        images.append(tile)
    if kind in GEAR:
        images.append(Image.open(io.BytesIO(jar.read('assets/minecraft/textures/item/'+GEAR[kind]+'.png'))).convert('RGBA'))
    if kind == 'drowned':
        images.append(picture(texture_path('trident.png')))
    width = 1 << (max(im.width for im in images)-1).bit_length()
    height = 1 << (sum(im.height for im in images)-1).bit_length()
    atlas = Image.new('RGBA', (width, height))
    offsets = []
    y = 0
    for image in images:
        offsets.append(y)
        atlas.paste(image, (0,y))
        y += image.height
    groups, pivots,rig = {}, {},{}
    zero = (0,0,0)
    for layer, layout in enumerate(layers):
        bones = {b['name']: b for b in layout['bones']}
        image = images[layer]
        desc = layout.get('description', layout)
        tw = desc.get('texture_width', desc.get('texturewidth', image.width))
        th = desc.get('texture_height', desc.get('textureheight', image.height))
        for bone in bones.values():
            chain = [bone]
            while chain[-1].get('parent') in bones:
                chain.append(bones[chain[-1]['parent']])
            if bone.get('neverRender') or any(b['name'].lower() in HIDDEN for b in chain):
                continue
            anchor=bone
            group=bone['name'].lower()
            if kind in ('skull','trident','fang','bullet','gust','spit'):
                group,anchor='body',None
            def posed(point, parents):
                for b in parents:
                    point=rotate(point,b.get('pivot',zero),b.get('rotation',zero))
                return point
            if group not in pivots:
                pivot=anchor.get('pivot',zero)if anchor else zero
                pivots[group] = (pivot[0],-pivot[1],pivot[2])
                rig[group]={'parent':bone.get('parent','').lower()if anchor else '',
                    'pivot':pivot,'rotation':bone.get('rotation',zero)if anchor else zero}
                groups[group]=mesh()
            for cube in bone.get('cubes',[]):
                x,y,z=cube['origin'];w,h,d=cube['size']
                origin=(x,-y-h,z)
                for vertices,(u,v,uw,vh) in faces(geometry,cube,bone,origin):
                    points=[]
                    for vx,vy,vz in vertices:
                        if cube.get('mirror',bone.get('mirror',False)):
                            vx=2*x+w-vx
                        # Omitted cube pivot means its uninflated centre, not
                        # the world origin (notably the modern chicken body).
                        centre=[x+w/2,y+h/2,z+d/2]
                        pt=rotate([vx,-vy,vz],cube.get('pivot',centre),cube.get('rotation',zero))
                        pt=rotate(pt,bone.get('pivot',zero),bone.get('bind_pose_rotation',zero))
                        px,py,pz=pt if anchor else posed(pt,chain)
                        points.append((px,-py,pz))
                    uv=[((u+s*uw)*image.width/tw/width,(offsets[layer]+(v+t*vh)*image.height/th)/height)
                        for s,t in ((0,0),(1,0),(1,1),(0,1))]
                    quad(groups.setdefault(group,mesh()),points,uv)
    # Weapons in the animated right hand use original item sprites or the
    # original three-dimensional trident mesh. The atlas also supplies the
    # cutout, including the open centre of the bow.
    if kind in GEAR:
        layer=len(images)-1;im=images[layer]
        grip=next((b for b in groups if JOINTS.get(b)=='right_arm'),'body')
        x,y,z=pivots[grip]
        pts=[(x,y+12-b,z+1-a) for a,b in ((-7,11),(7,11),(7,-3),(-7,-3))]
        quad(groups[grip],pts,[(s*im.width/width,(offsets[layer]+t*im.height)/height)
            for s,t in ((0,0),(1,0),(1,1),(0,1))])
    elif kind == 'drowned':
        spec=json.loads((source/geometry_path('trident')).read_bytes())['minecraft:geometry'][0]
        grip=next(b for b in groups if JOINTS.get(b)=='right_arm');x,y,z=pivots[grip]
        for cube in spec['bones'][0]['cubes']:
            a,b,c=cube['origin'];w,h,d=cube['size']
            for points,(u,v,uw,vh) in geometry.cuboid((a,-b-h,c),(w,h,d),cube['uv'],cube.get('inflate',0)):
                quad(groups[grip],[(x+vx,y+12+vz,z+vy+12) for vx,vy,vz in points],
                     [((u+s*uw)/width,(offsets[-1]+v+t*vh)/height) for s,t in ((0,0),(1,0),(1,1),(0,1))])
    parts=[]
    top,bottom=math.inf,-math.inf
    for name,part in groups.items():
        pivot=pivots[name]
        for idx,p in enumerate(part['positions']):
            q=[p[0],-p[1],p[2]];node=name;seen=set()
            while node in rig:
                assert node not in seen,'cyclic-mob-rig';seen.add(node)
                bone=rig[node];q=rotate(q,bone['pivot'],bone['rotation']);node=bone['parent']
            top=min(top,-q[1]);bottom=max(bottom,-q[1])
            part['positions'][idx]=[a-b for a,b in zip(p,pivot)]
        parts.append({'name':name,'pivot':pivot,'mesh':part})
    assert parts and top<bottom
    geometry.write_binary(out/(kind+'.mesh'),parts)
    # All instances share an atlas at original pixel density. Point sampling
    # is enforced on the native GPU resource when that atlas is first loaded.
    atlas.save(out/(kind+'.png'))
    def record(ext):
        name=kind+ext;raw=(out/name).read_bytes()
        return {'path':name,'bytes':len(raw),'sha256':hashlib.sha256(raw).hexdigest()}
    return {'mesh':record('.mesh'),'texture':record('.png'),'bottom':-bottom,'top':-top,'rig':rig}


def render(work):
    tool=work/'third_party/wukong-steve/tools/ExtractMinecraft.py'
    spec=importlib.util.spec_from_file_location('minecraft_cuboids',tool)
    geometry=importlib.util.module_from_spec(spec);spec.loader.exec_module(geometry)
    output=work/'assets/private/undead';output.mkdir(parents=True,exist_ok=True)
    reference=json.loads((work/'src/content/mob_visual_reference.json').read_bytes())
    for path in reference['files']:
        if path.startswith('models/'):
            data=read_json((work/'inputs/undead'/path).read_bytes())
            for key in data:
                if key.startswith('geometry.'):PARENT_MODELS[key.split(':')[0]]=path
            for row in data.get('minecraft:geometry',[]):PARENT_MODELS[row['description']['identifier']]=path
    with zipfile.ZipFile(work/'inputs/26.3.jar') as jar:
        manifest={name:build(name,work/'inputs/undead',jar,geometry,output,reference) for name in (*LAYERS,*MOB_LAYERS)}
        for name,texture in SPRITES.items():
            manifest[name]=sprite(name,jar,texture,geometry,output)
    (output/'manifest.json').write_bytes((json.dumps(manifest,indent=2)+'\n').encode())


if __name__=='__main__':
    render(ROOT)
