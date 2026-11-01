"""Create the game-root overlay without private files or original game resources."""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import zipfile

ROOT=Path(__file__).resolve().parents[1]
GAME_HASH='7b4fcd286a350780faf0824d73aa150b21cbf1bccde883e6a96386cbe09973b4'
LOADER_HASH='c273e7228687b647226fd63d7ca65888d313ece6be18996ec1320d00a5efe1f8'

def sha(path):return hashlib.file_digest(path.open('rb'),'sha256').hexdigest()
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
    parser.add_argument('--loader',type=Path,required=True,help='Pinned loader folder containing dwmapi.dll and ue4ss/UE4SS.dll')
    parser.add_argument('--bridge',type=Path,default=ROOT/'build/native-release/main.dll')
    parser.add_argument('--output',type=Path,required=True,help='New, empty output directory; never overwrites earlier releases')
    parser.add_argument('--version',default='0.1.0-alpha.1')
    args=parser.parse_args()
    if not args.version or any(c not in '0123456789abcdefghijklmnopqrstuvwxyz.-' for c in args.version):raise ValueError('Invalid release version')
    if sha(args.loader/'ue4ss/UE4SS.dll')!=LOADER_HASH:raise ValueError('Wrong loader DLL')
    output=args.output.resolve()
    if output.exists() and any(output.iterdir()):raise ValueError('Choose a new output directory')
    stage=output/'stage';stage.mkdir(parents=True,exist_ok=True)
    package=stage/'PBZMC';payload=package/'payload';host=payload/'platform/steam'
    for name in ('Launch-PBZMC.cmd','Backup-PBZMC.cmd','Uninstall-PBZMC.cmd'):
        copy(ROOT/'distribution'/name,stage/name)
    for name in ('Manage-PBZMC.ps1','toolchain.lock.json'):
        copy(ROOT/'distribution'/name,package/name)
    for name in ('README.md','LICENSE','NOTICE','CHANGELOG.md'):
        copy(ROOT/name,stage/name)
    for name in ('INSTALLATION.md','BUILDING.md','COMPATIBILITY.md','CONTROLS.md','media/demo.jpg'):
        copy(ROOT/'docs'/name,stage/'docs'/name)
    for relative in ('dwmapi.dll','ue4ss/UE4SS.dll','ue4ss/LICENSE','ue4ss/Mods/shared/UEHelpers/UEHelpers.lua'):
        copy(args.loader/relative,host/relative)
    tree(ROOT/'distribution/loader',host/'ue4ss')
    mods=host/'ue4ss/Mods'
    (mods/'mods.txt').write_text('PBZMCJsonBridge : 1\nPBZMCProbe : 1\n','utf-8')
    for name in ('PBZMCJsonBridge','PBZMCProbe'):
        (mods/name).mkdir(parents=True,exist_ok=True)
        (mods/name/'enabled.txt').write_text('','utf-8')
    copy(args.bridge,mods/'PBZMCJsonBridge/dlls/main.dll')
    scripts=mods/'PBZMCProbe/Scripts'
    copy(ROOT/'distribution/runtime/main.lua',scripts/'main.lua')
    tree(ROOT/'src',scripts/'pbzmc',{'.lua'})
    copy(ROOT/'third_party/dkjson/dkjson.lua',scripts/'pbzmc/vendor/dkjson.lua')
    source=package/'source'
    copy(ROOT/'tools/prepare_release_assets.py',source/'tools/prepare_release_assets.py')
    tree(ROOT/'tools/assets',source/'tools/assets',{'.py'})
    tree(ROOT/'src/content',source/'src/content',{'.lua','.json'})
    tree(ROOT/'distribution/asset-recipes',source/'distribution/asset-recipes',{'.json'})
    tree(ROOT/'third_party/wukong-steve',source/'third_party/wukong-steve')
    copy(ROOT/'native/json_bridge/block_audio_catalogue.hpp',source/'native/json_bridge/block_audio_catalogue.hpp')
    for name in ('UE4SS-LICENSE','fmt-LICENSE','minhook-1.3.4/LICENSE.txt',
                 'nlohmann-json-3.11.3/LICENSE.MIT','wukong-steve/LICENSE','wukong-steve/NOTICE','dkjson/dkjson.lua'):
        copy(ROOT/'third_party'/name,stage/'third_party'/name)
    files=[dict(path=p.relative_to(payload).as_posix(),sha256=sha(p))for p in sorted(payload.rglob('*'))if p.is_file()]
    manifest=dict(schema=1,version=args.version,steam_app_id=4115450,supported_exe_sha256=[GAME_HASH],
                  asset_recipe_sha256=sha(ROOT/'distribution/asset-recipes/runtime-files.json'),files=files)
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
