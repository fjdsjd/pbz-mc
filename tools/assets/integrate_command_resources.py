"""Bind converted original command-block icons, labels and widgets to the UI."""
from collections import Counter
from hashlib import sha256
import json
from pathlib import Path
import re

from asset_paths import ROOT
from convert_command_blocks import CLIENT_SHA256, LANGUAGE_SHA256, NAMES


def digest(raw):
    return sha256(raw).hexdigest()


def integrate(ui, bundle, definitions):
    manifest_path = ui / 'manifest.json'
    manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
    original = json.loads((bundle / 'source_manifest.json').read_text(encoding='utf-8'))
    blocks = json.loads((bundle / 'manifest.json').read_text(encoding='utf-8'))
    widgets_path = ui / 'command/manifest.json'
    widgets_raw = widgets_path.read_bytes()
    widgets = json.loads(widgets_raw)
    assert original['client']['sha256'] == widgets['archive_sha256'] == CLIENT_SHA256
    assert original['language']['sha256'] == widgets['language_sha256'] == LANGUAGE_SHA256
    images = {row['path']: row for row in manifest['outputs']}
    for name in NAMES:
        item_id = 'pbzmc:' + name
        icon = original['icons'][name]
        raw = (ui / icon['path']).read_bytes()
        assert digest(raw) == icon['sha256']
        resource = 'assets/minecraft/items/' + name + '.json'
        dependencies = [dict(path=path, sha256=value['sha256'])
                        for path, value in sorted(original['source_files'].items())
                        if path == resource or path == 'assets/minecraft/models/block/block.json'
                        or '/models/block/' + name in path or '/textures/block/' + name + '_' in path]
        images[icon['path']] = dict(path=icon['path'], sha256=icon['sha256'], bytes=len(raw), size=[64, 64],
                                   source='minecraft-original:26.3:' + resource,
                                   source_sha256=original['source_files'][resource]['sha256'],
                                   operation='render-original-block-model', minecraft_version='26.3',
                                   namespace='minecraft', source_dependencies=dependencies)
        manifest['item_icons'][item_id] = icon['path']
        manifest['labels'][item_id] = blocks['blocks'][name]['label']
        manifest.setdefault('label_sources', {})[item_id] = dict(
            source='assets/private/minecraft-original/26.3/indexed-assets/minecraft/lang/zh_cn.json',
            sha256=LANGUAGE_SHA256, minecraft_version='26.3', key='block.minecraft.' + name,
            kind='minecraft-translation')
        visual = dict(minecraft_version='26.3', manifest='command-blocks/manifest.json',
                      provenance='command-blocks/source_manifest.json', original_model=resource,
                      source_dependencies=dependencies)
        manifest.setdefault('item_visual_sources', {})[item_id] = visual
        manifest.setdefault('item_icon_sources', {})[item_id] = dict(
            resource='minecraft:' + name, minecraft_version='26.3',
            manifest='command-blocks/source_manifest.json', source_dependencies=dependencies)
        manifest.get('incomplete_item_visuals', {}).pop(item_id, None)
        for key in ('missing_item_icons', 'missing_item_labels'):
            manifest[key] = [row for row in manifest.get(key, [])
                             if (row.get('id') if isinstance(row, dict) else row) != item_id]
    for row in widgets['outputs']:
        assert digest((ui / row['path']).read_bytes()) == row['sha256']
        images[row['path']] = row
    images['command/manifest.json'] = dict(path='command/manifest.json', sha256=digest(widgets_raw),
        bytes=len(widgets_raw), operation='index-original-command-widgets', minecraft_version='26.3')
    manifest['command_editor'] = dict(manifest='command/manifest.json', minecraft_version='26.3',
                                       archive_sha256=CLIENT_SHA256, language_sha256=LANGUAGE_SHA256)
    manifest['outputs'] = list(images.values())
    ids = re.findall(r"^\s*\['([^']+)'\]=", definitions.decode('utf-8'), re.MULTILINE)
    assert ids and len(ids) == len(set(ids)), 'command-ui-item-definitions'
    missing = sorted(set(ids) - set(manifest['labels']))
    prior = manifest.get('label_coverage', {})
    manifest['label_coverage'] = dict(prior, definitions=len(ids), covered=len(ids) - len(missing),
        definitions_sha256=digest(definitions), missing=missing,
        by_source=dict(Counter(manifest['label_sources'].get(item_id, {}).get('kind', 'unknown')
                               for item_id in ids if item_id in manifest['labels'])))
    assert not missing, 'command-ui-label-coverage:' + ','.join(missing)
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    return dict(command_blocks=len(NAMES), widgets=len(widgets['widgets']), labels=len(ids),
                ui_outputs=len(images), manifest_sha256=digest(manifest_path.read_bytes()))


def main():
    result = integrate(ROOT / 'assets/private/minecraft-1.21.1/ui', ROOT / 'assets/private/command-blocks',
                       (ROOT / 'src/content/items.lua').read_bytes())
    print(json.dumps(result, ensure_ascii=False))


if __name__ == '__main__':
    main()
