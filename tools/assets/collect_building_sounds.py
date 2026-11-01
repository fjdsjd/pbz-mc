"""Decode original material-specific block events from the local MC asset index.

Does not change the existing combat/dirt or TNT manifests. PCM names remain
the original names so the fixed native bank can safely de-duplicate grass.
"""
from pathlib import Path
import hashlib
import json
import subprocess

from asset_paths import ROOT
ASSETS = (ROOT / 'inputs/assets')
FF = (ROOT / 'inputs/ffmpeg')
OUT = ROOT / 'assets/private/building-blocks/sounds'
GROUPS = ('grass', 'gravel', 'stone', 'wood', 'glass')
ACTIONS = {
    'hit': {'volume_add': 1, 'volume_divisor': 8, 'pitch_multiplier': .5},
    'place': {'volume_add': 1, 'volume_divisor': 2, 'pitch_multiplier': .8},
    'break': {'volume_add': 1, 'volume_divisor': 2, 'pitch_multiplier': .8},
}


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def main():
    index_path = ASSETS / 'indexes/1.21.1-17.json'
    index = index_path.read_bytes()
    entries = json.loads(index)['objects']

    def read(name):
        row = entries[name]
        path = ASSETS / 'objects' / row['hash'][:2] / row['hash']
        raw = path.read_bytes()
        assert len(raw) == row['size'] and hashlib.sha1(raw).hexdigest() == row['hash'], name
        return path, raw

    _, sound_raw = read('minecraft/sounds.json')
    sounds = json.loads(sound_raw)
    OUT.mkdir(parents=True, exist_ok=True)
    clips, groups, events, variants, event_names = {}, {}, {}, {}, {}
    for group in GROUPS:
        groups[group] = {'sound_type': group.upper(), 'volume': 1, 'pitch': 1, 'events': {}}
        for kind in ACTIONS:
            event = f'block.{group}.{kind}'
            key = group + '_' + kind
            event_names[key] = event
            events[key], variants[key] = [], []
            for source in sounds[event]['sounds']:
                spec = {'name': source} if isinstance(source, str) else source
                assert spec.get('type', 'sound') == 'sound', (event, spec)
                name = spec['name'].replace('/', '_')
                events[key].append(name)
                variants[key].append({'clip': name, 'volume': spec.get('volume', 1),
                                      'pitch': spec.get('pitch', 1), 'weight': spec.get('weight', 1)})
                if name in clips:
                    continue
                member = 'minecraft/sounds/' + spec['name'] + '.ogg'
                path, raw = read(member)
                probe = json.loads(subprocess.check_output([
                    str(FF / 'ffprobe.exe'), '-v', 'error', '-show_streams', '-of', 'json', str(path)]))
                assert len(probe['streams']) == 1
                stream = probe['streams'][0]
                assert stream['codec_type'] == 'audio' and float(stream['duration']) < 10
                target = OUT / (name + '.pcm')
                subprocess.run([str(FF / 'ffmpeg.exe'), '-v', 'error', '-y', '-i', str(path),
                                '-ac', '2', '-ar', '44100', '-f', 's16le', str(target)], check=True)
                pcm = target.read_bytes()
                assert 0 < len(pcm) <= 10 * 44100 * 4 and len(pcm) % 4 == 0
                clips[name] = {'name': name, 'file': target.name, 'bytes': len(pcm), 'sha256': digest(pcm),
                               'source': member, 'source_sha1': hashlib.sha1(raw).hexdigest(),
                               'source_sha256': digest(raw), 'source_codec': stream['codec_name'],
                               'source_channels': stream['channels'], 'source_sample_rate': int(stream['sample_rate']),
                               'duration_seconds': len(pcm) / (44100 * 4)}
            groups[group]['events'][kind] = {'event': event, 'variants': variants[key]}
    manifest = {'schema': 1, 'profile': 'minecraft-block-sound-groups-v1', 'version': '1.21.1',
                'format': 's16le', 'channels': 2, 'sample_rate': 44100,
                'actions': ACTIONS, 'groups': groups, 'events': events, 'variants': variants,
                'event_names': event_names, 'clips': list(clips.values()),
                'sounds_json_sha256': digest(sound_raw), 'asset_index_sha256': digest(index),
                'asset_index': str(index_path), 'recipe_sha256': digest(Path(__file__).read_bytes()),
                'encoder': {'path': str(FF / 'ffmpeg.exe'), 'sha256': digest((FF / 'ffmpeg.exe').read_bytes())},
                'pcm_install_directory': 'pbzmc-assets/sounds',
                'manifest_install_path': 'pbzmc-assets/building-blocks/sounds/manifest.json',
                'deployed': False}
    (OUT / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({'groups': list(groups), 'events': len(events), 'clips': len(clips),
                      'pcm_bytes': sum(c['bytes'] for c in clips.values()), 'deployed': False}))


if __name__ == '__main__':
    main()
