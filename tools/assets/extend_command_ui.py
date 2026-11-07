"""Copy pinned vanilla command-editor widgets into a private UI asset pack.

The sprites retain the original pixels; PNGs are normalized to RGBA because
Unreal imports vanilla grayscale PNGs as red-channel textures. Nine-slice
metadata remains byte-for-byte original. The
manifest is separate from the inventory UI so the converter is repeatable and
does not replace resources produced by other converters.
"""
from __future__ import annotations

import argparse
from hashlib import sha256
from io import BytesIO
import json
from pathlib import Path
import zipfile

from PIL import Image
from asset_paths import ROOT

CLIENT_SHA256 = '4508d006323f24fa02876310c192d739af56516eb259000ac50f0909a68c9a2d'
LANGUAGE_SHA256 = '7c58c6e3502d5643e92ed754ce7b5bb3bdedfeba1a09534165433c7c36260f2c'
BORDERS = dict(button=3, button_highlighted=3, button_disabled=1,
               text_field=1, text_field_highlighted=1)
BOSS_COLORS = ('pink', 'blue', 'red', 'green', 'yellow', 'purple', 'white')
BOSS_STYLES = ('notched_6', 'notched_10', 'notched_12', 'notched_20')
LABELS = dict(set_command='advMode.setCommand', command='advMode.command',
              previous_output='advMode.previousOutput', track_output='advMode.trackOutput',
              impulse='advMode.mode.redstone', repeat='advMode.mode.auto',
              chain='advMode.mode.sequence', conditional='advMode.mode.conditional',
              unconditional='advMode.mode.unconditional', always_active='advMode.mode.autoexec.bat',
              needs_redstone='advMode.mode.redstoneTriggered', done='gui.done', cancel='gui.cancel')


def digest(raw):
    return sha256(raw).hexdigest()


def convert(jar: Path, ui: Path, language: Path):
    archive_hash = digest(jar.read_bytes())
    assert archive_hash == CLIENT_SHA256, 'command-ui-source-jar-sha256-mismatch'
    language_raw = language.read_bytes()
    assert digest(language_raw) == LANGUAGE_SHA256, 'command-ui-language-sha256-mismatch'
    translations = json.loads(language_raw)
    outputs, widgets, sources, bossbars = [], {}, {}, {}

    def copy(source, raw, **extra):
        original = raw
        operation = 'byte-copy'
        if source.endswith('.png'):
            image = Image.open(BytesIO(original)).convert('RGBA')
            buffer = BytesIO()
            image.save(buffer, format='PNG')
            raw = buffer.getvalue()
            operation = 'rgba-pixel-copy'
        target = 'command/original/minecraft/26.3/' + source.removeprefix('assets/minecraft/')
        destination = ui / target
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(raw)
        record = dict(path=target, sha256=digest(raw), bytes=len(raw),
                      source='minecraft-original:26.3:' + source,
                      source_sha256=digest(original), operation=operation,
                      minecraft_version='26.3', namespace='minecraft', **extra)
        outputs.append(record)
        sources[source] = dict(sha256=digest(original), bytes=len(original))
        return target

    with zipfile.ZipFile(jar) as archive:
        for name, border in BORDERS.items():
            source = 'assets/minecraft/textures/gui/sprites/widget/' + name + '.png'
            raw, metadata = archive.read(source), archive.read(source + '.mcmeta')
            assert Image.open(BytesIO(raw)).size == (200, 20), source
            scaling = json.loads(metadata)['gui']['scaling']
            assert scaling == dict(type='nine_slice', width=200, height=20, border=border), source
            target = copy(source, raw, size=[200, 20])
            copy(source + '.mcmeta', metadata)
            widgets[name] = dict(path=target, width=200, height=20, border=border)
        for name in BOSS_COLORS + BOSS_STYLES:
            pair = {}
            for layer in ('background', 'progress'):
                source = f'assets/minecraft/textures/gui/sprites/boss_bar/{name}_{layer}.png'
                raw = archive.read(source)
                assert Image.open(BytesIO(raw)).size == (182, 5), source
                pair[layer] = copy(source, raw, size=[182, 5])
            bossbars[name] = pair
    copy('assets/minecraft/lang/zh_cn.json', language_raw)
    manifest = dict(schema=1, minecraft_version='26.3', layout_profile='java-command-widgets-v1',
                    archive_sha256=archive_hash, language_sha256=digest(language_raw),
                    widgets=widgets, bossbars=bossbars,
                    labels={key: translations[value] for key, value in LABELS.items()},
                    label_sources=LABELS, outputs=outputs, sources=sources)
    path = ui / 'command/manifest.json'
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    return dict(widgets=len(widgets), copied_files=len(outputs), manifest_sha256=digest(path.read_bytes()))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--jar', type=Path, default=ROOT / 'inputs/26.3.jar')
    parser.add_argument('--ui', type=Path, default=ROOT / 'assets/private/minecraft-1.21.1/ui')
    parser.add_argument('--language', type=Path,
                        default=ROOT / 'assets/private/minecraft-original/26.3/indexed-assets/minecraft/lang/zh_cn.json')
    args = parser.parse_args()
    print(json.dumps(convert(args.jar, args.ui, args.language), ensure_ascii=False))


if __name__ == '__main__':
    main()
