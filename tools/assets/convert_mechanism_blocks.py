"""Convert the user's original MC 1.21.1 mechanism resources into private bundles.

The world format is the existing STEVEM01 recipe. Original JSON elements, face
UVs, rotations, blockstates and item display transforms are authoritative. This
tool deliberately does not edit the shared content/UI/item manifests or deploy.
"""
from __future__ import annotations

from collections import defaultdict
from functools import lru_cache
import hashlib
import io
import itertools
import json
import math
from pathlib import Path
import struct
import subprocess
import sys

from PIL import Image, ImageDraw

from convert_building_blocks import CORNERS, NORMALS, binary, original_gui, rotation
from convert_original_item_models import CONTEXTS, Unsupported, display_transform, resolve_model
from extend_original_item_icons import OriginalPack, ROOT, digest, resource_path
from extend_original_item_labels import language

OUT = ROOT / 'assets/private/mechanism-blocks'
VERSION = '1.21.1'
SCALE = 6.25
CONTENT = ('oak_door', 'iron_door', 'end_rod', 'lever', 'redstone_block',
           'redstone_torch', 'repeater', 'comparator', 'piston', 'sticky_piston',
           'piston_head', 'obsidian', 'observer', 'slime_block', 'honey_block')
DEFAULTS = {
    'oak_door': dict(facing='north', half='lower', hinge='left', open=False),
    'iron_door': dict(facing='north', half='lower', hinge='left', open=False),
    'end_rod': dict(facing='up'),
    'lever': dict(face='floor', facing='north', powered=False),
    'redstone_block': {}, 'obsidian': {}, 'slime_block': {}, 'honey_block': {},
    'redstone_torch': dict(face='floor', facing='north', lit=True),
    'repeater': dict(delay=1, facing='north', locked=False, powered=False),
    'comparator': dict(facing='north', mode='compare', powered=False),
    'piston': dict(extended=False, facing='north'),
    'sticky_piston': dict(extended=False, facing='north'),
    'piston_head': dict(facing='north', short=False, type='normal'),
    'observer': dict(facing='north', powered=False),
    'redstone_dust': dict(east='none', north='none', power=0, south='none', west='none'),
}


def canonical(state):
    return ','.join(f'{k}={str(v).lower()}' for k, v in sorted(state.items()))


def parsed(text):
    return dict(pair.split('=', 1) for pair in text.split(',')) if text else {}


class Pack(OriginalPack):
    """Only the already hash-pinned local archive is admitted."""

    def read(self, path, dependencies):
        if path in dependencies:
            return dependencies[path]
        if path in self.entries:
            return super().read(path, dependencies)
        # Some block parent models were outside the earlier reuse allowlist.
        # Extract only dependencies reached from this tool's explicit roots.
        assert (path.startswith('assets/minecraft/') or path == 'data/minecraft/worldgen/biome/plains.json') and '..' not in path.split('/')
        raw = self.archive.read(path)
        dependencies[path] = raw
        return raw


def resolved(pack, name, deps):
    elements = None
    textures, displays, chain = {}, {}, []
    light = None
    while name:
        path = resource_path('models', name)
        assert path not in chain and len(chain) < 16, name
        model = json.loads(pack.read(path, deps))
        chain.append(path)
        if elements is None and 'elements' in model:
            elements = model['elements']
        for key, value in model.get('textures', {}).items():
            textures.setdefault(key, value)
        if light is None:
            light = model.get('gui_light')
        local = dict(model.get('display', {}))
        for prefix in ('firstperson', 'thirdperson'):
            if prefix + '_lefthand' not in local and prefix + '_righthand' in local:
                local[prefix + '_lefthand'] = local[prefix + '_righthand']
        for key, value in local.items():
            if key in CONTEXTS and key not in displays:
                displays[key] = display_transform(value)
        name = model.get('parent')
        if name in ('builtin/generated', 'minecraft:builtin/generated'):
            raise Unsupported('generated item; use original generated model converter')
    assert elements, chain
    return elements, textures, dict(parent_chain=chain,
        display={c: displays.get(c, display_transform({})) for c in CONTEXTS},
        gui_light=light or 'side', overrides=[])


def texref(value, textures):
    seen = set()
    while value.startswith('#'):
        assert value not in seen, value
        seen.add(value)
        value = textures[value[1:]]
    return resource_path('textures', value, '.png')


def default_uv(side, start, end):
    x0, y0, z0 = start
    x1, y1, z1 = end
    return {
        'down': [x0, 16-z1, x1, 16-z0], 'up': [x0, z0, x1, z1],
        'north': [16-x1, 16-y1, 16-x0, 16-y0],
        'south': [x0, 16-y1, x1, 16-y0],
        'west': [z0, 16-y1, z1, 16-y0],
        'east': [16-z1, 16-y1, 16-z0, 16-y0],
    }[side]


