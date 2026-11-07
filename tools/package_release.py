"""Create the game-root overlay without private files or original game resources."""
from __future__ import annotations
import argparse
import hashlib
import json
import re
from pathlib import Path
import shutil
import zipfile

ROOT=Path(__file__).resolve().parents[1]
LOADER_HASH='c273e7228687b647226fd63d7ca65888d313ece6be18996ec1320d00a5efe1f8'

def game_builds():
    # Read the same table compiled into the DLL. Refuse unrecognized rows.
    rows=(ROOT/'native/json_bridge/host_builds.inc').read_text('ascii').splitlines()
    builds={}
    for row in rows:
        if not row.strip() or row.lstrip().startswith('//'): continue
        match=re.fullmatch(r'\{"([0-9a-f]{64})",\d+,(\d+)(?:,0x[0-9a-f]+){6}\},',row.strip())
        if not match or match[1] in builds: raise ValueError('Invalid native host build table')
        builds[match[1]]=int(match[2])
    if not builds: raise ValueError('No supported host builds')
    return builds

def sha(path):return hashlib.file_digest(path.open('rb'),'sha256').hexdigest()
def check_proxy(proxy):
    record=json.loads(proxy.with_name('proxy-build.json').read_text('utf-8'))
    expected={'main.cpp','launch_policy.hpp','generate.py','dwmapi.exports','build.ps1'}
    if record.get('policy')!='PBZMC_LAUNCH_OPT_IN_V1' or record.get('sha256')!=sha(proxy):
        raise ValueError('Build the per-launch opt-in proxy before packaging')
    if set(record.get('sources',{}))!=expected:
        raise ValueError('Incomplete proxy build receipt')
    for name,digest in record['sources'].items():
        if sha(ROOT/'native/launcher_proxy'/name)!=digest:
            raise ValueError('Stale launcher proxy; rebuild after source changes')
    if b'PBZMC_LAUNCH_OPT_IN_V1' not in proxy.read_bytes():
        raise ValueError('Always-on or unknown launcher proxy rejected')
def copy(source,destination):
    if source.is_symlink() or not source.is_file():raise ValueError('Expected ordinary input file: '+str(source))
    destination.parent.mkdir(parents=True,exist_ok=True)
    shutil.copy2(source,destination)
