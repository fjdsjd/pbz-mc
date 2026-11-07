"""Convert pinned Java 26.3 weapon events into the PBZMC PCM format."""
import hashlib
import json
import subprocess

from asset_paths import ROOT


SPEAR_EVENTS = {f'{material}_{action}': f'item.{material}.{action}'
                for material in ('spear', 'spear_wood') for action in ('attack', 'hit', 'use')}


def convert(assets, ffmpeg, output, selected=SPEAR_EVENTS, *, clip_prefix=''):
    index = (assets / 'indexes/26.3-34.json').read_bytes()
    objects = json.loads(index)['objects']

    def read(name):
        row = objects[name]
        path = assets / 'objects' / row['hash'][:2] / row['hash']
        raw = path.read_bytes()
        if len(raw) != row['size'] or hashlib.sha1(raw).hexdigest() != row['hash']:
            raise ValueError(f'Invalid Minecraft 26.3 asset: {name}')
        return path, raw

    _, catalogue = read('minecraft/sounds.json')
    sounds = json.loads(catalogue)
    output.mkdir(parents=True, exist_ok=True)
    events, variants, event_names, clips = {}, {}, {}, {}
    for key, event in selected.items():
        event_names[key] = event
        events[key], variants[key] = [], []
        for entry in sounds[event]['sounds']:
            sound = {'name': entry} if isinstance(entry, str) else entry
            if sound.get('type', 'sound') != 'sound':
                raise ValueError(f'Indirect sound in pinned event {event}')
            name = clip_prefix + sound['name'].replace('/', '_')
            events[key].append(name)
            variants[key].append(dict(clip=name, volume=sound.get('volume', 1),
                                      pitch=sound.get('pitch', 1), weight=sound.get('weight', 1)))
            if name in clips:
                continue
            member = f"minecraft/sounds/{sound['name']}.ogg"
            path, raw = read(member)
            info = subprocess.check_output([ffmpeg / 'ffprobe.exe', '-v', 'error',
                                            '-show_streams', '-of', 'json', path])
            stream, = json.loads(info)['streams']
            if stream['codec_name'] != 'vorbis' or not 0 < float(stream['duration']) <= 10:
                raise ValueError(f'Invalid weapon audio stream: {member}')
            pcm = subprocess.check_output([ffmpeg / 'ffmpeg.exe', '-nostdin', '-v', 'error',
                                           '-i', path, '-ac', '2', '-ar', '44100', '-f', 's16le', '-'])
            if not pcm or len(pcm) % 4 or len(pcm) > 44100 * 4 * 10:
                raise ValueError(f'Invalid weapon PCM: {member}')
            file = name + '.pcm'
            (output / file).write_bytes(pcm)
            clips[name] = dict(name=name, file=file, bytes=len(pcm), sha256=hashlib.sha256(pcm).hexdigest(),
                               source=member, source_sha1=hashlib.sha1(raw).hexdigest(),
                               source_sha256=hashlib.sha256(raw).hexdigest(), duration_seconds=len(pcm) / (44100 * 4))

    manifest = dict(version='26.3', events=events, event_names=event_names, variants=variants,
                    clips=list(clips.values()), sounds_json_sha256=hashlib.sha256(catalogue).hexdigest(),
                    asset_index_sha256=hashlib.sha256(index).hexdigest())
    (output / 'manifest.json').write_bytes((json.dumps(manifest, indent=2) + '\n').encode('utf-8'))


if __name__ == '__main__':
    convert(ROOT / 'inputs/assets', ROOT / 'inputs/ffmpeg', ROOT / 'assets/private/spear/sounds')