def element_transform(point, transform, normal=False):
    if not transform:
        return list(point)
    axis = 'xyz'.index(transform['axis'])
    origin = [0, 0, 0] if normal else transform['origin']
    p = [point[i]-origin[i] for i in range(3)]
    angle = math.radians(transform['angle'])
    c, s = math.cos(angle), math.sin(angle)
    if axis == 0:
        p[1], p[2] = p[1]*c-p[2]*s, p[1]*s+p[2]*c
    elif axis == 1:
        p[0], p[2] = p[0]*c+p[2]*s, -p[0]*s+p[2]*c
    else:
        p[0], p[1] = p[0]*c-p[1]*s, p[0]*s+p[1]*c
    if transform.get('rescale'):
        for i in range(3):
            if i != axis:
                p[i] /= math.cos(angle)
    if normal:
        norm = math.sqrt(sum(v*v for v in p))
        return [v/norm for v in p]
    return [round(p[i]+origin[i], 10) for i in range(3)]


def splits(a, b, pixels):
    assert a != b
    points = {0., 1.}
    lo, hi = sorted((a, b))
    for boundary in range(math.floor(lo*pixels/16)+1, math.ceil(hi*pixels/16)):
        t = (boundary*16/pixels-a)/(b-a)
        if 0 < t < 1:
            points.add(round(t, 12))
    return sorted(points)


def wire_tint(power):
    # RedstoneWireBlock.COLORS, source hash retained in manifest references.
    p = power / 15.
    return (p*.6 + (.4 if p > 0 else .3),
            max(0., min(1., p*p*.7-.5)), max(0., min(1., p*p*.6-.7)))


def build_faces(pack, name, deps, state=None, power=0):
    elements, textures, info = resolved(pack, name, deps)
    variant = state or {}
    assert not variant.get('uvlock', False), 'UV lock is not present in this explicit resource set'
    bx, by = variant.get('x', 0), variant.get('y', 0)
    faces = []
    for element in elements:
        start, end = element['from'], element['to']
        er = element.get('rotation')
        for side, value in element['faces'].items():
            path = texref(value['texture'], textures)
            image = Image.open(io.BytesIO(pack.read(path, deps))).convert('RGBA')
            assert image.width == image.height, path
            uv = value.get('uv', default_uv(side, start, end))
            if uv[0] == uv[2] or uv[1] == uv[3]:
                continue
            quarter = value.get('rotation', 0)//90
            points = []
            for index in (0, 3, 2, 1):
                cube_corner = CORNERS[side][(index-quarter) % 4]
                point = [start[i]+cube_corner[i]*(end[i]-start[i]) for i in range(3)]
                point = element_transform(point, er)
                points.append(rotation([v-8 for v in point], bx, by))
            normal = rotation(element_transform(NORMALS[side], er, True), bx, by)
            cull = value.get('cullface')
            if cull:
                n = rotation(NORMALS[cull], bx, by)
                cull = next(k for k, v in NORMALS.items() if all(abs(v[i]-n[i]) < 1e-8 for i in range(3)))
            xs, ys = splits(uv[0], uv[2], image.width), splits(uv[1], uv[3], image.height)
            pixels = []
            tint = wire_tint(power) if value.get('tintindex', -1) >= 0 else (1, 1, 1)
            for a, b in zip(ys, ys[1:]):
                v = (uv[1]+(uv[3]-uv[1])*(a+b)*.5)/16
                row = []
                for x, y in zip(xs, xs[1:]):
                    u = (uv[0]+(uv[2]-uv[0])*(x+y)*.5)/16
                    rgba = image.getpixel((min(image.width-1, max(0, int(u*image.width))),
                                           min(image.height-1, max(0, int(v*image.height)))))
                    assert 0 <= rgba[3] <= 255, (path, rgba)
                    row.append(tuple(round(rgba[i]*tint[i]) for i in range(3))+(rgba[3],))
                pixels.append(row)
            faces.append(dict(points=points, normal=normal, cull=cull, xs=xs, ys=ys, pixels=pixels,
                              texture=path, shade=element.get('shade', True)))
    return faces, info, elements


