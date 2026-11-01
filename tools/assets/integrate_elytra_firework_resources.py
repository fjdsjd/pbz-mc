"""Plan or apply only the isolated original flight item/UI resource fragment.

Default is a read-only dry run so the owning task can serialize shared edits.
Use --apply for the merge. This never registers gameplay ids, changes fonts,
edits native audio code, deploys to the game, or writes a game save.
"""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path

from asset_paths import ROOT
BUNDLE = ROOT / 'assets/private/elytra-firework'
UI = ROOT / 'assets/private/minecraft-1.21.1/ui'
ITEMS = ROOT / 'assets/private/item-models'


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def load(path):
    return json.loads(path.read_text(encoding='utf8'))


def encoded(value):
    return (json.dumps(value, ensure_ascii=False, indent=2) + '\n').encode('utf8')


def prepare():
    manifest = load(BUNDLE / 'manifest.json')
    assert manifest['schema'] == 1 and manifest['private_local_assets']
    outputs = {row['path']: row for row in manifest['outputs']}
    fragment_raw = (BUNDLE / 'integration-fragments.json').read_bytes()
    assert digest(fragment_raw) == outputs['integration-fragments.json']['sha256']
    fragment = json.loads(fragment_raw)
    im = load(ITEMS / 'manifest.json')
    ui = load(UI / 'manifest.json')
    old_font = dict(ui['unicode_font'])
    ids = set(fragment['items'])
    assert ids == {'pbzmc:elytra', 'pbzmc:firework_rocket'}
    unrelated_items = {k: v for k, v in im['items'].items() if k not in ids}
    unrelated_icons = {k: v for k, v in ui['item_icons'].items() if k not in ids}
    model_outputs = {row['path']: row for row in im['outputs']}
    model_sources = {row['version']+'/'+row['path']: row for row in im['sources']}
    ui_outputs = {row['path']: row for row in ui['outputs']}
    planned_files = {}
    def retain(root, source, relative, expected):
        path = (BUNDLE / source).resolve()
        assert path.is_relative_to(BUNDLE.resolve())
        raw = path.read_bytes()
        assert digest(raw) == expected == outputs[source]['sha256']
        destination = (root / relative).resolve()
        assert destination.is_relative_to(root.resolve())
        if destination.exists():
            # Files specific to this same fragment may be reproduced; unrelated
            # files or hash collisions must not be silently replaced.
            assert destination.read_bytes() == raw, 'conflicting retained resource: '+str(destination)
        planned_files[destination] = raw
        return dict(path=relative, sha256=digest(raw), bytes=len(raw))
    for key, entry in fragment['models'].items():
        row = dict(entry)
        relative = 'minecraft/1.21.1/elytra-firework/' + Path(row['path']).name
        model_outputs[relative] = retain(ITEMS, row['path'], relative, row['sha256'])
        row['path'] = relative
        im['models'][key] = row
    for source in fragment['sources']:
        key = source['version'] + '/' + source['path']
        record = {k: source[k] for k in ('version', 'path', 'sha256')}
        assert key not in model_sources or model_sources[key] == record
        model_sources[key] = record
    im['items'].update(fragment['items'])
    for content_id in ids:
        im.get('unavailable', {}).pop(content_id, None)
    im['outputs'] = list(model_outputs.values())
    im['sources'] = list(model_sources.values())
    for content_id, entry in fragment['icons'].items():
        relative = 'elytra-firework/' + Path(entry['path']).name
        ui_outputs[relative] = dict(retain(UI, entry['path'], relative, entry['sha256']),
                                    size=entry['size'], operation='byte-copy',
                                    source='minecraft-original:1.21.1:' + entry['source'],
                                    source_sha256=entry['sha256'], minecraft_version='1.21.1', namespace='minecraft')
        ui['item_icons'][content_id] = relative
        ui['labels'][content_id] = entry['label']
        ui.setdefault('label_sources', {})[content_id] = entry['label_source']
        ui.setdefault('item_icon_sources', {})[content_id] = dict(
            minecraft_version='1.21.1', resource=entry['resource'], model_dependencies=[relative], conditions=[])
        ui.setdefault('item_visual_sources', {})[content_id] = dict(
            minecraft_version='1.21.1', manifest='elytra-firework/manifest.json',
            original_model=entry['original_model'], item_model=entry['item_model'],
            source_dependencies=entry['dependencies'])
        ui.get('incomplete_item_visuals', {}).pop(content_id, None)
    ui['outputs'] = list(ui_outputs.values())
    ui['missing_item_icons'] = [value for value in ui.get('missing_item_icons', []) if value not in ids]
    if 'missing_item_labels' in ui:
        ui['missing_item_labels'] = [value for value in ui['missing_item_labels']
                                    if (value.get('id') if isinstance(value, dict) else value) not in ids]
    recipe = digest(Path(__file__).read_bytes())
    im.setdefault('recipe_sha256', {})[Path(__file__).name] = recipe
    ui.setdefault('recipe_sha256', {})[Path(__file__).name] = recipe
    assert old_font == ui['unicode_font'] and not fragment['font']['regenerated']
    assert unrelated_items == {k: v for k, v in im['items'].items() if k not in ids}
    assert unrelated_icons == {k: v for k, v in ui['item_icons'].items() if k not in ids}
    planned_files[ITEMS / 'manifest.json'] = encoded(im)
    planned_files[UI / 'manifest.json'] = encoded(ui)
    return planned_files, fragment


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true', help='Apply the already validated item/UI fragment.')
    args = parser.parse_args()
    planned, fragment = prepare()
    changes = []
    for path, raw in planned.items():
        existing = path.read_bytes() if path.exists() else None
        if existing == raw:
            continue
        changes.append(dict(path=path.relative_to(ROOT).as_posix(), bytes=len(raw), sha256=digest(raw),
                            previous_sha256=digest(existing) if existing is not None else None))
    if args.apply:
        for path, raw in planned.items():
            path.parent.mkdir(parents=True, exist_ok=True)
            if not path.exists() or path.read_bytes() != raw:
                path.write_bytes(raw)
        for path, raw in planned.items():
            assert path.read_bytes() == raw
    print(json.dumps(dict(mode='applied' if args.apply else 'dry-run', items=len(fragment['items']),
                          models=len(fragment['models']), changed_files=changes,
                          font_regenerated=False, gameplay_registration_modified=False,
                          native_audio_modified=False, deployed=False), ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
