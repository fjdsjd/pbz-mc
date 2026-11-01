"""Build an isolated, private MC 1.21.1 elytra/firework resource bundle.

Only this script's new bundle is written. Shared item/UI/font/audio manifests
are left to integrate_elytra_firework_resources.py and the parent task.
Textures are byte-copied; geometry comes from original item models and the
verified original ElytraEntityModel. No synthetic art or broken-elytra state.
"""
from __future__ import annotations
import bisect
import importlib.util
import io
import json
import math
from pathlib import Path
import re
import struct
import subprocess
from PIL import Image, ImageDraw

from extend_original_item_icons import OriginalPack, PACK_HASHES, ROOT, digest, resource_path
from convert_original_item_models import CONTEXTS, resolve_model
from mc_generated_geometry import mesh_bytes
from convert_original_boat import combine, merged_mesh, number, rotate
from extend_original_item_labels import language

OUT = ROOT / 'assets/private/elytra-firework'
REFERENCE = ROOT / 'recipes/elytra-parts.json'
EXTRACTOR = ROOT / 'third_party/wukong-steve/tools/ExtractMinecraft.py'
PIN = '9f213556519dca4498fd46f02af6236ae121ecae'
WING_SCALE = 100 * .9375 / 16
ITEM_SCALE = 100 / 16
ASSETS = (ROOT / 'inputs/assets')
FF = (ROOT / 'inputs/ffmpeg')
SOUND_EVENTS = {
    'launch': 'entity.firework_rocket.launch',
    'blast': 'entity.firework_rocket.blast',
    'twinkle': 'entity.firework_rocket.twinkle',
    'flying': 'item.elytra.flying',
}


def encoded(value):
    return (json.dumps(value, ensure_ascii=False, indent=2) + '\n').encode('utf8')


def load(path):
    return json.loads(path.read_text(encoding='utf8'))


def xyz(vector, scale=WING_SCALE):
    x, y, z = vector
    return [-z * scale, -x * scale, -y * scale]


def original_wings(source):
    dilation, = re.findall(r'Dilation dilation = new Dilation\(([^)]+)\)', source)
    size, = re.findall(r'TexturedModelData\.of\(modelData,\s*(\d+),\s*(\d+)\)', source)
    assert tuple(map(int, size)) == (64, 32)
    pattern = (r'modelPartData\.addChild\(\s*"([a-z_]+)",\s*'
               r'ModelPartBuilder\.create\(\)\.uv\((\d+),\s*(\d+)\)(\.mirrored\(\))?'
               r'\.cuboid\(([^)]+)\),\s*ModelTransform\.of\((.*?)\)\s*\);')
    parts = {}
    for name, u, v, mirror, box, pose in re.findall(pattern, source, re.S):
        args = box.split(',')
        assert args.pop().strip() == 'dilation'
        box_values = list(map(number, args))
        pose_values = list(map(number, pose.split(',')))
        assert len(box_values) == len(pose_values) == 6
        parts[name] = dict(origin=box_values[:3], size=box_values[3:], uv=[int(u), int(v)],
                           dilation=number(dilation), mirror=bool(mirror),
                           original_pivot_model_pixels=pose_values[:3],
                           rotation_rest_radians=pose_values[3:])
    assert set(parts) == {'left_wing', 'right_wing'}
    assert parts['left_wing']['original_pivot_model_pixels'] == [5, 0, 0]
    assert parts['right_wing']['original_pivot_model_pixels'] == [-5, 0, 0]
    return parts


