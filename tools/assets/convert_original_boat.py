"""Convert the pinned Java boat model into independent host hull/paddle meshes.

Only the original 1.21.1 oak texture and the bounded private model reference
are read. Uses the pinned upstream per-texel mesh encoder; retain its NOTICE.
No game deployment, runtime change or synthetic boat art is performed.
"""
from __future__ import annotations
import importlib.util
import io
import json
import math
import re
from pathlib import Path
from PIL import Image, ImageDraw
from extend_original_item_icons import OriginalPack, ROOT, digest

OUT = ROOT / 'assets/private/boat'
REFERENCE = ROOT / 'recipes/boat-parts.json'
EXTRACTOR = ROOT / 'third_party/wukong-steve/tools/ExtractMinecraft.py'
SCALE = 6.25


def number(expression):
    expression = expression.replace('(float)', '').replace('Math.PI', repr(math.pi))
    expression = re.sub(r'(?<=\d)[Ff]\b', '', expression)
    if not re.fullmatch(r'[\d\s.+*/()\-]+', expression):
        raise ValueError('unrecognized bounded model expression: ' + expression)
    return float(eval(expression, {'__builtins__': {}}, {}))


def original_parts(source):
    pattern = (r'modelPartData\.addChild\(\s*"([a-z_]+)",\s*'
               r'ModelPartBuilder\.create\(\)\.uv\((\d+),\s*(\d+)\)(.*?),\s*'
               r'ModelTransform\.(of|pivot)\((.*?)\)\s*\);')
    parts = []
    for name, u, v, boxes, transform, values in re.findall(pattern, source, re.S):
        cubes = []
        for arguments in re.findall(r'\.cuboid\(([^)]+)\)', boxes):
            values6 = list(map(number, arguments.split(',')))
            assert len(values6) == 6
            cubes.append(dict(origin=values6[:3], size=values6[3:], uv=[int(u), int(v)]))
        assert len(cubes) in (1, 2), name
        values = list(map(number, values.split(',')))
        assert len(values) == (6 if transform == 'of' else 3)
        parts.append(dict(name=name, cubes=cubes, pivot=values[:3],
                          rotation=values[3:] if transform == 'of' else [0, 0, 0]))
    assert [p['name'] for p in parts] == [
        'bottom', 'back', 'front', 'right', 'left', 'left_paddle', 'right_paddle', 'water_patch']
    return parts


def rotate(vector, angles):
    # ModelPart uses Quaternionf.rotationZYX(roll,yaw,pitch): Rx, then Ry, then Rz.
    x, y, z = vector
    c, s = math.cos(angles[0]), math.sin(angles[0]); y, z = c*y-s*z, s*y+c*z
    c, s = math.cos(angles[1]), math.sin(angles[1]); x, z = c*x+s*z, -s*x+c*z
    c, s = math.cos(angles[2]), math.sin(angles[2]); x, y = c*x-s*y, s*x+c*y
    return [x, y, z]


def recipe(vector, origin=False):
    # mesh_bundle turns this into UE(modelX,-modelZ,-modelY+6)*6.25.
    x, y, z = vector
    return [z, y-(6 if origin else 0), -x]


def runtime(vector):
    x, y, z = vector
    return [-z*SCALE, -x*SCALE, -y*SCALE]


def paddle_angles(phase, right=False):
    pitch = -math.pi/3 + (math.pi/4)*(math.sin(-phase)+1)/2
    yaw = -math.pi/4 + (math.pi/2)*(math.sin(-phase+1)+1)/2
    return [pitch, math.pi-yaw if right else yaw, math.pi/16]


def combine(meshes):
    result = {k: [] for k in ('positions', 'normals', 'uv', 'colors', 'triangles')}
    for mesh in meshes:
        offset = len(result['positions'])
        for key in ('positions', 'normals', 'uv', 'colors'):
            result[key].extend(mesh[key])
        result['triangles'].extend(i+offset for i in mesh['triangles'])
    return result


