"""Audit an extracted release, optionally exercise its installer in temporary fixtures."""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

def sha(path):
    with path.open('rb')as f:return hashlib.file_digest(f,'sha256').hexdigest()
def write(path,value):
    path.parent.mkdir(parents=True,exist_ok=True)
    path.write_text(json.dumps(value,indent=2),'utf-8')
def text(path,value):
    path.parent.mkdir(parents=True,exist_ok=True);path.write_text(value,'utf-8')

def audit(stage):
    package=stage/'PBZMC';manifest=json.loads((package/'release.json').read_text('utf-8'))
    offline=manifest.get('package_kind')=='offline'
    resources=package/'cache/runtime-assets'
    bundled=set()
    if offline:
        ready_path=resources/'ready.json'
        assert sha(ready_path)==manifest['resource_receipt_sha256'],'damaged offline resource receipt'
        ready=json.loads(ready_path.read_text('utf-8'))
        recipe_file=Path(__file__).resolve().parents[1]/'distribution/asset-recipes/runtime-files.json'
        recipe=json.loads(recipe_file.read_text('utf-8'))
        assert sha(recipe_file)==manifest['asset_recipe_sha256']==ready['recipe']
        assert ready['release']==manifest['version']
        expected={name:row['sha256']for name,row in recipe.items()}
        actual={row['path']:row['sha256']for row in ready['files']}
        assert actual==expected and len(actual)==len(ready['files']),'offline resource list differs'
        assert {p.relative_to(resources).as_posix()for p in resources.rglob('*')if p.is_file()}==set(expected)|{'ready.json'},'extra or missing offline files'
        for relative,digest in expected.items():
            path=(resources/relative).resolve()
            assert path.is_relative_to(resources.resolve()),'unsafe resource path'
            assert sha(path)==digest,relative
            if 'bytes'in recipe[relative]:assert path.stat().st_size==recipe[relative]['bytes'],relative
        bundled={p.resolve()for p in resources.rglob('*')if p.is_file()}
        assert not any((package/name).exists()for name in ('source','Download-PBZMC.ps1','toolchain.lock.json')),'offline bundle includes download/conversion tools'
    for row in manifest['files']:
        path=(package/'payload'/row['path']).resolve()
        assert path.is_relative_to((package/'payload').resolve()),'unsafe runtime path'
        assert sha(path)==row['sha256'],row['path']
    forbidden={'agents.md','modlog.md','.env','installed-files.json','ready.json','bridge.lua','developer_commands.lua','pbz.exe'}
    text_types={'.lua','.py','.hpp','.cpp','.cs','.ps1','.cmd','.json','.md','.ini','.txt',''}
    for path in stage.rglob('*'):
        if not path.is_file():continue
        rel=path.relative_to(stage).as_posix()
        is_resource=path.resolve()in bundled
        assert path.name.lower()not in forbidden or (is_resource and path==resources/'ready.json'),rel
        assert not any(s in rel.lower().split('/')for s in ('research','pbzmc-data','pbzmc-assets','__pycache__','.git')),rel
        assert is_resource or path.suffix.lower()not in {'.sav','.dmp','.pdb','.jar','.class','.ogg','.wav','.pcm','.uasset','.pak','.ucas'},rel
        if path.suffix.lower()in text_types:
            value=path.read_text('utf-8-sig')
            assert not re.search(r'[A-Za-z]:[/\\]+(?:Users|Game_project|SteamLibrary)[/\\]+',value,re.I),rel
            assert not re.search(r'(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{50,}|sk-(?:proj-)?[A-Za-z0-9_-]{35,})',value),rel
    main=(package/'payload/platform/steam/ue4ss/Mods/PBZMCProbe/Scripts/main.lua').read_text('utf-8')
    assert 'PBZMC_HostCompatible' in main and "require('host.pbz.mod').start"in main
    if shutil.which('powershell.exe'):
        for name in (('Manage-PBZMC.ps1',)if offline else ('Manage-PBZMC.ps1','Download-PBZMC.ps1')):
            script=str(package/name).replace("'","''")
            command=f"$e=$null;$t=$null;[System.Management.Automation.Language.Parser]::ParseFile('{script}',[ref]$t,[ref]$e)|Out-Null;if($e.Count){{$e|ForEach-Object{{$_.Message}};exit 1}}"
            subprocess.run(['powershell.exe','-NoProfile','-Command',command],check=True)
    if not offline:assert (package/'source/tools/resource_download.py').is_file(),'missing embedded downloader'
    label=f'{len(bundled)-1} verified bundled resources'if offline else 'no original game resources'
    print(f'PASS: {len(manifest["files"])} runtime files; {label}; no private files or secrets; installer parses')

