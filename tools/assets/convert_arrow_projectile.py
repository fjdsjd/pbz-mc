"""Pinned upstream ArrowRenderer geometry, sampled from local original MC art.

Derived from wukong-steve ExtractMinecraftItems.py, PolyForm Noncommercial;
retain third_party/wukong-steve/NOTICE. No invented projectile artwork.
"""
import importlib.util, io, json, math
from pathlib import Path
from PIL import Image
from extend_original_item_icons import OriginalPack, ROOT, digest
from mc_generated_geometry import mesh_bytes

source=ROOT/'third_party/wukong-steve/tools/ExtractMinecraft.py'
spec=importlib.util.spec_from_file_location('pinned_mc_extract',source)
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
pack=OriginalPack('1.21.1');dependencies={}
texture_path='assets/minecraft/textures/entity/projectiles/arrow.png'
raw=pack.read(texture_path,dependencies);pack.archive.close()
texture=Image.open(io.BytesIO(raw)).convert('RGBA');assert texture.size==(32,32)
faces=[([(-7,-2,-2),(-7,-2,2),(-7,2,2),(-7,2,-2)],(0,5,5,5))]
for angle in (0,90):
    c,s=math.cos(math.radians(angle)),math.sin(math.radians(angle))
    faces.append(([(x,y*c,y*s) for x,y in [(-8,-2),(8,-2),(8,2),(-8,2)]],(0,0,16,5)))
result={key:[] for key in ('positions','normals','uv','colors','triangles')}
for vertices,uv in faces:
    mesh=module.mesh_from_faces([(vertices,uv)],texture)
    def axis(point,normal=False):
        x,y,z=point
        if not normal:x-=4
        return [-(y-z)/math.sqrt(2),-(y+z)/math.sqrt(2),-x]
    mesh['positions']=[axis(p) for p in mesh['positions']]
    mesh['normals']=[axis(p,True) for p in mesh['normals']]
    mesh['triangles'] += [v for i in range(0,len(mesh['triangles']),3)
        for v in (mesh['triangles'][i],mesh['triangles'][i+2],mesh['triangles'][i+1])]
    offset=len(result['positions'])
    for key in ('positions','normals','uv','colors'):result[key].extend(mesh[key])
    result['triangles'].extend(i+offset for i in mesh['triangles'])
root=ROOT/'assets/private/item-models';target='minecraft/1.21.1/entity/arrow_projectile.mesh'
output=root/target;output.parent.mkdir(parents=True,exist_ok=True)
binary=mesh_bytes(result);output.write_bytes(binary)
manifest_path=root/'manifest.json';manifest=json.loads(manifest_path.read_text(encoding='utf-8'))
records={r['path']:r for r in manifest['outputs']}
records[target]=dict(path=target,sha256=digest(binary),bytes=len(binary),source_texture=texture_path,
    source_sha256=digest(raw),geometry_source='wukong-steve@9f213556519dca4498fd46f02af6236ae121ecae/ExtractMinecraftItems.py:234-251')
manifest['outputs']=list(records.values());manifest.setdefault('projectiles',{})['arrow']=target
manifest_path.write_text(json.dumps(manifest,ensure_ascii=False,indent=2),encoding='utf-8')
print(json.dumps(dict(path=str(output),vertices=len(result['positions']),sha256=digest(binary))))