def merged_mesh(faces, texture, extract):
    """Merge exact RGBA rectangles within each original face, without resampling.

    Different normals, UV islands and colors never share a rectangle. Feeding
    one constant-color texel to the pinned encoder preserves its winding and
    vertex-color contract; restore the original rectangle UVs afterwards.
    """
    rectangles = []
    tw, th = texture.size
    for vertices, (u, v, w, h) in faces:
        cols, rows = int(abs(w)), int(abs(h))
        pixels = [[texture.getpixel((math.floor(u+(x+.5)*w/cols),
                                    math.floor(v+(y+.5)*h/rows)))
                   for x in range(cols)] for y in range(rows)]
        used = set()
        for y in range(rows):
            for x in range(cols):
                rgba = pixels[y][x]
                if (x, y) in used or rgba[3] == 0:
                    continue
                width = 1
                while x+width < cols and (x+width, y) not in used and pixels[y][x+width] == rgba:
                    width += 1
                height = 1
                while y+height < rows and all((xx, y+height) not in used and pixels[y+height][xx] == rgba
                                               for xx in range(x, x+width)):
                    height += 1
                used.update((xx, yy) for yy in range(y, y+height) for xx in range(x, x+width))
                st = [(x/cols, y/rows), ((x+width)/cols, y/rows),
                      ((x+width)/cols, (y+height)/rows), (x/cols, (y+height)/rows)]
                points = [[vertices[0][j]+s*(vertices[1][j]-vertices[0][j])+
                           t*(vertices[3][j]-vertices[0][j]) for j in range(3)] for s, t in st]
                piece = extract.mesh_from_faces([(points, (0, 0, 1, 1))], Image.new('RGBA', (1, 1), rgba))
                piece['uv'] = [[(u+s*w)/tw, (v+t*h)/th] for s, t in st]
                rectangles.append(piece)
    return combine(rectangles)


def pose_mesh(mesh, angles=(0, 0, 0), pivot=(0, 0, 0), global_origin=True):
    points = [[v+p for v, p in zip(rotate(point, angles), pivot)] for point in mesh['positions']]
    return dict(mesh, positions=[recipe(p, global_origin) for p in points],
                normals=[recipe(rotate(n, angles)) for n in mesh['normals']])


def bounds(mesh):
    points = list(map(runtime, mesh['positions']))
    return [[min(p[i] for p in points), max(p[i] for p in points)] for i in range(3)]


def preview(mesh, path):
    """Evidence-only orthographic rendering of these actual original-color quads."""
    output = Image.new('RGB', (1440, 520), '#eef0f1'); draw = ImageDraw.Draw(output)
    points = list(map(runtime, mesh['positions']))
    views = [('Original oak boat - resting paddles', -35, 30),
             ('Top - two independent paddles', 0, 90), ('Side - origin at hull bottom', 0, 0)]
    for view, (label, azimuth, elevation) in enumerate(views):
        a, e = math.radians(azimuth), math.radians(elevation)
        def project(p):
            x, y, z = p
            horizontal = x*math.cos(a)-y*math.sin(a)
            depth = x*math.sin(a)+y*math.cos(a)
            return horizontal, z*math.cos(e)-depth*math.sin(e), depth*math.cos(e)+z*math.sin(e)
        q = list(map(project, points)); xs = [p[0] for p in q]; ys = [p[1] for p in q]
        size = 420/max(max(xs)-min(xs), max(ys)-min(ys)); cx = (min(xs)+max(xs))/2; cy = (min(ys)+max(ys))/2
        # From negative depth to positive depth (viewer); the source color is unchanged.
        for i in sorted(range(0, len(q), 4), key=lambda k: sum(q[j][2] for j in range(k, k+4))):
            color = tuple(round(c*255) for c in mesh['colors'][i][:3])
            draw.polygon([(view*480+240+(q[j][0]-cx)*size, 280-(q[j][1]-cy)*size)
                          for j in range(i, i+4)], fill=color)
        draw.text((view*480+16, 20), label, fill='#222222')
    output.save(path)