def installer_test(stage):
    if not shutil.which('powershell.exe'):raise RuntimeError('Installer tests require Windows PowerShell')
    # This directory is newly allocated and never points at a real installation.
    # Keep it for inspection; no recursive deletion or real executable is used.
    offline=json.loads((stage/'PBZMC/release.json').read_text('utf-8')).get('package_kind')=='offline'
    root=Path(tempfile.mkdtemp(prefix='pbzmc-installer-check-')).resolve()
    package=root/'PBZMC';package.mkdir()
    shutil.copy2(stage/'PBZMC/Manage-PBZMC.ps1',package/'Manage-PBZMC.ps1')
    exe=root/'platform/steam/PBZ.exe';text(exe,'installer fixture, not executable')
    relative='platform/steam/ue4ss/Mods/PBZMCProbe/Scripts'
    critical=['platform/steam/dwmapi.dll','platform/steam/ue4ss/UE4SS.dll',
      'platform/steam/ue4ss/Mods/PBZMCJsonBridge/dlls/main.dll',relative+'/main.lua',relative+'/pbzmc/mod.lua']
    files=[]
    for name in critical:
        path=package/'payload'/name;text(path,'fixture:'+name);files.append(dict(path=name,sha256=sha(path)))
    manifest=dict(schema=1,version='test.1',supported_exe_sha256=[sha(exe)],asset_recipe_sha256='fixture-recipe',files=files)
    write(package/'release.json',manifest)
    resources=package/'cache/runtime-assets';text(resources/'test.txt','synthetic runtime resource')
    write(resources/'ready.json',dict(schema=1,release='test.1',recipe='fixture-recipe',files=[dict(path='test.txt',sha256=sha(resources/'test.txt'))]))
    if offline:
        manifest.update(package_kind='offline',resource_receipt_sha256=sha(resources/'ready.json'))
        write(package/'release.json',manifest)
    saves=['ProjectPBZ/Saved/SaveGames/slot.sav','ProjectPBZ/Saved/PBZSharedSetting.sav',relative+'/pbzmc-data/player-store/state.json']
    for name in saves:text(root/name,'preserve:'+name)
    saved={name:sha(root/name)for name in saves}
    def run(action,ok=True,explicit_root=True):
        command=['powershell.exe','-NoProfile','-ExecutionPolicy','Bypass','-File',str(package/'Manage-PBZMC.ps1'),'-Action',action]
        if explicit_root:command+=['-GameRoot',str(root)]
        result=subprocess.run(command,capture_output=True,text=True,encoding='utf-8',errors='replace')
        assert (result.returncode==0)==ok,(action,result.stdout,result.stderr)
        for name,h in saved.items():assert sha(root/name)==h,('save changed',name)
        return result
    if offline:
        resource_receipt=resources/'ready.json';original=resource_receipt.read_bytes()
        resource_receipt.unlink();run('Install',False)
        resource_receipt.write_bytes(original+b' ');run('Install',False)
        resource_receipt.write_bytes(original)
        (resources/'test.txt').write_text('damaged resource');run('Install',False)
        assert not any((root/name).exists()for name in critical),'offline failure left installed files'
        (resources/'test.txt').write_text('synthetic runtime resource')
        assert not (package/'cache/downloads').exists(),'offline failure entered the downloader'
    run('Install',explicit_root=False);run('Verify',explicit_root=False)
    receipt=json.loads((package/'installed-files.json').read_text('utf-8'))
    backup=Path(receipt['backup'])
    for name,h in saved.items():assert sha(backup/name)==h
    assert (root/relative/'pbzmc-data/player-store').is_dir()
    count=len(list((package/'backups').iterdir()));run('Install')
    assert len(list((package/'backups').iterdir()))==count,'idempotent install made a backup'
    # A Lua-only upgrade must reuse the resource recipe without bootstrapping
    # tools (this fixture has neither a downloader lock nor converter scripts).
    manifest['version']='test.2'
    if offline:
        data=json.loads((resources/'ready.json').read_text());data['release']='test.2'
        write(resources/'ready.json',data);manifest['resource_receipt_sha256']=sha(resources/'ready.json')
    write(package/'release.json',manifest)
    run('Install');run('Verify')
    assert json.loads((resources/'ready.json').read_text('utf-8'))['release']=='test.2'
    assert json.loads((package/'installed-files.json').read_text('utf-8'))['version']=='test.2'
    run('Uninstall');run('Verify',False);run('Install');run('Verify')
    script=root/critical[-1];text(script,'user modification')
    run('Verify',False);run('Uninstall');assert script.read_text()=='user modification'
    run('Install',False)
    shutil.copy2(package/'payload'/critical[-1],script);run('Install');run('Verify')
    proxy=root/'platform/steam/dwmapi.dll';text(proxy,'another loader')
    run('Uninstall',False);assert (root/critical[-1]).exists(),'partial uninstall on proxy conflict'
    shutil.copy2(package/'payload/platform/steam/dwmapi.dll',proxy)
    text(exe,'unsupported update');run('Install',False)
    assert not proxy.exists() and proxy.with_name('dwmapi.dll.pbzmc-disabled').exists()
    text(exe,'installer fixture, not executable');run('Install');run('Verify')
    # Upgrade preflight must reject path traversal before replacing anything.
    malicious={**manifest,'version':'test.3','files':[dict(path='../outside.txt',sha256='0'*64)]}
    write(package/'release.json',malicious);run('Install',False)
    assert not (root.parent/'outside.txt').exists()
    print('PASS: fresh install, backup hashes, idempotence, code-only upgrade, uninstall/reinstall, modified-file preservation, proxy conflict, unsupported-build disable and unsafe paths')
    if offline:print('PASS: missing/corrupt offline manifest, damaged resource rollback and zero downloader entry')
    print('Fixture retained at '+str(root))

def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('stage',type=Path);ap.add_argument('--installer-test',action='store_true')
    args=ap.parse_args();audit(args.stage.resolve())
    if args.installer_test:installer_test(args.stage.resolve())
if __name__=='__main__':main()