def tree(source,destination,suffix=None):
    for path in sorted(source.rglob('*')):
        if path.is_file() and '__pycache__' not in path.parts and path.suffix!='.pyc' and (not suffix or path.suffix in suffix):
            copy(path,destination/path.relative_to(source))

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--loader',type=Path,required=True,help='Pinned loader folder containing ue4ss/UE4SS.dll')
    parser.add_argument('--proxy',type=Path,default=ROOT/'build/launcher-proxy/dwmapi.dll')
    parser.add_argument('--bridge',type=Path,default=ROOT/'build/native-release/main.dll')
    parser.add_argument('--host-check',type=Path,default=ROOT/'build/native-release/Check-PBZHost.exe')
    parser.add_argument('--output',type=Path,required=True,help='New, empty output directory; never overwrites earlier releases')
    parser.add_argument('--version',default='0.1.0-alpha.6.1')
    args=parser.parse_args()
    if not args.version or any(c not in '0123456789abcdefghijklmnopqrstuvwxyz.-' for c in args.version):raise ValueError('Invalid release version')
    if sha(args.loader/'ue4ss/UE4SS.dll')!=LOADER_HASH:raise ValueError('Wrong loader DLL')
    check_proxy(args.proxy)
    output=args.output.resolve()
    if output.exists() and any(output.iterdir()):raise ValueError('Choose a new output directory')
    stage=output/'stage';stage.mkdir(parents=True,exist_ok=True)
    package=stage/'PBZMC';payload=package/'payload';host=payload/'platform/steam'
    for name in ('Launch-PBZMC.cmd','Backup-PBZMC.cmd','Uninstall-PBZMC.cmd'):
        copy(ROOT/'distribution'/name,stage/name)
    for name in ('Manage-PBZMC.ps1','Start-PBZMC.ps1','Download-PBZMC.ps1','toolchain.lock.json'):
        copy(ROOT/'distribution'/name,package/name)
    for name in ('README.md','LICENSE','NOTICE','CHANGELOG.md'):
        copy(ROOT/name,stage/name)
    for name in ('INSTALLATION.md','BUILDING.md','COMPATIBILITY.md','CONTROLS.md','COMMANDS.md','MOB_MODELS.md','POTIONS.md','FIRE.md','media/demo.jpg'):
        copy(ROOT/'docs'/name,stage/'docs'/name)
    copy(args.proxy,host/'dwmapi.dll')
    for relative in ('ue4ss/UE4SS.dll','ue4ss/LICENSE','ue4ss/Mods/shared/UEHelpers/UEHelpers.lua'):
        copy(args.loader/relative,host/relative)
    tree(ROOT/'distribution/loader',host/'ue4ss')
    mods=host/'ue4ss/Mods'
    (mods/'mods.txt').write_text('PBZMCJsonBridge : 1\nPBZMCProbe : 1\n','utf-8')
    for name in ('PBZMCJsonBridge','PBZMCProbe'):
        (mods/name).mkdir(parents=True,exist_ok=True)
        (mods/name/'enabled.txt').write_text('','utf-8')
    copy(args.bridge,mods/'PBZMCJsonBridge/dlls/main.dll')
    copy(args.host_check,package/'Check-PBZHost.exe')
    scripts=mods/'PBZMCProbe/Scripts'
    copy(ROOT/'distribution/runtime/main.lua',scripts/'main.lua')
    tree(ROOT/'src',scripts/'pbzmc',{'.lua'})
    # Keep lookup metadata with the code so existing verified resource caches work offline.
    recipe=json.loads((ROOT/'distribution/asset-recipes/runtime-files.json').read_bytes())
    icons={}
    for path,row in recipe.items():
        match=re.fullmatch(r'ui/construction/([a-z0-9_]+)\.png',path)
        if match:icons[match[1]]=row['sha256']
    if not icons:raise ValueError('Construction icon hashes missing from the resource recipe')
    ui=json.loads((ROOT/'distribution/asset-recipes/manifests/ui/manifest.json').read_bytes())
    indexed={row['path']:row['sha256'] for row in ui['outputs']}
    blocks=json.loads((ROOT/'src/content/construction_reference.json').read_bytes())['blocks']
    for name,*_ in blocks:
        icon=ui['item_icons'].get('pbzmc:'+name)
        if icon:
            if not indexed.get(icon) or indexed[icon]!=recipe.get('ui/'+icon,{}).get('sha256'):
                raise ValueError('Unverified construction catalogue icon: '+icon)
        elif name not in icons:
            raise ValueError('Missing construction catalogue icon: '+name)
    hashes=''.join(f'  ["{name}"]="{digest}",\n' for name,digest in sorted(icons.items()))
    (scripts/'pbzmc/content/construction_icon_hashes.lua').write_text('return {\n'+hashes+'}\n',encoding='ascii',newline='\n')
    copy(ROOT/'third_party/dkjson/dkjson.lua',scripts/'pbzmc/vendor/dkjson.lua')
    source=package/'source'
    copy(ROOT/'tools/prepare_release_assets.py',source/'tools/prepare_release_assets.py')
    copy(ROOT/'tools/resource_download.py',source/'tools/resource_download.py')
    tree(ROOT/'tools/assets',source/'tools/assets',{'.py'})
    tree(ROOT/'src/content',source/'src/content',{'.lua','.json'})
    tree(ROOT/'distribution/asset-recipes',source/'distribution/asset-recipes',{'.json'})
    tree(ROOT/'third_party/wukong-steve',source/'third_party/wukong-steve')
    copy(ROOT/'native/json_bridge/block_audio_catalogue.hpp',source/'native/json_bridge/block_audio_catalogue.hpp')
    for name in ('UE4SS-LICENSE','fmt-LICENSE','minhook-1.3.4/LICENSE.txt',
                 'nlohmann-json-3.11.3/LICENSE.MIT','wukong-steve/LICENSE','wukong-steve/NOTICE','dkjson/dkjson.lua'):
        copy(ROOT/'third_party'/name,stage/'third_party'/name)
    files=[dict(path=p.relative_to(payload).as_posix(),sha256=sha(p))for p in sorted(payload.rglob('*'))if p.is_file()]
    builds=game_builds()
    manifest=dict(schema=1,version=args.version,steam_app_id=4115450,supported_exe_sha256=list(builds),future_after_cl=max(builds.values()),
                  launch_policy='PBZMC_LAUNCH_OPT_IN_V1',launch_script_sha256=sha(package/'Start-PBZMC.ps1'),
                  host_check_sha256=sha(args.host_check),asset_recipe_sha256=sha(ROOT/'distribution/asset-recipes/runtime-files.json'),files=files)
    (package/'release.json').write_text(json.dumps(manifest,indent=2)+'\n','utf-8')
    archive=output/f'PBZMC-{args.version}-win64.zip'
    with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED,compresslevel=9) as z:
        for path in sorted(stage.rglob('*')):
            if path.is_file():
                info=zipfile.ZipInfo(path.relative_to(stage).as_posix(),(2026,11,1,0,0,0))
                info.compress_type=zipfile.ZIP_DEFLATED;info.external_attr=0o100644<<16
                z.writestr(info,path.read_bytes())
    (output/'SHA256SUMS.txt').write_text(f'{sha(archive)}  {archive.name}\n','ascii')
    print(json.dumps({'archive':str(archive),'sha256':sha(archive),'runtime_files':len(files),'bytes':archive.stat().st_size}))
if __name__=='__main__':main()
