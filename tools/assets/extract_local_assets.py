"""Private local conversion using the pinned upstream's mesh recipe.

No client assets are downloaded or included in distributable source. This first
stage covers dirt/stone, their ten mining stages, and Steve's twelve body parts.
"""
from __future__ import annotations
import argparse
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import zipfile
from PIL import Image

from asset_paths import ROOT
BASELINE='9f213556519dca4498fd46f02af6236ae121ecae'

def combine(meshes):
    result={key:[] for key in ('positions','normals','uv','colors','triangles')}
    for mesh in meshes:
        offset=len(result['positions'])
        for key in ('positions','normals','uv','colors'): result[key].extend(mesh[key])
        result['triangles'].extend(i+offset for i in mesh['triangles'])
    return result

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--client',type=Path,required=True)
    parser.add_argument('--output',type=Path,default=ROOT/'assets/private/minecraft-1.21.1')
    args=parser.parse_args()
    upstream=ROOT/'third_party/wukong-steve/tools/ExtractMinecraft.py'
    spec=importlib.util.spec_from_file_location('pinned_mesh_converter',upstream)
    recipe=importlib.util.module_from_spec(spec)
    spec.loader.exec_module(recipe)
    output=args.output.resolve()
    # Outputs are deliberately isolated from the user's Minecraft install.
    if output==args.client.resolve().parent or args.client.resolve().parent in output.parents:
        raise ValueError('Output must be outside the Minecraft version directory')
    output.mkdir(parents=True,exist_ok=True)
    (output/'textures').mkdir(exist_ok=True)
    manifest={'schema':1,'upstream_commit':BASELINE,'private_local_assets':True,
      'client_sha256':hashlib.sha256(args.client.read_bytes()).hexdigest(),
      'recipe_sha256':hashlib.sha256(upstream.read_bytes()).hexdigest(),'resources':[],'meshes':[]}
    def save_mesh(name,parts):
        path=output/(name+'.mesh')
        recipe.write_binary(path,parts)
        manifest['meshes'].append({'name':name,'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),
            'parts':len(parts),'vertices':sum(len(p['mesh']['positions']) for p in parts),
            'indices':sum(len(p['mesh']['triangles']) for p in parts)})
    with zipfile.ZipFile(args.client) as jar:
        version=json.loads(jar.read('version.json'))['id']
        if version!='1.21.1': raise ValueError(f'Expected baseline client 1.21.1, got {version}')
        manifest['minecraft_version']=version
        def texture(resource,name):
            raw=jar.read('assets/minecraft/textures/'+resource+'.png')
            (output/'textures'/(name+'.png')).write_bytes(raw)
            image=Image.open(io.BytesIO(raw)).convert('RGBA')
            manifest['resources'].append({'resource':resource+'.png','sha256':hashlib.sha256(raw).hexdigest(),
                'size':list(image.size),'alpha_range':list(image.getchannel('A').getextrema()),'colors':len(image.getcolors(65536))})
            return image
        cracks=[texture(f'block/destroy_stage_{i}',f'destroy_stage_{i}') for i in range(10)]
        faces=recipe.cuboid((-8,-8,-8),(16,16,16),(0,0))
        for name in ('dirt','stone'):
            image=texture('block/'+name,name)
            assert image.size==(16,16)
            def block(tex):
                mesh=combine([recipe.mesh_from_faces([(verts,(0,0,16,16))],tex) for verts,_ in faces])
                return [dict(name=name,pivot=[0,0,0],mesh=mesh)]
            save_mesh(name,block(image))
            for stage,crack in enumerate(cracks): save_mesh(f'{name}_crack_{stage}',block(Image.alpha_composite(image,crack)))
        skin=texture('entity/player/wide/steve','steve')
        assert skin.size==(64,64)
        parts=[dict(name=name,pivot=pivot,mesh=recipe.mesh_from_faces(recipe.cuboid(origin,size,uv,inflate),skin))
            for name,pivot,origin,size,uv,inflate in recipe.PARTS]
        save_mesh('steve',parts)
    (output/'sources.json').write_text(json.dumps(manifest,indent=2,ensure_ascii=False),encoding='utf-8')
    print(json.dumps({'output':str(output),'version':version,'mesh_files':len(manifest['meshes']),
      'resources':len(manifest['resources']),'client_sha256':manifest['client_sha256']},ensure_ascii=False))

if __name__=='__main__': main()
