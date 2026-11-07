"""Minecraft's wind-charge projectile uses two independently rotating textured bones."""
import hashlib
import importlib.util
import json
import math
import zipfile

from asset_paths import ROOT
from convert_spear_sounds import convert
from mc_generated_geometry import mesh_bytes


def render(jar, output, extractor):
    spec = importlib.util.spec_from_file_location('pbzmc_wind_faces', extractor)
    geometry = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(geometry)
    output.mkdir(parents=True, exist_ok=True)
    source = 'assets/minecraft/textures/entity/projectiles/wind_charge.png'
    with zipfile.ZipFile(jar) as archive:
        texture = archive.read(source)
    assert texture[:8] == b'\x89PNG\r\n\x1a\n' and tuple(int.from_bytes(texture[i:i+4], 'big') for i in (16,20)) == (64,32)
    (output/'wind_charge.png').write_bytes(texture)
    digests = {'wind_charge.png': hashlib.sha256(texture).hexdigest()}
    bones = {'core': [((-2,-2,-2), (4,4,4), (0,0))],
             'shell': [((-4,-1,-4), (8,2,8), (15,20)), ((-3,-2,-3), (6,4,6), (0,9))]}
    for name, boxes in bones.items():
        mesh = {key: [] for key in ('positions','normals','uv','colors','triangles')}
        for origin, size, uv in boxes:
            for vertices, (u,v,w,h) in geometry.cuboid(origin, size, uv):
                base = len(mesh['positions'])
                a = [vertices[1][i]-vertices[0][i] for i in range(3)]
                b = [vertices[3][i]-vertices[0][i] for i in range(3)]
                n = [a[(i+1)%3]*b[(i+2)%3]-a[(i+2)%3]*b[(i+1)%3] for i in range(3)]
                normal = [c/math.sqrt(sum(x*x for x in n)) for c in n]
                mesh['positions'].extend(vertices)
                mesh['normals'].extend([normal]*4)
                mesh['colors'].extend([(1,1,1,1)]*4)
                mesh['uv'].extend([((u+s*w)/64, (v+t*h)/32) for s,t in ((0,0),(1,0),(1,1),(0,1))])
                mesh['triangles'].extend(base+i for i in (0,1,2,0,2,3,2,1,0,3,2,0))
        raw = mesh_bytes(mesh)
        path = name + '.mesh'
        (output/path).write_bytes(raw)
        digests[path] = hashlib.sha256(raw).hexdigest()
    manifest = {'source':source, 'model':'WindChargeModel', 'files':digests,
                'texture':{'path':'wind_charge.png','bytes':len(texture),'sha256':digests['wind_charge.png']}}
    (output/'manifest.json').write_bytes((json.dumps(manifest, indent=2)+'\n').encode())


if __name__ == '__main__':
    render(ROOT/'inputs/1.21.1.jar', ROOT/'assets/private/wind-charge',
           ROOT/'third_party/wukong-steve/tools/ExtractMinecraft.py')
    convert(ROOT/'inputs/assets', ROOT/'inputs/ffmpeg', ROOT/'assets/private/wind-charge/sounds',
            {'wind_throw':'entity.wind_charge.throw'}, clip_prefix='wind26_')
