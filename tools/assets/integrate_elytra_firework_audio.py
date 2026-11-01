"""Incrementally merge original flight sounds, then regenerate the native bank.

Native playback preloads the flat pbzmc-assets/sounds install directory. Keep
the independent source bundle and also publish four verified PCM files/events
in the existing source root. No bridge compilation or game deployment occurs.
"""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

from asset_paths import ROOT
SOURCE = ROOT/'assets/private/elytra-firework/sounds'
TARGET = ROOT/'assets/private/minecraft-1.21.1/sounds'
HEADER = ROOT/'native/json_bridge/block_audio_catalogue.hpp'
EVENTS = {'launch': 'firework_launch', 'blast': 'firework_blast',
          'twinkle': 'firework_twinkle', 'flying': 'elytra_flying'}


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def load(path):
    return json.loads(path.read_text(encoding='utf8'))


def encoded(value):
    return (json.dumps(value, ensure_ascii=False, indent=2)+'\n').encode('utf8')


def native_clips(raw):
    rows = re.findall(r'\{"([a-z0-9_]+)", "([0-9a-f]{64})", (\d+)\}', raw.decode('utf8'))
    result = {name: (digest, int(size)) for name, digest, size in rows}
    assert len(result) == len(rows)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    source_raw = (SOURCE/'manifest.json').read_bytes()
    source = json.loads(source_raw)
    bundle = load(SOURCE.parent/'manifest.json')
    record, = [row for row in bundle['outputs'] if row['path'] == 'sounds/manifest.json']
    assert sha(source_raw) == record['sha256']
    target_raw = (TARGET/'manifest.json').read_bytes()
    target = json.loads(target_raw)
    expected = ('s16le', 2, 44100)
    assert tuple(target[key] for key in ('format', 'channels', 'sample_rate')) == expected
    assert tuple(source[key] for key in ('format', 'channels', 'sample_rate')) == expected
    before_clips = {row['name']: row for row in target['clips']}
    current_clips = dict(before_clips)
    before_events = {key: dict(target.get(key, {})) for key in ('events', 'event_names', 'variants')}
    copies = {}
    for clip in source['clips']:
        assert clip['file'] == clip['name']+'.pcm' and re.fullmatch('[a-z0-9_]+', clip['name'])
        raw = (SOURCE/clip['file']).read_bytes()
        assert len(raw) == clip['bytes'] and sha(raw) == clip['sha256']
        if clip['name'] in current_clips:
            old = current_clips[clip['name']]
            assert (old['sha256'], old['bytes']) == (clip['sha256'], clip['bytes'])
        else:
            current_clips[clip['name']] = dict(clip, bundle='assets/private/elytra-firework',
                                              original='assets/private/elytra-firework/'+clip['original'])
        destination = TARGET/clip['file']
        assert not destination.exists() or destination.read_bytes() == raw
        copies[destination] = raw
    for key, alias in EVENTS.items():
        for kind in ('events', 'event_names', 'variants'):
            value = source[kind][key]
            current = target.setdefault(kind, {})
            assert alias not in current or current[alias] == value, 'event collision: '+alias
            current[alias] = value
    target['clips'] = list(current_clips.values())
    target.setdefault('extensions', {})['elytra_firework'] = dict(
        source_manifest='assets/private/elytra-firework/sounds/manifest.json',
        source_manifest_sha256=sha(source_raw), events=EVENTS,
        recipe='tools/integrate_elytra_firework_audio.py', recipe_sha256=sha(Path(__file__).read_bytes()),
        event_policy=source['event_policy'])
    # Every pre-existing record and alias survives exactly, not only by count.
    assert all(current_clips[name] == value for name, value in before_clips.items())
    assert all(target[kind][name] == value for kind, entries in before_events.items() for name, value in entries.items())
    copies[TARGET/'manifest.json'] = encoded(target)
    previous_header = HEADER.read_bytes()
    baseline = native_clips(previous_header)
    expected_bank = dict(baseline)
    for clip in source['clips']:
        spec = (clip['sha256'], clip['bytes'])
        assert clip['name'] not in expected_bank or expected_bank[clip['name']] == spec
        expected_bank[clip['name']] = spec
    assert len(expected_bank) == 134
    report = dict(schema=1, mode='applied' if args.apply else 'dry-run',
        baseline_native_clips=len(baseline), target_native_clips=len(expected_bank),
        previous_native_header_sha256=sha(previous_header), root_clips_before=len(before_clips),
        root_clips_after=len(current_clips), root_manifest_before_sha256=sha(target_raw),
        events=EVENTS, install_directory='ue4ss/Mods/PBZMCProbe/Scripts/pbzmc-assets/sounds',
        source_files=[dict(path=str(path.relative_to(ROOT).as_posix()), sha256=sha(raw), bytes=len(raw))
                      for path, raw in copies.items()],
        original_native_records_preserved=True, original_root_records_preserved=True,
        font_regenerated=False, native_dll_compiled=False, deployed=False)
    if args.apply:
        for path, raw in copies.items():
            if not path.exists() or path.read_bytes() != raw:
                path.write_bytes(raw)
        subprocess.run([sys.executable, str(ROOT/'tools/build_audio_catalogue.py')], check=True)
        actual_header = HEADER.read_bytes()
        actual = native_clips(actual_header)
        assert actual == expected_bank
        assert all(actual[name] == value for name, value in baseline.items())
        assert all(path.read_bytes() == raw for path, raw in copies.items())
        report.update(native_header_sha256=sha(actual_header), native_clips_after=len(actual),
                      root_manifest_after_sha256=sha((TARGET/'manifest.json').read_bytes()))
        evidence = ROOT/'conversion-reports/elytra-firework-audio.json'
        evidence.write_bytes(encoded(report))
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