def wing_mesh(part, texture, extract):
    faces = extract.cuboid(part['origin'], part['size'], part['uv'], part['dilation'])
    mesh = merged_mesh(faces, texture, extract)
    if part['mirror']:
        # ModelPart.Cuboid swaps its inflated x endpoints, reverses winding,
        # and negates x normals. Reflect about the original box centre.
        twice_centre = 2 * part['origin'][0] + part['size'][0]
        mesh['positions'] = [[twice_centre - x, y, z] for x, y, z in mesh['positions']]
        mesh['normals'] = [[-x, y, z] for x, y, z in mesh['normals']]
        t = mesh['triangles']
        mesh['triangles'] = [t[i+j] for i in range(0, len(t), 3) for j in (0, 2, 1)]
    # Original ElytraFeatureRenderer selects armorCutoutNoCull; the existing
    # white vertex-color material is culled, so retain a second index pass.
    front = list(mesh['triangles'])
    mesh['triangles'] += [front[i+j] for i in range(0, len(front), 3) for j in (0, 2, 1)]
    opaque = 0
    for _, (u, v, w, h) in faces:
        for y in range(int(abs(h))):
            for x in range(int(abs(w))):
                opaque += texture.getpixel((math.floor(u + (x+.5)*w/abs(w)),
                                            math.floor(v + (y+.5)*h/abs(h))))[3] > 0
    stats = dict(vertices=len(mesh['positions']), indices=len(mesh['triangles']),
                 merged_quads=len(mesh['positions'])//4, source_opaque_texels=opaque,
                 vertices_before_merge=opaque*4, double_sided_indices=True,
                 local_bounds_model_pixels=[[min(p[i] for p in mesh['positions']),
                                             max(p[i] for p in mesh['positions'])] for i in range(3)])
    return mesh, stats


def particle_mesh(runs):
    """Exact original opaque runs on one normalized, zero-pivot billboard.

    The existing bundle reader maps this raw plane to UE Y/Z. Full sprite
    width/height is one unit; controller scale supplies the particle extent.
    No image resampling, lighting, extrusion, or custom sparkle is involved.
    """
    mesh = {key: [] for key in ('positions', 'normals', 'uv', 'colors', 'triangles')}
    for x, y, width, r, g, b, a in runs:
        left, right = x/8-.5, (x+width)/8-.5
        top, bottom = .5-y/8, .5-(y+1)/8
        # UE face points: (0,left,bottom),(0,right,bottom),
        # (0,right,top),(0,left,top). Inverse bundle map gives raw coordinates.
        positions = [[-horizontal, -vertical, 0] for horizontal, vertical in
                     ((left, bottom), (right, bottom), (right, top), (left, top))]
        offset = len(mesh['positions'])
        mesh['positions'].extend(positions)
        mesh['normals'].extend([[0, 0, -1]]*4)
        mesh['uv'].extend([[x/8, (y+1)/8], [(x+width)/8, (y+1)/8],
                           [(x+width)/8, y/8], [x/8, y/8]])
        mesh['colors'].extend([[r/255, g/255, b/255, a/255]]*4)
        mesh['triangles'].extend(offset+i for i in (0, 1, 2, 0, 2, 3, 0, 2, 1, 0, 3, 2))
    assert mesh['positions']
    return mesh


def font_coverage(labels):
    ui_root = ROOT / 'assets/private/minecraft-1.21.1/ui'
    ui = load(ui_root / 'manifest.json')
    outputs = {row['path']: row for row in ui['outputs']}
    header_path = ui['unicode_font']['index']
    header_raw = (ui_root / header_path).read_bytes()
    assert digest(header_raw) == outputs[header_path]['sha256']
    header = json.loads(header_raw)
    index_raw = (ui_root / header['index']).read_bytes()
    assert digest(index_raw) == outputs[header['index']]['sha256']
    rows = list(struct.iter_unpack('<IHHHBB', index_raw))
    codes = [row[0] for row in rows]
    result = []
    for character in sorted(set(''.join(labels))):
        if character in ui['glyphs']:
            path = ui['glyphs'][character]['path']
            record = dict(kind='existing-explicit-glyph', path=path)
        else:
            idx = bisect.bisect_left(codes, ord(character))
            assert idx < len(rows) and rows[idx][0] == ord(character), character
            _, page, x, y, w, h = rows[idx]
            path = header['pages'][page - 1]
            record = dict(kind='existing-original-unihex-atlas', path=path, region=[x, y, w, h])
        raw = (ui_root / path).read_bytes()
        assert digest(raw) == outputs[path]['sha256']
        result.append(dict(character=character, codepoint=ord(character), sha256=digest(raw), **record))
    return dict(regenerated=False, glyphs=result, header=header_path, header_sha256=digest(header_raw))


