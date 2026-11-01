"""Fill UI labels from verified local MC translations and the pinned upstream.

Names are read from their original localization/Label methods, not written as
an independent name table. Only private UI metadata and evidence are changed.
"""
from __future__ import annotations
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import subprocess

from asset_paths import ROOT
UI = ROOT / 'assets/private/minecraft-1.21.1/ui'
UPSTREAM = ROOT / 'third_party/wukong-steve'
PIN = '9f213556519dca4498fd46f02af6236ae121ecae'
STR = r'"(?:\\.|[^"\\])*"'


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def upstream_file(name):
    relative = 'src/SteveTransformation/' + name
    path = UPSTREAM / relative
    raw = path.read_bytes()
    original = raw
    return raw.decode('utf-8-sig'), dict(source=path.relative_to(ROOT).as_posix(),
                                       sha256=digest(raw), git_blob_sha256=digest(original), commit=PIN)


def language(version):
    base = ROOT / 'assets/private/minecraft-original' / version
    imported = json.loads((base / 'IMPORT_MANIFEST.json').read_text(encoding='utf-8'))
    assert imported['version'] == version
    relative = 'indexed-assets/minecraft/lang/zh_cn.json'
    entry, = [item for item in imported['files'] if item['path'] == relative]
    raw = (base / relative).read_bytes()
    assert len(raw) == entry['bytes'] and digest(raw) == entry['sha256']
    assert hashlib.sha1(raw).hexdigest() == entry['asset_sha1']
    return json.loads(raw), dict(source=(base / relative).relative_to(ROOT).as_posix(),
                                sha256=digest(raw), asset_sha1=entry['asset_sha1'], minecraft_version=version)


def literals(body):
    return {name: json.loads(value) for name, value in re.findall(r'McItem\.(\w+)\s*=>\s*(' + STR + ')', body)}