def merged_mesh(faces, space='world'):
    mesh = {k: [] for k in ('positions', 'normals', 'uv', 'colors', 'triangles')}
    def recipe(p):
        x, y, z = p
        return [z, -y, -x] if space == 'world' else [x, -y, -z]
    pixels_total = 0
    face_groups = []
    seen_quads = set()
    for face in sorted(faces, key=lambda f: f['cull'] or ''):
        start_index = len(mesh['triangles'])
        xs, ys, pixels = face['xs'], face['ys'], face['pixels']
        width, height = len(xs)-1, len(ys)-1
        used = set()
        for y in range(height):
            for x in range(width):
                rgba = pixels[y][x]
                if rgba[3] == 0 or (x, y) in used:
                    continue
                w = 1
                while x+w < width and (x+w, y) not in used and pixels[y][x+w] == rgba:
                    w += 1
                h = 1
                while y+h < height and all((xx, y+h) not in used and pixels[y+h][xx] == rgba for xx in range(x, x+w)):
                    h += 1
                used.update((xx, yy) for xx in range(x, x+w) for yy in range(y, y+h))
                pixels_total += w*h
                uv = [(xs[x], ys[y]), (xs[x+w], ys[y]), (xs[x+w], ys[y+h]), (xs[x], ys[y+h])]
                p = face['points']
                points = [recipe([round(p[0][i]+u*(p[1][i]-p[0][i])+v*(p[3][i]-p[0][i]), 9)
                                  for i in range(3)]) for u, v in uv]
                normal = recipe(face['normal'])
                identity = (tuple(sorted(tuple(p) for p in points)), tuple(normal), rgba)
                if identity in seen_quads:
                    continue
                seen_quads.add(identity)
                a, b = ([points[j][i]-points[0][i] for i in range(3)] for j in (1, 2))
                cross = (a[1]*b[2]-a[2]*b[1], a[2]*b[0]-a[0]*b[2], a[0]*b[1]-a[1]*b[0])
                order = (0, 1, 2, 0, 2, 3) if sum(c*n for c, n in zip(cross, normal)) > 0 else (0, 2, 1, 0, 3, 2)
                offset = len(mesh['positions'])
                mesh['positions'].extend(points)
                mesh['normals'].extend([normal]*4)
                mesh['uv'].extend(uv)
                mesh['colors'].extend([tuple(c/255 for c in rgba)]*4)
                mesh['triangles'].extend(offset+j for j in order)
        count = len(mesh['triangles'])-start_index
        if count:
            if face_groups and face_groups[-1]['cullface'] == face['cull'] and face_groups[-1]['first_index']+face_groups[-1]['index_count'] == start_index:
                face_groups[-1]['index_count'] += count
            else:
                face_groups.append(dict(cullface=face['cull'], first_index=start_index, index_count=count))
    return mesh, dict(sampled_opaque_texels=pixels_total, vertices_before_merge=pixels_total*4,
                      vertices=len(mesh['positions']), indices=len(mesh['triangles']), face_groups=face_groups)


def alpha_gui(mesh, display):
    # Same original JSON GUI transform/lighting as the existing renderer, but
    # source-alpha composite back-to-front so the translucent shell keeps its
    # inner core. One high-resolution layer per face is an offline-only cost.
    points=[];colors=[];d=display['gui']
    for p,n,color in zip(mesh['positions'],mesh['normals'],mesh['colors']):
        x,y,z=p[0]*d['scale'][0],-p[1]*d['scale'][1],-p[2]*d['scale'][2]
        for axis in (2,1,0):
            c,s=math.cos(math.radians(d['rotation'][axis])),math.sin(math.radians(d['rotation'][axis]))
            if axis==2:x,y=x*c-y*s,x*s+y*c
            elif axis==1:x,z=x*c+z*s,-x*s+z*c
            else:y,z=y*c-z*s,y*s+z*c
        points.append((x+d['translation'][0],y+d['translation'][1],z+d['translation'][2]))
        shade=1 if n[1]<-.5 else .5 if n[1]>.5 else .8 if abs(n[2])>.5 else .6
        colors.append(tuple(round(c*shade*255) for c in color[:3])+(round(color[3]*255),))
    image=Image.new('RGBA',(256,256))
    for i in sorted(range(0,len(points),4),key=lambda k:sum(points[j][2] for j in range(k,k+4))):
        layer=Image.new('RGBA',image.size)
        ImageDraw.Draw(layer).polygon([(128+points[j][0]*16,128-points[j][1]*16) for j in range(i,i+4)],fill=colors[i])
        image=Image.alpha_composite(image,layer)
    return image.resize((64,64),Image.Resampling.NEAREST)