def convert_sounds(write):
    index_path = ASSETS / 'indexes/1.21.1-17.json'
    index_raw = index_path.read_bytes()
    objects = json.loads(index_raw)['objects']
    def read(name):
        entry = objects[name]
        path = ASSETS / 'objects' / entry['hash'][:2] / entry['hash']
        raw = path.read_bytes()
        assert len(raw) == entry['size'] and __import__('hashlib').sha1(raw).hexdigest() == entry['hash']
        return path, raw, entry
    _, catalogue_raw, _ = read('minecraft/sounds.json')
    catalogue = json.loads(catalogue_raw)
    records, events, variants = {}, {}, {}
    (OUT / 'sounds').mkdir(exist_ok=True)
    for key, event in SOUND_EVENTS.items():
        events[key], variants[key] = [], []
        for value in catalogue[event]['sounds']:
            spec = dict(name=value) if isinstance(value, str) else value
            assert spec.get('type', 'sound') == 'sound'
            name = spec['name'].replace('/', '_')
            assert re.fullmatch('[a-z0-9_]+', name)
            events[key].append(name)
            variants[key].append(dict(clip=name, volume=spec.get('volume', 1),
                                      pitch=spec.get('pitch', 1), weight=spec.get('weight', 1)))
            if name in records:
                continue
            source = 'minecraft/sounds/' + spec['name'] + '.ogg'
            path, raw, indexed = read(source)
            info = json.loads(subprocess.check_output([str(FF/'ffprobe.exe'), '-v', 'error',
                                                        '-show_streams', '-of', 'json', str(path)]))
            assert len(info['streams']) == 1 and info['streams'][0]['codec_type'] == 'audio'
            assert 0 < float(info['streams'][0]['duration']) < 60
            output = OUT / 'sounds' / (name + '.pcm')
            command = [str(FF/'ffmpeg.exe'), '-v', 'error', '-y', '-i', str(path),
                       '-ac', '2', '-ar', '44100', '-f', 's16le', str(output)]
            subprocess.run(command, check=True)
            pcm = output.read_bytes()
            assert 0 < len(pcm) <= 60 * 44100 * 4 and len(pcm) % 4 == 0
            write('sounds/' + output.name, pcm, operation='original-ogg-to-s16le-stereo-44100')
            original = 'original/1.21.1/indexed-assets/' + source
            write(original, raw, operation='byte-copy', source=source, source_sha1=indexed['hash'])
            records[name] = dict(name=name, file=output.name, bytes=len(pcm), sha256=digest(pcm),
                                 source=source, source_sha1=indexed['hash'], source_sha256=digest(raw),
                                 original=original, source_codec=info['streams'][0]['codec_name'],
                                 source_channels=info['streams'][0]['channels'],
                                 source_sample_rate=int(info['streams'][0]['sample_rate']),
                                 duration_seconds=len(pcm)/(44100*4))
    assert len(records) == 4
    manifest = dict(schema=1, version='1.21.1', format='s16le', channels=2, sample_rate=44100,
                    event_names=SOUND_EVENTS, events=events, variants=variants, clips=list(records.values()),
                    sounds_json_sha256=digest(catalogue_raw), asset_index_sha256=digest(index_raw),
                    asset_index=str(index_path), encoder=dict(path=str(FF/'ffmpeg.exe'),
                        sha256=digest((FF/'ffmpeg.exe').read_bytes())),
                    event_policy='No-star rocket uses launch only; blast/twinkle are retained original events for explicitly configured explosion components. Flying is an original loop.',
                    native_audio_modified=False, deployed=False)
    write('sounds/manifest.json', encoded(manifest))
    baseline_path = ROOT / 'native/json_bridge/block_audio_catalogue.hpp'
    baseline_raw = baseline_path.read_bytes()
    baseline = re.findall(r'\{"([a-z0-9_]+)", "([0-9a-f]{64})", (\d+)\}', baseline_raw.decode('utf8'))
    clips = {name: (sha, int(size)) for name, sha, size in baseline}
    assert len(clips) == len(baseline)
    new = []
    for name, record in records.items():
        spec = record['sha256'], record['bytes']
        assert name not in clips or clips[name] == spec, name
        if name not in clips:
            new.append(name)
        clips[name] = spec
    lines = ['// Prepared from the current verified native catalogue plus original flight clips.',
             '// Integration requires the bridge rebuild; this file does not install itself.',
             'constexpr ClipSpec clips[] = {']
    lines += [f'    {{"{name}", "{sha}", {size}}},' for name, (sha, size) in clips.items()]
    lines += ['};', '']
    write('sounds/native-audio-catalogue.hpp', '\n'.join(lines).encode('utf8'))
    fragment = '\n'.join(f'    {{"{name}", "{record["sha256"]}", {record["bytes"]}}},'
                         for name, record in records.items()) + '\n'
    write('sounds/native-catalogue-fragment.hpp', fragment.encode('utf8'))
    return dict(manifest='sounds/manifest.json', events=events, clips=len(records),
                baseline_path=baseline_path.relative_to(ROOT).as_posix(),
                baseline_sha256=digest(baseline_raw), baseline_clips=len(baseline),
                added=new, combined_clips=len(clips),
                combined_header='sounds/native-audio-catalogue.hpp',
                fragment_header='sounds/native-catalogue-fragment.hpp')