def main():
    definitions = (ROOT / 'src/content/items.lua').read_bytes()
    ids = re.findall(r"^\s*\['([^']+)'\]=", definitions.decode('utf-8'), re.MULTILINE)
    assert ids and len(ids) == len(set(ids)), 'Duplicate or missing actual item definitions'
    mapping_raw = (ROOT / 'src/content/upstream_ids.json').read_bytes()
    mapping = json.loads(mapping_raw)
    assert mapping['baseline'] == PIN
    enums = {id: enum for enum, id in mapping['items'].items()}
    inventory, inv_source = upstream_file('MinecraftInventory.cs')
    adventure, adv_source = upstream_file('AdventureItems.cs')
    weapons, weapon_source = upstream_file('MinecraftWeapons.cs')
    assert inv_source['sha256'] == mapping['source_sha256']
    asset_body = inventory.split('internal static string Asset(McItem item) => item switch', 1)[1].split('};', 1)[0]
    label_body = inventory.split('internal static string Label(McItem item) => item switch', 1)[1].split('};', 1)[0]
    adv_label_body = adventure.split('internal static string? Label(McItem item)', 1)[1].split('internal static double Reinforcement', 1)[0]
    aliases = literals(asset_body)
    inv_labels, adv_labels = literals(label_body), literals(adv_label_body)
    # These two source expressions define all upstream spear label variants.
    # Parse their actual text and preserve the source-derived material/level rule.
    spear_expression = label_body.split('_ when MinecraftWeapons.IsSpear(item)=>', 1)[1].split('McItem.Sword=>', 1)[0]
    arrays = re.findall(r'new\[\]\{([^}]+)\}', spear_expression)
    assert len(arrays) == 2
    spear_names = [json.loads(value) for value in re.findall(STR, arrays[0])]
    levels = [json.loads(value) for value in re.findall(STR, arrays[1])]
    affix = json.loads(re.search(r'Lunge\(item\)>0\?(' + STR + r')', spear_expression).group(1))
    assert len(spear_names) == 7 and len(levels) == 4
    assert 'item==McItem.NetheriteSpearLungeI?1:item==McItem.NetheriteSpearLungeII?2:3' in weapons
    assert 'item<=McItem.NetheriteSpearLungeIII?(int)item-(int)McItem.WoodenSpearLungeIII:6' in weapons
    enum_names = [value.strip() for value in re.search(r'internal enum McItem\s*\{([^}]+)\}', inventory).group(1).split(',')]
    positions = {name: index for index, name in enumerate(enum_names)}

    def spear_label(enum):
        if enum not in positions:
            return None
        index = positions[enum]
        if not positions['WoodenSpear'] <= index <= positions['NetheriteSpearLungeII']:
            return None
        material = (index - positions['WoodenSpear'] if index <= positions['NetheriteSpear'] else
                    index - positions['WoodenSpearLungeIII'] if index <= positions['NetheriteSpearLungeIII'] else 6)
        level = 0 if index <= positions['NetheriteSpear'] else 1 if enum == 'NetheriteSpearLungeI' else 2 if enum == 'NetheriteSpearLungeII' else 3
        return spear_names[material] + (affix + levels[level] if level else '')

    manifest = json.loads((UI / 'manifest.json').read_text(encoding='utf-8'))
    languages = {version: language(version) for version in ('1.21.1', '26.3')}
    label_sources, missing = {}, []
    for id in ids:
        name = id.split(':', 1)[1]
        enum = enums.get(id)
        version = manifest.get('item_icon_sources', {}).get(id, {}).get('minecraft_version', '1.21.1')
        assert version in languages, f'Unsupported original label resource version: {version}'
        label, source = None, None
        for version in dict.fromkeys((version, '1.21.1', '26.3')):
            data, provenance = languages[version]
            for resource in dict.fromkeys((name, aliases.get(enum))):
                if not resource:
                    continue
                key = next((prefix + resource for prefix in ('item.minecraft.', 'block.minecraft.') if prefix + resource in data), None)
                if key:
                    label = data[key]
                    source = dict(provenance, kind='minecraft-translation', key=key)
                    if resource != name:
                        source['alias_from_upstream'] = dict(inv_source, member='MinecraftInventory.Asset', enum=enum)
                    break
            if label is not None:
                break
        if label is None and enum in adv_labels:
            label = adv_labels[enum]
            source = dict(adv_source, kind='upstream-label', member='AdventureItems.Label', enum=enum)
        if label is None and enum in inv_labels:
            label = inv_labels[enum]
            source = dict(inv_source, kind='upstream-label', member='MinecraftInventory.Label', enum=enum)
        if label is None:
            label = spear_label(enum)
            if label is not None:
                source = dict(inv_source, kind='upstream-derived-label', member='MinecraftInventory.Label', enum=enum,
                              rules=dict(weapon_source, members=['Material', 'Lunge']))
        if label is None:
            missing.append(dict(id=id, reason='No original MC translation or pinned upstream Label source found'))
            manifest['labels'].pop(id, None)
            continue
        assert isinstance(label, str) and label.strip(), f'Empty source label: {id}'
        manifest['labels'][id] = label
        label_sources[id] = source
    assert set(manifest['labels']) <= set(ids), 'Stale labels outside actual item definitions'
    counts = Counter(source['kind'] for source in label_sources.values())
    manifest['label_sources'] = label_sources
    manifest['missing_item_labels'] = missing
    manifest['label_coverage'] = dict(definitions=len(ids), covered=len(label_sources), by_source=dict(counts),
                                    definitions_sha256=digest(definitions), upstream_ids_sha256=digest(mapping_raw), missing=missing)
    (UI / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding='utf-8')
    evidence = ROOT / 'conversion-reports/item-label-values-20261101.json'
    evidence.write_text(json.dumps(dict(rows=[dict(id=id, value=manifest['labels'][id]) for id in ids if id in label_sources],
                                       coverage=manifest['label_coverage'], sources=label_sources), ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps(manifest['label_coverage'], ensure_ascii=True))


if __name__ == '__main__':
    main()
