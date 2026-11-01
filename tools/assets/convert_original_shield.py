"""Original Java shield entity (plate + handle), display states and GUI render.

Geometry/UV recipe: pinned wukong-steve ExtractMinecraftItems.py:147-163,
derived from Minecraft ShieldModel. Keep third_party/wukong-steve/NOTICE.
Private original resources are verified against the user's retained client.
"""
import importlib.util
import io
import json
import math
from pathlib import Path
from PIL import Image, ImageDraw
from extend_original_item_icons import OriginalPack, ROOT, digest
from convert_original_item_models import CONTEXTS, display_transform
from mc_generated_geometry import mesh_bytes


def main():
    source = ROOT/'third_party/wukong-steve/tools/ExtractMinecraft.py'
    spec = importlib.util.spec_from_file_location('pinned_mc_extract', source)
    extract = importlib.util.module_from_spec(spec); spec.loader.exec_module(extract)
    pack = OriginalPack('1.21.1'); dependencies = {}
    texture_path = 'assets/minecraft/textures/entity/shield_base_nopattern.png'
    texture = Image.open(io.BytesIO(pack.read(texture_path, dependencies))).convert('RGBA')
    assert texture.size == (64,64)
    faces = extract.cuboid((-6,-11,-2), (12,22,1), (0,0))
    faces += extract.cuboid((-1,-3,-1), (2,6,6), (26,0))
    mesh = extract.mesh_from_faces(faces, texture)
    # Entity renderer flips Y/Z, then ItemRenderer subtracts the half-block.
    # mesh_bundle maps recipe(x,-y,-z) to UE(z,-x,y). No display is baked.
    mesh['positions'] = [[x-8,y+8,z+8] for x,y,z in mesh['positions']]
    root = ROOT/'assets/private/item-models'
    target = 'minecraft/1.21.1/entity/shield.mesh'
    binary = mesh_bytes(mesh); output = root/target
    output.parent.mkdir(parents=True,exist_ok=True); output.write_bytes(binary)
    manifest_path = root/'manifest.json'
    manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
    models = {}
    for state in ('shield','shield_blocking'):
        path = 'assets/minecraft/models/item/'+state+'.json'
        original = json.loads(pack.read(path, dependencies))
        display = {context:display_transform(original.get('display',{}).get(context,{})) for context in CONTEXTS}
        key = '1.21.1/'+path
        models[state] = key
        manifest['models'][key] = dict(path=target,minecraft_version='1.21.1',model='minecraft:item/'+state,
            geometry='shield_entity',vertices=len(mesh['positions']),indices=len(mesh['triangles']),
            display=display,gui_light=original['gui_light'],overrides=original.get('overrides',[]),
            dependencies=['1.21.1/'+p for p in (texture_path,path)])
    manifest['items']['pbzmc:shield'] = dict(resource='minecraft:shield',minecraft_version='1.21.1',
        contexts={c:dict(model=models['shield'],conditions=[]) for c in CONTEXTS},
        variants=[dict(base_model=models['shield'],predicate={'blocking':1},model=models['shield_blocking'],
                       model_resource='item/shield_blocking')],item_dependencies=[])
    manifest['unavailable'].pop('pbzmc:shield',None)
    records = {r['path']:r for r in manifest['outputs']}
    records[target] = dict(path=target,sha256=digest(binary),bytes=len(binary),geometry='original-shield-plate-and-handle')
    manifest['outputs'] = list(records.values())
    sources = {r['version']+'/'+r['path']:r for r in manifest['sources']}
    for path,raw in dependencies.items(): sources['1.21.1/'+path] = dict(version='1.21.1',path=path,sha256=digest(raw))
    manifest['sources'] = list(sources.values())
    manifest.setdefault('recipe_sha256',{})[Path(__file__).name] = digest(Path(__file__).read_bytes())
    manifest_path.write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')

    # Render the complete original mesh through its GUI display transform.
    # This keeps the actual perspective and handle; never crop the front PNG.
    d = manifest['models'][models['shield']]['display']['gui']
    points = []
    for px,py,pz in mesh['positions']:
        x,y,z = (v*s for v,s in zip((px,-py,-pz),d['scale']))
        for axis in (2,1,0):
            c,s = math.cos(math.radians(d['rotation'][axis])),math.sin(math.radians(d['rotation'][axis]))
            if axis == 2: x,y = x*c-y*s,x*s+y*c
            elif axis == 1: x,z = x*c+z*s,-x*s+z*c
            else: y,z = y*c-z*s,y*s+z*c
        points.append((x+d['translation'][0],y+d['translation'][1],z+d['translation'][2]))
    image = Image.new('RGBA',(64,64)); draw = ImageDraw.Draw(image)
    # Fit this complete GUI projection inside the host icon tile. The original
    # model's geometry, relative proportions and GUI rotation are preserved.
    xs=[p[0] for p in points];ys=[p[1] for p in points]
    scale=56/max(max(xs)-min(xs),max(ys)-min(ys));cx=(min(xs)+max(xs))/2;cy=(min(ys)+max(ys))/2
    for i in sorted(range(0,len(points),4),key=lambda i:sum(points[j][2] for j in range(i,i+4))):
        draw.polygon([(32+(points[j][0]-cx)*scale,32-(points[j][1]-cy)*scale) for j in range(i,i+4)],
                     fill=tuple(round(v*255) for v in mesh['colors'][i]))
    ui = ROOT/'assets/private/minecraft-1.21.1/ui'
    icon = 'original/minecraft/1.21.1/rendered/shield.png'
    icon_path = ui/icon; icon_path.parent.mkdir(parents=True,exist_ok=True);image.save(icon_path)
    ui_path = ui/'manifest.json'; data = json.loads(ui_path.read_text(encoding='utf-8'))
    records = {r['path']:r for r in data['outputs']}
    records[icon] = dict(path=icon,sha256=digest(icon_path.read_bytes()),source='minecraft-original:1.21.1:'+texture_path,
        source_sha256=digest(dependencies[texture_path]),operation='original-entity-gui-render',size=[64,64],
        minecraft_version='1.21.1',namespace='minecraft',recipe_sha256=digest(Path(__file__).read_bytes()))
    data['outputs'] = list(records.values());data['item_icons']['pbzmc:shield'] = icon
    data['item_icon_sources']['pbzmc:shield'] = dict(minecraft_version='1.21.1',resource='minecraft:shield',
        geometry='ShieldModel plate and handle',display='item/shield.json#display.gui',conditions=[])
    data['missing_item_icons'] = [v for v in data['missing_item_icons'] if v!='pbzmc:shield']
    data['incomplete_item_visuals'].pop('pbzmc:shield',None)
    ui_path.write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    pack.archive.close()
    print(json.dumps(dict(mesh=target,vertices=len(mesh['positions']),indices=len(mesh['triangles']),icon=icon)))


if __name__ == '__main__': main()