def preview(wings, meshes, icons, write):
    image = Image.new('RGB', (1280, 620), '#e7ecef')
    draw = ImageDraw.Draw(image)
    for column, state in enumerate(('folded', 'gliding')):
        full = []
        for name, wing in wings.items():
            angles = wing['rotation_rest_radians']
            if state == 'gliding':
                angles = [math.pi/9, 0, -math.pi/2 if name == 'left_wing' else math.pi/2]
            pivot = wing['attachment_pivot_model_pixels']
            full.append(dict(meshes[name], positions=[[p[i] + pivot[i] for i in range(3)]
                                                       for p in map(lambda point: rotate(point, angles), meshes[name]['positions'])]))
        mesh = combine(full)
        points = mesh['positions']
        # View from the model's back, mildly above, retaining original colors.
        angle = math.radians(16)
        projected = [(x, y*math.cos(angle) - z*math.sin(angle),
                      z*math.cos(angle) + y*math.sin(angle)) for x, y, z in points]
        size = min(22, 510/max(max(p[0] for p in projected)-min(p[0] for p in projected), 1),
                   390/max(max(p[1] for p in projected)-min(p[1] for p in projected), 1))
        cx = (max(p[0] for p in projected) + min(p[0] for p in projected))/2
        cy = (max(p[1] for p in projected) + min(p[1] for p in projected))/2
        for i in sorted(range(0, len(projected), 4), key=lambda k: sum(projected[j][2] for j in range(k, k+4))):
            color = tuple(round(c*255) for c in mesh['colors'][i][:3])
            draw.polygon([(column*640+320+(projected[j][0]-cx)*size,
                           265+(projected[j][1]-cy)*size) for j in range(i, i+4)], fill=color)
        draw.text((column*640+20, 20), 'Original MC 1.21.1 elytra / ' + state, fill='#101820')
    for index, (name, icon) in enumerate(icons.items()):
        image.paste(icon.resize((96, 96), Image.Resampling.NEAREST), (30+index*240, 490),
                    icon.resize((96, 96), Image.Resampling.NEAREST))
        draw.text((140+index*240, 530), name, fill='#101820')
    draw.text((620, 530), 'Converted original geometry; not a PBZ runtime capture.', fill='#101820')
    stream = io.BytesIO()
    image.save(stream, format='PNG')
    write('preview.png', stream.getvalue(), operation='evidence-only-original-geometry-render')