def palette_uv(mesh, name, write):
    # PBZ's cooked Widget pass-through samples SlateUI but ignores mesh vertex
    # colour. Each existing merged rectangle has one exact source RGBA value;
    # a nearest palette texel restores that value without rebuilding geometry.
    colors=sorted({tuple(round(v*255) for v in rgba) for rgba in mesh['colors']})
    width=1
    while width*width<len(colors):width*=2
    height=1
    while width*height<len(colors):height*=2
    assert width<=64 and height<=64,'unexpected-palette-size'
    image=Image.new('RGBA',(width,height))
    image.putdata(colors+[(0,0,0,0)]*(width*height-len(colors)))
    stream=io.BytesIO();image.save(stream,format='PNG')
    row=write('palettes/'+name+'.png',stream.getvalue(),operation='lossless-vertex-rgba-palette')
    uv={rgba:((i%width+.5)/width,(i//width+.5)/height) for i,rgba in enumerate(colors)}
    mesh['uv']=[uv[tuple(round(v*255) for v in rgba)] for rgba in mesh['colors']]
    return dict(**row,size=[width,height],colors=len(colors),filter='nearest',color_space='srgb',
                uv_origin='top-left',vertex_color_policy='host-white',vertex_alpha_policy='host-one')


def box_cm(start, end, variant=None):
    variant = variant or {}
    points = [rotation([p[i]-8 for i in range(3)], variant.get('x', 0), variant.get('y', 0))
              for p in itertools.product(*zip(start, end))]
    points = [(x*SCALE, -z*SCALE, y*SCALE) for x, y, z in points]
    lo = [round(min(p[i] for p in points), 6) for i in range(3)]
    hi = [round(max(p[i] for p in points), 6) for i in range(3)]
    return dict(min=lo, max=hi, center=[(a+b)/2 for a, b in zip(lo, hi)], half=[(b-a)/2 for a, b in zip(lo, hi)])


def collision(name, state, variant, elements):
    if name == 'slime_block':
        return [box_cm([0, 0, 0], [16, 16, 16])]
    if name == 'honey_block':
        return [box_cm([1, 0, 1], [15, 15, 15])]
    if name in ('lever', 'redstone_torch', 'redstone_dust'):
        return []
    if name in ('repeater', 'comparator'):
        return [box_cm([0, 0, 0], [16, 2, 16])]
    if name == 'end_rod':
        return [box_cm([6, 0, 6], [10, 16, 10], variant)]
    # Doors use original 3-pixel bounds, pistons use the original platform/rod.
    return [box_cm(e['from'], e['to'], variant) for e in elements]


def matches(condition, state):
    if 'OR' in condition:
        return any(matches(c, state) for c in condition['OR'])
    if 'AND' in condition:
        return all(matches(c, state) for c in condition['AND'])
    return all(str(state.get(key, '')).lower() in value.split('|') for key, value in condition.items())


def sound_index():
    base = (ROOT / 'inputs/assets')
    index_path = base/'indexes/1.21.1-17.json'
    raw = index_path.read_bytes()
    entries = json.loads(raw)['objects']
    def read(name):
        entry = entries[name]
        source = base/'objects'/entry['hash'][:2]/entry['hash']
        data = source.read_bytes()
        assert hashlib.sha1(data).hexdigest() == entry['hash'] and len(data) == entry['size']
        return source, data
    sound_path, sound_raw = read('minecraft/sounds.json')
    catalogue = json.loads(sound_raw)
    names = ('block.wooden_door.open', 'block.wooden_door.close', 'block.iron_door.open',
             'block.iron_door.close', 'block.lever.click', 'block.stone_button.click_on',
             'block.stone_button.click_off', 'block.comparator.click', 'block.piston.extend',
             'block.piston.contract', 'block.water.ambient', 'block.lava.ambient',
             'block.lava.pop', 'block.fire.extinguish', 'item.bucket.fill',
             'item.bucket.empty', 'item.bucket.fill_lava', 'item.bucket.empty_lava',
             'block.stone.place', 'block.stone.break', 'block.stone.hit',
             'block.wood.place', 'block.wood.break', 'block.wood.hit',
             'block.metal.place', 'block.metal.break', 'block.metal.hit',
             'block.slime_block.place', 'block.slime_block.break', 'block.slime_block.hit',
             'block.slime_block.step', 'block.slime_block.fall',
             'block.honey_block.place', 'block.honey_block.break', 'block.honey_block.hit',
             'block.honey_block.step', 'block.honey_block.fall', 'block.honey_block.slide')
    events, clips = {}, {}
    def event(name, visiting=()):
        assert name not in visiting
        variants = []
        for value in catalogue[name]['sounds']:
            value = {'name': value} if isinstance(value, str) else value
            if value.get('type', 'sound') == 'event':
                variants.extend(event(value['name'], visiting+(name,)))
            else:
                member = 'minecraft/sounds/'+value['name']+'.ogg'
                path, data = read(member)
                clips[member] = dict(member=member, source_path=str(path), source_sha1=entries[member]['hash'],
                                     sha256=digest(data), bytes=len(data))
                variants.append(dict(member=member, volume=value.get('volume', 1),
                                     pitch=value.get('pitch', 1), weight=value.get('weight', 1)))
        return variants
    for name in names:
        events[name] = event(name)
    return dict(version=VERSION, asset_index=str(index_path), asset_index_sha256=digest(raw),
                sounds_json=str(sound_path), sounds_json_sha256=digest(sound_raw),
                events=events, clips=list(clips.values()), converted_to_pcm=False)


def convert_sounds(index, write):
    ff = (ROOT / 'inputs/ffmpeg')
    clips = []
    by_member = {}
    for source in index['clips']:
        path = Path(source['source_path'])
        raw = path.read_bytes()
        assert digest(raw) == source['sha256']
        probe = json.loads(subprocess.check_output([
            str(ff/'ffprobe.exe'), '-v', 'error', '-show_streams', '-of', 'json', str(path)]))
        assert len(probe['streams']) == 1 and probe['streams'][0]['codec_type'] == 'audio'
        stream = probe['streams'][0]
        assert 0 < float(stream['duration']) < 60, source['member']
        name = source['member'].removeprefix('minecraft/sounds/').removesuffix('.ogg').replace('/', '_')
        pcm = subprocess.check_output([str(ff/'ffmpeg.exe'), '-v', 'error', '-i', str(path),
            '-ac', '2', '-ar', '44100', '-f', 's16le', 'pipe:1'])
        assert 0 < len(pcm) < 60*44100*4 and len(pcm) % 4 == 0
        row = write('sounds/'+name+'.pcm', pcm)
        clip = dict(**row, name=name, file=name+'.pcm', source=source['member'],
            source_sha1=source['source_sha1'], source_sha256=source['sha256'],
            source_codec=stream['codec_name'], source_channels=stream['channels'],
            source_sample_rate=int(stream['sample_rate']), duration_seconds=len(pcm)/(44100*4))
        clips.append(clip)
        by_member[source['member']] = name
    event_names = {
        'oak_door_open': 'block.wooden_door.open', 'oak_door_close': 'block.wooden_door.close',
        'iron_door_open': 'block.iron_door.open', 'iron_door_close': 'block.iron_door.close',
        'lever': 'block.lever.click', 'button_on': 'block.stone_button.click_on',
        'button_off': 'block.stone_button.click_off', 'comparator': 'block.comparator.click',
        'piston_extend': 'block.piston.extend', 'piston_contract': 'block.piston.contract',
        'water_ambient': 'block.water.ambient', 'lava_ambient': 'block.lava.ambient',
        'lava_pop': 'block.lava.pop', 'extinguish': 'block.fire.extinguish',
        'bucket_fill': 'item.bucket.fill', 'bucket_empty': 'item.bucket.empty',
        'bucket_fill_lava': 'item.bucket.fill_lava', 'bucket_empty_lava': 'item.bucket.empty_lava',
    }
    for group in ('stone', 'wood', 'metal'):
        for action in ('place', 'break', 'hit'):
            event_names[group+'_'+action] = 'block.'+group+'.'+action
    for group in ('slime', 'honey'):
        for action in ('place', 'break', 'hit', 'step', 'fall'):
            event_names[group+'_'+action]='block.'+group+'_block.'+action
    event_names['honey_slide']='block.honey_block.slide'
    variants = {key: [dict(clip=by_member[v['member']], volume=v['volume'], pitch=v['pitch'], weight=v['weight'])
                     for v in index['events'][event]] for key, event in event_names.items()}
    manifest = dict(schema=1, version=VERSION, format='s16le', channels=2, sample_rate=44100,
        event_names=event_names, events={k: [v['clip'] for v in values] for k, values in variants.items()},
        variants=variants, clips=clips, asset_index=index['asset_index'],
        asset_index_sha256=index['asset_index_sha256'], sounds_json_sha256=index['sounds_json_sha256'],
        encoder=dict(path=str(ff/'ffmpeg.exe'), sha256=digest((ff/'ffmpeg.exe').read_bytes())),
        recipe_sha256=digest(Path(__file__).read_bytes()),
        native_audio_modified=False, deployed=False,
        pcm_install_directory='pbzmc-assets/sounds',
        native_integration='Merge name/hash/bytes into block_audio_catalogue.hpp and rebuild; prepare() preloads all allowlisted PCM, no impact-time file IO.',
        original_silent_actions=['repeater delay change'],
        original_silent_action_source='Minecraft RepeaterBlock.useWithoutItem',
        playback_notes='Use event-specific game volume/pitch and bounded ambient voice coalescing; sample metadata is not an instruction to loop every active fluid cell.')
    write('sounds/manifest.json', (json.dumps(manifest, indent=2)+'\n').encode('utf8'))
    fragment = '\n'.join('    {"'+v['name']+'", "'+v['sha256']+'", '+str(v['bytes'])+'},' for v in clips)+'\n'
    write('sounds/native-catalogue-fragment.hpp', fragment.encode('utf8'))
    return manifest


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    pack = Pack(VERSION)
    deps, outputs, models, states, metadata, item_models, item_bindings, icons = {}, {}, {}, {}, {}, {}, {}, {}
    model_digests = {}
    labels, label_source = language(VERSION)
    references = []
    def write(path, raw, **extra):
        file = OUT/path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_bytes(raw)
        row = dict(path=path, sha256=digest(raw), bytes=len(raw), **extra)
        outputs[path] = row
        return row

    def add_model(mesh, stats, boxes, **extra):
        raw = binary(mesh, 'mechanism')
        sha = digest(raw)
        if sha in model_digests:
            key = model_digests[sha]
            assert models[key]['boxes_cm'] == boxes, (key, boxes)
            return key
        key = 'mechanism-blocks/'+sha[:20]
        points = [(-p[2]*SCALE, -p[0]*SCALE, -p[1]*SCALE) for p in mesh['positions']]
        bounds = [[min(p[i] for p in points), max(p[i] for p in points)] for i in range(3)]
        row = write('meshes/'+sha[:20]+'.mesh', raw)
        models[key] = dict(row, scale=SCALE, pivot=[0, 0, 0], bounds_cm=bounds,
                           boxes_cm=boxes, **stats, **extra)
        model_digests[sha] = key
        return key

    for name in CONTENT:
        source = resource_path('blockstates', name)
        definition = json.loads(pack.read(source, deps))
        content_id = 'pbzmc:'+name
        table, properties = {}, defaultdict(set)
        variants = definition['variants']
        if name == 'redstone_torch':
            variants = {canonical(dict(face='floor', facing='north', **parsed(k))): v for k, v in variants.items()}
            wall = json.loads(pack.read(resource_path('blockstates', 'redstone_wall_torch'), deps))['variants']
            variants.update({canonical(dict(face='wall', **parsed(k))): v for k, v in wall.items()})
        for text, value in variants.items():
            state = parsed(text)
            variant = value[0] if isinstance(value, list) else value
            faces, info, elements = build_faces(pack, variant['model'], deps, variant)
            mesh, stats = merged_mesh(faces)
            boxes = collision(name, state, variant, elements)
            translucent = name in ('slime_block', 'honey_block')
            palette=palette_uv(mesh,name,write) if translucent else None
            key = add_model(mesh, stats, boxes, alpha_mode='translucent' if translucent else 'cutout',
                            render_layer='translucent' if translucent else 'cutout',
                            **(dict(palette=palette) if palette else {}),
                            original_elements=len(elements), vertex_alpha_values=sorted({round(v[3]*255) for v in mesh['colors']}),
                            original_model=variant['model'], original_rotation={k: variant.get(k, 0) for k in ('x', 'y')})
            table[canonical(state)] = key
            for k, v in state.items():
                properties[k].add(v)
        states[content_id] = table
        metadata[content_id] = dict(state_defaults=DEFAULTS[name],
            state_properties={k: sorted(v) for k, v in sorted(properties.items())},
            default_model=table[canonical(DEFAULTS[name])], source_blockstate=source,
            catalogue=name != 'piston_head',
            render_layer='translucent' if name in ('slime_block', 'honey_block') else 'cutout')

    wire_source_path = resource_path('blockstates', 'redstone_wire')
    parts = json.loads(pack.read(wire_source_path, deps))['multipart']
    wire = {}
    @lru_cache(maxsize=None)
    def wire_faces(name, x, y, power):
        return build_faces(pack, name, deps, dict(x=x, y=y), power)[0]
    for connections in itertools.product(('none', 'side', 'up'), repeat=4):
        for power in range(16):
            state = dict(zip(('east', 'north', 'south', 'west'), connections), power=power)
            faces = []
            for part in parts:
                if matches(part.get('when', {}), state):
                    value = part['apply']
                    value = value[0] if isinstance(value, list) else value
                    faces.extend(wire_faces(value['model'], value.get('x', 0), value.get('y', 0), power))
            mesh, stats = merged_mesh(faces)
            key = add_model(mesh, stats, [], alpha_mode='cutout', power=power,
                            redstone_color_rgb=list(wire_tint(power)))
            wire[canonical(state)] = key
    content_id = 'pbzmc:redstone_dust'
    states[content_id] = wire
    metadata[content_id] = dict(state_defaults=DEFAULTS['redstone_dust'],
        state_properties={**{k: ['none', 'side', 'up'] for k in ('east', 'north', 'south', 'west')}, 'power': list(range(16))},
        default_model=wire[canonical(DEFAULTS['redstone_dust'])], source_blockstate=wire_source_path, catalogue=True)

    # Item and UI fragments have bundle-local paths; parent integration copies
    # these records with its chosen root. No shared manifest is touched here.
    for name in tuple(n for n in CONTENT if n != 'piston_head') + ('redstone_dust', 'water_bucket', 'lava_bucket', 'bucket'):
        source_name = 'redstone' if name == 'redstone_dust' else name
        item_id = 'pbzmc:'+name
        model_name = 'minecraft:item/'+source_name
        item_deps = {}
        try:
            mesh, info = resolve_model(pack, model_name, item_deps)
            icon_raw = item_deps[info['texture']]
            icon_kind = 'byte-copy'
        except Unsupported:
            faces, info, elements = build_faces(pack, model_name, item_deps)
            mesh, stats = merged_mesh(faces, 'item')
            icon = alpha_gui(mesh, info['display']) if name in ('slime_block', 'honey_block') else original_gui(mesh, info['display'])
            stream = io.BytesIO()
            icon.save(stream, format='PNG')
            icon_raw = stream.getvalue()
            icon_kind = 'original-json-model-gui-render'
            info['geometry'] = dict(original_elements=len(elements), **stats)
            if name in ('slime_block', 'honey_block'):
                info['render_layer']='translucent'
                info['vertex_alpha_values']=sorted({round(v[3]*255) for v in mesh['colors']})
                info['palette']=palette_uv(mesh,name,write)
        deps.update(item_deps)
        model_key = VERSION+'/'+resource_path('models', model_name)
        row = write('item-models/'+source_name+'.mesh', binary(mesh, 'item'))
        item_models[model_key] = dict(row, minecraft_version=VERSION, model=model_name,
            dependencies=[VERSION+'/'+p for p in item_deps], vertices=len(mesh['positions']),
            indices=len(mesh['triangles']), **info)
        item_bindings[item_id] = dict(resource='minecraft:'+source_name, minecraft_version=VERSION,
            contexts={c: dict(model=model_key, conditions=[]) for c in CONTEXTS}, variants=[], item_dependencies=[])
        icon = write('icons/'+source_name+'.png', icon_raw, operation=icon_kind,
                     size=list(Image.open(io.BytesIO(icon_raw)).size))
        label_key = ('item.minecraft.'+source_name if 'item.minecraft.'+source_name in labels else 'block.minecraft.'+source_name)
        icons[item_id] = dict(**icon, label=labels[label_key], label_source=dict(label_source, key=label_key),
                             item_model=model_key, original_model=resource_path('models', model_name),
                             dependencies=[dict(path=p, sha256=digest(raw)) for p, raw in item_deps.items()])

    biome_source = 'data/minecraft/worldgen/biome/plains.json'
    biome = json.loads(pack.read(biome_source, deps))
    water_color = biome['effects']['water_color']
    water_rgb = [(water_color >> shift) & 255 for shift in (16, 8, 0)]
    fluids = {}
    for fluid in ('water', 'lava'):
        animations = {}
        for kind in ('still', 'flow'):
            source = resource_path('textures', 'block/'+fluid+'_'+kind, '.png')
            raw = pack.read(source, deps)
            meta_raw = pack.read(source+'.mcmeta', deps)
            image = Image.open(io.BytesIO(raw)).convert('RGBA')
            frame_width = image.width
            count = image.height//frame_width
            original = json.loads(meta_raw)['animation']
            sequence = []
            for value in original.get('frames', list(range(count))):
                value = dict(index=value) if isinstance(value, int) else value
                sequence.append(dict(index=value['index'], ticks=value.get('time', original.get('frametime', 1))))
            frame_table = [dict(index=i, uv_min=[0, i/count], uv_max=[1, (i+1)/count]) for i in range(count)]
            row = write('fluids/'+fluid+'_'+kind+'.png', raw, operation='byte-copy')
            animations[kind] = dict(**row, source=source, meta_source=source+'.mcmeta',
                image_size=list(image.size), frame_size=[frame_width, frame_width], frame_count=count,
                sequence=sequence, cycle_ticks=sum(v['ticks'] for v in sequence), frame_uv=frame_table,
                interpolate=original.get('interpolate', False),
                original_alpha_values=sorted(set(image.getchannel('A').get_flattened_data())))
        fluids['pbzmc:'+fluid] = dict(textures=animations, collision_boxes_cm=[],
            render_contract='One shared original strip texture/MID per fluid/texture role (still or flow); one mesh with up to two sections and six quads per visible cell. UV V=(frameIndex+localV)/frameCount. Level/flow surface heights belong to gameplay.',
            alpha_mode='translucent' if fluid == 'water' else 'opaque', tint_rgb=water_rgb if fluid == 'water' else [255, 255, 255],
            tint_source=dict(path=biome_source, property='effects.water_color', value=water_color) if fluid == 'water' else None,
            tint_policy='MC plains water color; PBZ has no Minecraft biome source' if fluid == 'water' else 'untinted',
            vertex_alpha=1, fullbright=fluid == 'lava')

    source_records = []
    for path, raw in sorted(deps.items()):
        row = write('original/'+path, raw, operation='byte-copy')
        source_records.append(dict(version=VERSION, path=path, sha256=digest(raw), bytes=len(raw), retained_path=row['path']))
    sounds = sound_index()
    write('sound-index.json', (json.dumps(sounds, ensure_ascii=False, indent=2)+'\n').encode('utf8'))
    sound_manifest = convert_sounds(sounds, write)
    fragments = dict(models=item_models, items=item_bindings, icons=icons,
                     palettes={p:v for p,v in outputs.items() if p.startswith('palettes/')},
                     path_root='assets/private/mechanism-blocks', merge_policy='copy referenced files and records; do not replace unrelated entries')
    write('integration-fragments.json', (json.dumps(fragments, ensure_ascii=False, indent=2)+'\n').encode('utf8'))
    manifest = dict(schema=1, private_local_assets=True, format='STEVEM01', minecraft_version=VERSION,
        archive_sha256=pack.manifest['archive_sha256'], source_archive=pack.manifest['source_archive'],
        coordinate_contract='World: MC cell center(8,8,8) -> recipe(z,-y,-x) -> PBZ(x,-z,y), scale 6.25 cm/model unit. Item: recipe(x,-y,-z).',
        state_key_contract='Sort only state_properties keys lexicographically; fill state_defaults; lowercase true/false; join key=value with commas. Ignore simulation-only properties not listed. Redstone floor torch uses facing=north.',
        sources=source_records, references=references, models=models, states=states, blocks=metadata,
        items=icons, fluids=fluids, outputs=list(outputs.values()), recipe_sha256=digest(Path(__file__).read_bytes()),
        sounds='sounds/manifest.json', sound_sources='sound-index.json', integration_fragments='integration-fragments.json',
        upstream_format_source=dict(repository='nicedoctors/wukong-steve', commit='9f213556519dca4498fd46f02af6236ae121ecae',
                                    license='PolyForm Noncommercial 1.0.0', retained_license='third_party/wukong-steve/LICENSE'),
        performance=dict(rectangle_merge=True, hash_deduplicated_models=True,
            frame_textures_decoded_once=True, host_cache_required=True,
            neighbor_culling='Each model face_groups has zero-based first_index/index_count and MC cullface; null groups are always visible.',
            resource_bytes=sum(v['bytes'] for v in outputs.values()), mesh_bytes=sum(v['bytes'] for v in models.values())),
        limitations=['No native PBZ rendering, placement, collision or fluid-material test is implied by conversion.',
            'GUI renders use original elements/display/nearest texture colors; lighting is the existing repository side-light approximation.',
            'No moving-piston interpolation is baked: static base/head states plus host transforms are supplied.',
            'Fluid biome tint uses the default overworld color because PBZ has no Minecraft biome registry.'])
    (OUT/'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2)+'\n', encoding='utf8')
    # Model-derived contact sheet is a QA artifact, never a replacement sprite.
    sheet = Image.new('RGBA', (8*112, math.ceil(len(icons)/8)*112), '#242424')
    draw = ImageDraw.Draw(sheet)
    for i, (item_id, row) in enumerate(icons.items()):
        icon = Image.open(OUT/row['path']).convert('RGBA').resize((64, 64), Image.Resampling.NEAREST)
        x, y = (i % 8)*112, (i//8)*112
        sheet.alpha_composite(icon, (x+24, y+8))
        draw.text((x+3, y+79), item_id.removeprefix('pbzmc:'), fill='white')
    sheet.save(OUT/'contact-sheet.png')
    pack.archive.close()
    print(json.dumps(dict(models=len(models), states=sum(len(v) for v in states.values()),
                         items=len(icons), sources=len(source_records),
                         resource_bytes=manifest['performance']['resource_bytes'],
                         mesh_bytes=manifest['performance']['mesh_bytes'], deployed=False)))


def sounds_only():
    manifest = json.loads((OUT/'manifest.json').read_text(encoding='utf8'))
    outputs = {v['path']: v for v in manifest['outputs'] if not v['path'].startswith('sounds/')}
    def write(path, raw, **extra):
        file = OUT/path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_bytes(raw)
        row = dict(path=path, sha256=digest(raw), bytes=len(raw), **extra)
        outputs[path] = row
        return row
    index = sound_index()
    write('sound-index.json', (json.dumps(index, ensure_ascii=False, indent=2)+'\n').encode('utf8'))
    sounds = convert_sounds(index, write)
    manifest['sounds'] = 'sounds/manifest.json'
    manifest['sound_sources'] = 'sound-index.json'
    for fluid in manifest['fluids'].values():
        fluid['render_contract'] = 'One shared original strip texture/MID per fluid/texture role (still or flow); one mesh with up to two sections and six quads per visible cell. UV V=(frameIndex+localV)/frameCount. Level/flow surface heights belong to gameplay.'
    manifest['outputs'] = list(outputs.values())
    manifest['recipe_sha256'] = digest(Path(__file__).read_bytes())
    manifest['performance']['resource_bytes'] = sum(v['bytes'] for v in outputs.values())
    (OUT/'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2)+'\n', encoding='utf8')
    print(json.dumps(dict(sound_clips=len(sounds['clips']), pcm_bytes=sum(c['bytes'] for c in sounds['clips']),
                         max_duration=max(c['duration_seconds'] for c in sounds['clips']), deployed=False)))


if __name__ == '__main__':
    sounds_only() if sys.argv[1:] == ['--sounds-only'] else main()
