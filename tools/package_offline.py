"""Assemble a public cache-only installer or a personal offline bundle."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import shutil
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def child(root, relative):
    parts = PurePosixPath(relative).parts
    if not parts or '\\' in relative or ':' in relative or '..' in parts or relative.startswith('/'):
        raise ValueError('Unsafe package path: ' + relative)
    path = root.joinpath(*parts)
    if not path.resolve().is_relative_to(root.resolve()):
        raise ValueError('Package path escapes root')
    current = path
    while current != root:
        if current.is_symlink() or (hasattr(current, 'is_junction') and current.is_junction()):
            raise ValueError('Linked input rejected: ' + relative)
        current = current.parent
    return path


def write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n', encoding='utf-8', newline='\n')


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--release', type=Path, required=True, help='Audited online release stage directory')
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument('--assets', type=Path, help='Personal bundle with resources from this verified runtime-assets directory')
    mode.add_argument('--cache-only', action='store_true', help='Public installer. Include the hash list and use the player\'s own resources.')
    ap.add_argument('--output', type=Path, required=True, help='New empty output directory')
    args = ap.parse_args()
    release, output = args.release.resolve(), args.output.resolve()
    assets = args.assets.resolve() if args.assets else None
    if output.exists() and any(output.iterdir()):
        raise ValueError('Choose a new output directory; existing packages are never replaced')
    manifest = json.loads((release/'PBZMC/release.json').read_text('utf-8'))
    recipe_file = ROOT/'distribution/asset-recipes/runtime-files.json'
    recipe = json.loads(recipe_file.read_text('utf-8'))
    if sha(recipe_file) != manifest['asset_recipe_sha256']:
        raise ValueError('Release and resource recipe differ')
    expected = {name: row['sha256'] for name, row in recipe.items()}
    if assets:
        ready = json.loads((assets/'ready.json').read_text('utf-8'))
        if ready['recipe'] != manifest['asset_recipe_sha256']:
            raise ValueError('Prepared resources use a different recipe')
        actual = {row['path']: row['sha256'] for row in ready['files']}
        if expected != actual or len(actual) != len(ready['files']):
            raise ValueError('Incomplete or altered runtime resource list')
    # Validate everything before creating an output package. Never include a
    # user's save, source archives, conversion work or stale cache files.
    for row in manifest['files']:
        path = child(release/'PBZMC/payload', row['path'])
        if sha(path) != row['sha256']:
            raise ValueError('Damaged release input: ' + row['path'])
    if assets:
        for relative, expected_hash in expected.items():
            path = child(assets, relative)
            if not path.is_file() or ('bytes' in recipe[relative] and path.stat().st_size != recipe[relative]['bytes']) or sha(path) != expected_hash:
                raise ValueError('Damaged runtime resource: ' + relative)
    stage = output/'stage'
    stage.mkdir(parents=True)
    excluded = {'README.md', 'NOTICE', 'docs/INSTALLATION.md', 'docs/BUILDING.md',
                'PBZMC/Manage-PBZMC.ps1', 'PBZMC/Download-PBZMC.ps1',
                'PBZMC/toolchain.lock.json', 'PBZMC/release.json'}
    for path in sorted(release.rglob('*')):
        if not path.is_file():
            continue
        relative = path.relative_to(release).as_posix()
        if relative in excluded or relative.startswith(('PBZMC/source/', 'PBZMC/cache/')):
            continue
        source = child(release, relative)
        dest = child(stage, relative)
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, dest)
    shutil.copy2(ROOT/'distribution/Manage-PBZMC.ps1', stage/'PBZMC/Manage-PBZMC.ps1')
    version = manifest['version']
    if args.cache_only:
        readme = (ROOT/'distribution/offline/CACHE-README.md').read_text('utf-8')
        (stage/'README.md').write_text(readme.replace('{version}', version), encoding='utf-8', newline='\n')
        shutil.copy2(release/'docs/INSTALLATION.md', stage/'docs/INSTALLATION.md')
        shutil.copy2(release/'NOTICE', stage/'NOTICE')
        receipt = stage/'PBZMC/offline-resources.json'
        kind = 'offline-cache'
    else:
        for name in ('README.md', 'INSTALLATION.md'):
            dest = stage/('README.md' if name == 'README.md' else 'docs/INSTALLATION.md')
            value = (ROOT/'distribution/offline'/name).read_text('utf-8').replace('{version}', version)
            dest.write_text(value, encoding='utf-8', newline='\n')
        notice = (ROOT/'NOTICE').read_text('utf-8')
        notice = notice.replace(
            'The upstream NOTICE above describes its original project; third-party game assets listed there are not redistributed in this project.\nMinecraft resources are prepared locally from pinned original sources and are not relicensed.',
            'The upstream NOTICE above describes its original project. This local offline bundle includes verified Minecraft resources from the resource cache.\nMinecraft resources remain the property of Mojang / Microsoft and are not relicensed under the mod source license.\nIt includes neither Minecraft client binaries nor PBZ game content.')
        (stage/'NOTICE').write_text(notice, encoding='utf-8', newline='\n')
        resources = stage/'PBZMC/cache/runtime-assets'
        for relative in expected:
            dest = child(resources, relative)
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(child(assets, relative), dest)
        receipt = resources/'ready.json'
        kind = 'offline'
    ready = dict(schema=1, release=version, recipe=manifest['asset_recipe_sha256'],
                 files=[dict(path=name, sha256=expected[name]) for name in sorted(expected)])
    write(receipt, ready)
    manifest.update(package_kind=kind, resource_receipt_sha256=sha(receipt))
    write(stage/'PBZMC/release.json', manifest)
    archive = output/f'PBZMC-{version}-win64-{kind}.zip'
    with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for path in sorted(stage.rglob('*')):
            if path.is_file():
                info = zipfile.ZipInfo(path.relative_to(stage).as_posix(), (2026,11,1,0,0,0))
                info.compress_type = zipfile.ZIP_DEFLATED
                info.external_attr = 0o100644 << 16
                z.writestr(info, path.read_bytes())
    (output/'SHA256SUMS.txt').write_text(f'{sha(archive)}  {archive.name}\n', encoding='ascii', newline='\n')
    print(json.dumps(dict(archive=str(archive), sha256=sha(archive), bytes=archive.stat().st_size,
                         bundled_resources=len(expected) if assets else 0, runtime_files=len(manifest['files']))))


if __name__ == '__main__':
    main()