def main():
    reference_raw = REFERENCE.read_bytes()
    parts = json.loads(reference_raw)
    offset = [0, 0, 2]
    spec = importlib.util.spec_from_file_location('pinned_elytra_extract', EXTRACTOR)
    extract = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(extract)
    OUT.mkdir(parents=True, exist_ok=True)
    outputs = {}
    def write(relative, raw, **extra):
        path = OUT / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(raw)
        outputs[relative] = dict(path=relative, sha256=digest(raw), bytes=len(raw), **extra)
        return outputs[relative]
    pack = OriginalPack('1.21.1')
    dependencies = {}
    original_texture = 'assets/minecraft/textures/entity/elytra.png'
    texture_raw = pack.read(original_texture, dependencies)
    texture = Image.open(io.BytesIO(texture_raw)).convert('RGBA')
    assert texture.size == (64, 32) and set(texture.getchannel('A').get_flattened_data()) <= {0, 255}
    write('textures/elytra.png', texture_raw, operation='byte-copy', source=original_texture, size=[64, 32])
    meshes, wings = {}, {}
    for name, part in parts.items():
        mesh, stats = wing_mesh(part, texture, extract)
        meshes[name] = mesh
        relative = 'wings/' + name + '.mesh'
        (OUT / 'wings').mkdir(exist_ok=True)
        extract.write_binary(OUT / relative, [dict(name=name, pivot=[0, 0, 0], mesh=mesh)])
        row = write(relative, (OUT/relative).read_bytes(), **stats)
        attachment = [part['original_pivot_model_pixels'][i] + offset[i] for i in range(3)]
        wings[name] = dict(part, path=relative, sha256=row['sha256'], bytes=row['bytes'],
                          binary_pivot=[0, 0, 0], attachment_pivot_model_pixels=attachment,
                          pivot_cm=xyz(attachment), renderer_offset_model_pixels=offset,
                          texture='textures/elytra.png', **stats)
    models, items, icons, image_objects, labels = {}, {}, {}, {}, {}
    translations, label_source = language('1.21.1')
    for item in ('elytra', 'firework_rocket'):
        content_id = 'pbzmc:' + item
        dep = {}
        mesh, info = resolve_model(pack, 'minecraft:item/' + item, dep)
        original_overrides = info.pop('overrides')
        assert (len(original_overrides) == 1) == (item == 'elytra')
        # No durability predicate or broken state enters the runtime fragment.
        info['overrides'] = []
        path = 'items/' + item + '.mesh'
        record = write(path, mesh_bytes(mesh))
        key = '1.21.1/' + resource_path('models', 'minecraft:item/' + item)
        models[key] = dict(path=path, sha256=record['sha256'], bytes=record['bytes'],
                           minecraft_version='1.21.1', model='minecraft:item/' + item,
                           dependencies=['1.21.1/' + p for p in dep], vertices=len(mesh['positions']),
                           indices=len(mesh['triangles']), **info)
        items[content_id] = dict(resource='minecraft:' + item, minecraft_version='1.21.1',
                                 contexts={c: dict(model=key, conditions=[]) for c in CONTEXTS},
                                 variants=[], item_dependencies=[])
        icon_raw = dep[info['texture']]
        image = Image.open(io.BytesIO(icon_raw)).convert('RGBA')
        assert image.size == (16, 16)
        icon_path = 'icons/' + item + '.png'
        icon_row = write(icon_path, icon_raw, operation='byte-copy', source=info['texture'], size=[16, 16])
        label = translations['item.minecraft.' + item]
        icons[content_id] = dict(icon_row, label=label,
                                 label_source=dict(label_source, kind='minecraft-translation', key='item.minecraft.'+item),
                                 minecraft_version='1.21.1', resource='minecraft:' + item,
                                 original_model='minecraft:item/' + item, item_model=key,
                                 dependencies=['1.21.1/' + p for p in dep])
        image_objects[item] = image
        labels[content_id] = dict(text=label, **icons[content_id]['label_source'])
        dependencies.update(dep)
    rocket_key = items['pbzmc:firework_rocket']['contexts']['ground']['model']
    rocket_raw = (OUT / models[rocket_key]['path']).read_bytes()
    rocket = write('world/firework_rocket.mesh', rocket_raw)
    world = dict(path=rocket['path'], sha256=rocket['sha256'], bytes=rocket['bytes'],
                 model=rocket_key, context='ground', display=models[rocket_key]['display']['ground'],
                 scale_for_mesh_bundle=ITEM_SCALE, billboard='camera quaternion before ground display',
                 shot_at_angle_rotations_degrees=[['z', 180], ['y', 180], ['x', 90]],
                 source_class='net/minecraft/client/render/entity/FireworkRocketEntityRenderer',
                 geometry_contract='Same original generated item geometry; no invented solid rocket model; display and camera transforms remain unbaked.')
    particle_definition_path = 'assets/minecraft/particles/firework.json'
    particle_raw = pack.read(particle_definition_path, dependencies)
    definition = json.loads(particle_raw)
    write('particles/firework.json', particle_raw, operation='byte-copy', source=particle_definition_path)
    sprites = []
    for resource in definition['textures']:
        path = resource_path('textures/particle', resource, '.png')
        raw = pack.read(path, dependencies)
        image = Image.open(io.BytesIO(raw)).convert('RGBA')
        assert image.size == (8, 8) and set(image.getchannel('A').get_flattened_data()) <= {0, 255}
        relative = 'particles/' + Path(path).name
        record = write(relative, raw, operation='byte-copy', source=path, size=[8, 8])
        runs = []
        for y in range(8):
            x = 0
            while x < 8:
                rgba = image.getpixel((x, y))
                end = x + 1
                while end < 8 and image.getpixel((end, y)) == rgba:
                    end += 1
                if rgba[3]:
                    runs.append([x, y, end-x, *rgba])
                x = end
        sparkle = particle_mesh(runs)
        mesh_path = relative.removesuffix('.png') + '.mesh'
        mesh_record = write(mesh_path, mesh_bytes(sparkle), vertices=len(sparkle['positions']),
                            indices=len(sparkle['triangles']), operation='exact-original-rgba-runs-billboard')
        sprites.append(dict(resource=resource, path=relative, sha256=record['sha256'],
                            width=8, height=8, runs=runs,
                            mesh=dict(path=mesh_path, sha256=mesh_record['sha256'], bytes=mesh_record['bytes'],
                                      vertices=len(sparkle['positions']), indices=len(sparkle['triangles']))))
    # Exact source RGB, nearest-neighbour tile placement, and explicitly
    # quantized opacity are sufficient for the host's original SlateUI
    # translucent material, which cannot use per-vertex color as opacity.
    # This is a source-image layout/alpha conversion, not drawn particle art.
    opacity_rows = 32
    opacity_values = [.99*(1-row/(opacity_rows-1)) for row in range(opacity_rows)]
    atlas_image = Image.new('RGBA', (8*len(sprites), 8*opacity_rows))
    for column, frame in enumerate(sprites):
        frame_image = Image.open(OUT/frame['path']).convert('RGBA')
        for row, opacity in enumerate(opacity_values):
            for y in range(8):
                for x in range(8):
                    r, g, b, a = frame_image.getpixel((x, y))
                    atlas_image.putpixel((column*8+x, row*8+y), (r, g, b, round(a*opacity)))
    atlas_stream = io.BytesIO()
    atlas_image.save(atlas_stream, format='PNG')
    atlas_record = write('particles/spark_atlas.png', atlas_stream.getvalue(), size=list(atlas_image.size),
                          operation='original-spark-frames-layout-and-quantized-opacity',
                          sources=[dict(path=frame['path'], sha256=frame['sha256']) for frame in sprites])
    atlas = dict(path=atlas_record['path'], sha256=atlas_record['sha256'], bytes=atlas_record['bytes'],
                  size=list(atlas_image.size), columns=len(sprites), opacity_rows=opacity_rows, cell_size=[8, 8],
                  opacity_values=opacity_values, rgb_operation='Original PNG RGB copied per pixel, including transparent texels.',
                  alpha_operation='round(original_alpha * 0.99 * (1 - row / 31))',
                  maximum_opacity_quantization_error=.99/(2*(opacity_rows-1)),
                  animation_contract='Choose frame from original age sprite schedule; choose opacity row nearest the actual original AnimatedParticle alpha, not age/maximum_age.',
                  source_alpha_contract='Factory starts at 0.99; after age > floor(maxAge/2), alpha = 1 - (age - floor(maxAge/2)) / maxAge. It does not fade to zero before expiry.')
    particle = dict(schema=1, minecraft_version='1.21.1', original_definition='particles/firework.json',
                    original_definition_sha256=digest(particle_raw), sprites=sprites, atlas=atlas,
                    frame_order='Original firework.json order: spark_7 to spark_0',
                    frame_index_zero_based='floor(age * (sprite_count - 1) / max_age); for eight sprites floor(age * 7 / max_age)',
                    sprite_provider_source='net/minecraft/client/particle/ParticleManager$SimpleSpriteProvider',
                    run_format=['x', 'y', 'length', 'r', 'g', 'b', 'a'],
                    mesh_contract='mesh_bundle scale=1: UE X=0 plane, +X normal, Y=horizontal right, Z=vertical up. Original full 8x8 sprite extent is [-.5,.5] in Y/Z; set the component or vertex scale to the required world extent. Double-sided indices and exact original sRGB colors.',
                    scale_for_mesh_bundle=1,
                    original_lifecycle=dict(tick_rate=20, max_age_min=48, max_age_random_exclusive=12,
                        full_extent_cm='2 * [0.1 * (random_float * 0.5 + 0.5) * 2 * 0.75] * 100 = 15..30',
                        velocity_multiplier=.91, downward_acceleration_blocks_per_tick_squared=.004,
                        alpha_initial=.99,
                        alpha_after_half='1 - (age - floor(max_age / 2)) / max_age',
                        brightness=15728880),
                    no_star_rocket='Launch trail only. No explosion component means no starburst or blast/twinkle.',
                    source_class='net/minecraft/client/particle/FireworksSparkParticle$Explosion')
    write('particles/spark-frames.json', encoded(particle))
    sounds = convert_sounds(write)
    source_records = []
    for path, raw in dependencies.items():
        retained = 'original/1.21.1/' + path
        write(retained, raw, operation='byte-copy', source=path, minecraft_version='1.21.1')
        source_records.append(dict(version='1.21.1', path=path, sha256=digest(raw), retained=retained))
    fonts = font_coverage([row['text'] for row in labels.values()])
    fragment = dict(schema=1, bundle='assets/private/elytra-firework', models=models, items=items, icons=icons,
                    sources=source_records, labels=labels, font=fonts, sounds=sounds,
                    removal_policy='Only these two ids may be removed from missing/unavailable lists.',
                    no_durability_state=True, shared_manifests_modified=False)
    write('integration-fragments.json', encoded(fragment))
    preview(wings, meshes, image_objects, write)
    write('LICENSE-NOTICE.txt', b'Minecraft textures, models and audio: private local Mojang/Microsoft original client resources; not relicensed.\n'
          b'Converter uses pinned Wukong Steve STEVEM01 writer and cuboid layout under PolyForm Noncommercial 1.0.0.\n'
          b'Retain third_party/wukong-steve/LICENSE and NOTICE. Hashes and source references are in manifest.json.\n'
          b'No decompiled Minecraft source is included in runtime assets.\n')
    write('MODLOG.md', ('# Private original-resource conversion\n\n'
          '- Elytra entity texture: original 64 x 32 RGBA PNG; hard alpha; two independent original wing cubes.\n'
          '- Item icons: original 16 x 16 RGBA PNGs, unchanged bytes; all eight original display contexts resolved.\n'
          '- Wings: original bone-local model pixels, zero binary pivots, mesh_bundle maps (-z,-x,-y), 5.859375 cm/pixel.\n'
          '- Attachment pivots include original renderer z offset of two model pixels. Body parent supplies avatar motion.\n'
          '- Sparks: eight original 8 x 8 hard-alpha PNG frames in original order; exact RGBA runs are metadata only.\n'
          '- Spark atlas: original RGB tile copies, 32 explicit opacity levels from 0.99 to zero; maximum alpha quantization error 0.99/62 before RGBA8 rounding. Original age/alpha selection stays in the controller.\n'
          '- Audio: four original indexed OGG clips decoded to existing s16le stereo 44100 Hz format via pinned local FFmpeg.\n'
          '- Preview is an offline check of the converted geometry; no PBZ runtime or gameplay claim.\n').encode('utf8'))
    recipes = ['convert_elytra_firework_resources.py', 'convert_original_boat.py',
               'convert_original_item_models.py', 'mc_generated_geometry.py']
    manifest = dict(schema=1, private_local_assets=True, format='STEVEM01', minecraft_version='1.21.1',
                     namespace='minecraft', wings=wings, units=dict(scale_for_mesh_bundle=WING_SCALE,
                         pixel_cm=WING_SCALE, item_pixel_cm=ITEM_SCALE, base_block_cm=100, steve_scale=.9375),
                     coordinate_contract='Wing binary stores original MC bone-local (x,y,z), zero pivot. mesh_bundle converts to UE(-z,-x,-y)*5.859375. Attach to Steve body at pivot_cm, which already includes the renderer offset. Do not add the original pivot twice.',
                     rotation_contract='Wing model R = Rz(roll)*Ry(yaw)*Rx(pitch); runtime rotation is P*R*P^-1 with P(x,y,z)=(-z,-x,-y). Item display uses the separate existing generated-item contract.',
                     material_contract='Original hard-alpha holes omitted; exact RGBA rectangles merged only within original cube faces; original no-cull backface index pass; original sRGB vertex colors, no resampling or palette substitution.',
                     pose=dict(rest='rotation_rest_radians per wing', gliding=dict(pitch_min=math.pi/12,
                         pitch_max=math.pi/9, left_roll_min=-math.pi/12, left_roll_max=-math.pi/2,
                         falling_factor='1 - pow(-normalized_velocity_y, 1.5); otherwise 1'),
                         player_smoothing_per_tick=.1, right_mirrors=['yaw', 'roll'],
                         crouch=dict(pitch=2*math.pi/9, left_roll=-math.pi/4, left_yaw=.08726646, pivot_y_model_pixels=3)),
                     items=items, world_firework=world, particles='particles/spark-frames.json',
                     sounds=sounds, labels=labels, font=fonts, integration_fragments='integration-fragments.json',
                     no_durability_state=True, excluded_states=['original broken-elytra predicate/model'],
                     references=[dict(path=REFERENCE.relative_to(ROOT).as_posix(), sha256=digest(reference_raw))],
                     archives={'1.21.1': PACK_HASHES['1.21.1']}, sources=source_records,
                     recipe_sha256={name:digest((ROOT/'tools'/name).read_bytes()) for name in recipes},
                     upstream=dict(commit=PIN, extractor=EXTRACTOR.relative_to(ROOT).as_posix(),
                         sha256=digest(EXTRACTOR.read_bytes()), license='third_party/wukong-steve/LICENSE',
                         notice='third_party/wukong-steve/NOTICE'),
                     totals=dict(wings=2, wing_vertices=sum(w['vertices'] for w in wings.values()),
                         wing_indices=sum(w['indices'] for w in wings.values()), item_models=2,
                         item_contexts=sum(len(i['contexts']) for i in items.values()),
                         spark_frames=len(sprites), audio_clips=sounds['clips']),
                     outputs=list(outputs.values()), evidence_preview=dict(path='preview.png',
                         sha256=outputs['preview.png']['sha256'], runtime_capture=False),
                     shared_manifests_modified=False, deployed=False, runtime_tested=False)
    (OUT/'manifest.json').write_bytes(encoded(manifest))
    pack.archive.close()
    print(json.dumps(dict(**manifest['totals'], audio_baseline=sounds['baseline_clips'],
                          audio_combined=sounds['combined_clips'], outputs=len(outputs),
                          path=str(OUT), shared_manifests_modified=False)))


if __name__ == '__main__':
    main()