def main():
    parts = json.loads(REFERENCE.read_text(encoding='utf8'))
    spec = importlib.util.spec_from_file_location('pinned_mc_boat_extract', EXTRACTOR)
    extract = importlib.util.module_from_spec(spec); spec.loader.exec_module(extract)
    pack = OriginalPack('1.21.1'); dependencies = {}
    texture_path = 'assets/minecraft/textures/entity/boat/oak.png'
    texture_raw = pack.read(texture_path, dependencies)
    texture = Image.open(io.BytesIO(texture_raw)).convert('RGBA')
    assert texture.size == (128, 64)
    meshes = {}
    for part in parts:
        faces = []
        for cube in part['cubes']:
            faces.extend(extract.cuboid(cube['origin'], cube['size'], cube['uv']))
        meshes[part['name']] = merged_mesh(faces, texture, extract)
    hull = combine([pose_mesh(meshes[p['name']], p['rotation'], p['pivot']) for p in parts[:5]])
    output_parts = {'hull': dict(name='hull', pivot=[0, 0, 0], mesh=hull)}
    complete = [hull]
    for p in parts[5:7]:
        output_parts[p['name']] = dict(name=p['name'], pivot=recipe(p['pivot'], True),
                                      mesh=pose_mesh(meshes[p['name']], global_origin=False))
        complete.append(pose_mesh(meshes[p['name']], paddle_angles(0, p['name']=='right_paddle'), p['pivot']))
    output_parts['complete_rest'] = dict(name='complete_rest', pivot=[0, 0, 0], mesh=combine(complete))
    OUT.mkdir(parents=True, exist_ok=True); (OUT/'oak.png').write_bytes(texture_raw)
    outputs = []
    for name, part in output_parts.items():
        path = OUT/(name+'.mesh'); extract.write_binary(path, [part])
        outputs.append(dict(path=path.name, sha256=digest(path.read_bytes()), bytes=path.stat().st_size,
                            vertices=len(part['mesh']['positions']), indices=len(part['mesh']['triangles']),
                            pivot_cm=runtime(part['pivot']), local_bounds_cm=bounds(part['mesh'])))
    preview(output_parts['complete_rest']['mesh'], OUT/'preview.png')
    manifest = dict(format='STEVEM01', minecraft_version='1.21.1', namespace='minecraft',
        resource='minecraft:oak_boat', units=dict(scale_for_mesh_bundle=SCALE, block_cm=100, pixel_cm=SCALE),
        axes='UE +X bow/forward, +Y starboard/right, +Z up; hull bottom plane is local Z=0',
        coordinate_recipe='Model(x,y,z) -> recipe(z,y-6,-x) -> UE(x,-z,6-y)*6.25; paddle local vertices omit -6',
        paddle_contract='Load left/right local mesh at its decoded pivot; rotate local vertices with P R P^-1, where P(x,y,z)=(x,-z,-y), R=Rz(roll)Ry(yaw)Rx(pitch). Do not add pivot twice.',
        paddle_animation=dict(roll=math.pi/16, phase_per_tick=math.pi/8, tick_rate=20,
            rest_angles_left=paddle_angles(0), rest_angles_right=paddle_angles(0,True)),
        entity_dimensions_cm=[137.5, 137.5, 56.25], seat_height_cm=18.75,
        seat_forward_cm=dict(single=[0], double=[20,-60]),
        water_patch='Excluded: original hidden water-mask pass is not wooden geometry.',
        optimization='Exact RGBA greedy rectangles within each original cuboid face; no texture resampling or color reduction.',
        original_parts=parts,
        sources=[dict(path=texture_path, sha256=digest(texture_raw), retained='oak.png', operation='byte-copy'),
                 dict(path=str(REFERENCE.relative_to(ROOT)), sha256=digest(REFERENCE.read_bytes())),
                 dict(path=str(EXTRACTOR.relative_to(ROOT)), sha256=digest(EXTRACTOR.read_bytes()),
                      commit='9f213556519dca4498fd46f02af6236ae121ecae', license='PolyForm Noncommercial 1.0.0', notice='third_party/wukong-steve/NOTICE')],
        recipe_sha256=digest(Path(__file__).read_bytes()), outputs=outputs,
        evidence_preview=dict(path='preview.png', sha256=digest((OUT/'preview.png').read_bytes()), runtime_capture=False))
    (OUT/'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
    pack.archive.close()
    print(json.dumps(dict(outputs=outputs, preview=str(OUT/'preview.png'))))


if __name__ == '__main__':
    main()
