"""Exercise the compiled opt-in proxy in separate Windows processes (no PBZ)."""
from __future__ import annotations
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def child(proxy: Path, expected: bool, hold: bool):
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.GetModuleHandleW.argtypes = [ctypes.c_wchar_p]
    kernel.GetModuleHandleW.restype = ctypes.c_void_p
    assert not kernel.GetModuleHandleW('UE4SS.dll')
    wrapped = ctypes.WinDLL(str(proxy.resolve()))
    wrapped.PBZMCLaunchPolicy.restype = ctypes.c_char_p
    assert wrapped.PBZMCLaunchPolicy() == b'PBZMC_LAUNCH_OPT_IN_V1'
    loaded = bool(kernel.GetModuleHandleW('UE4SS.dll'))
    assert loaded == expected, (loaded, expected)
    original = ctypes.WinDLL(str(Path(os.environ['SystemRoot']) / 'System32/dwmapi.dll'))
    for name in ('DwmIsCompositionEnabled', 'DwmGetColorizationColor'):
        if name == 'DwmIsCompositionEnabled':
            a, b = ctypes.c_int(), ctypes.c_int()
            hr_a = getattr(wrapped, name)(ctypes.byref(a))
            hr_b = getattr(original, name)(ctypes.byref(b))
            assert (hr_a, a.value) == (hr_b, b.value)
        else:
            a, b, c, d = ctypes.c_ulong(), ctypes.c_int(), ctypes.c_ulong(), ctypes.c_int()
            hr_a = getattr(wrapped, name)(ctypes.byref(a), ctypes.byref(b))
            hr_b = getattr(original, name)(ctypes.byref(c), ctypes.byref(d))
            assert (hr_a, a.value, b.value) == (hr_b, c.value, d.value)
    # Ordinal forwarding must use the same ABI as named forwarding.
    v = ctypes.c_int()
    # The pinned proxy ordinal 85 represents DwmIsCompositionEnabled; Windows
    # versions can assign different ordinals to their named exports.
    assert wrapped[85](ctypes.byref(v)) == original.DwmIsCompositionEnabled(ctypes.byref(v))
    print(json.dumps({'loader_loaded': loaded, 'system_forwarding': True}), flush=True)
    if hold:
        time.sleep(30)


def build_stub(folder: Path):
    source = folder / 'fake_loader.cpp'
    source.write_text('extern "C" __declspec(dllexport) int PBZMCFakeLoader() { return 1; }\n', 'ascii')
    ps = folder / 'build-stub.ps1'
    ps.write_text(r'''
$ErrorActionPreference='Stop'
$vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$vs=& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$devcmd=Join-Path $vs 'Common7/Tools/VsDevCmd.bat'
$environment=& $env:ComSpec /d /s /c "`"$devcmd`" -no_logo -arch=x64 -host_arch=x64 >nul && set"
if ($LASTEXITCODE -ne 0) { throw 'MSVC setup failed.' }
foreach ($line in $environment) { if ($line -match '^([^=]+)=(.*)$') { [Environment]::SetEnvironmentVariable($matches[1],$matches[2],'Process') } }
Push-Location $PSScriptRoot
try {
    & cl /nologo /LD /MT /O2 /EHsc fake_loader.cpp /Fe:UE4SS.dll
    if ($LASTEXITCODE -ne 0) { throw 'Test loader build failed.' }
} finally { Pop-Location }
''', 'utf-8')
    subprocess.run(['powershell.exe', '-NoProfile', '-File', str(ps)], check=True, capture_output=True)
    return folder / 'UE4SS.dll'


def launcher_script_test(folder: Path):
    source = ROOT / 'distribution/Start-PBZMC.ps1'
    fake = folder / 'Steam with spaces' / 'steam.exe'
    fake.parent.mkdir()
    fake.write_bytes(b'fixture; never executed')
    test = folder / 'check-launch-script.ps1'
    test.write_text(r'''
param([string]$Source,[string]$Fake)
$ErrorActionPreference='Stop'
. $Source
$script:calls=0
function Get-ItemProperty {
    param($LiteralPath,$ErrorAction)
    if ($LiteralPath -like 'HKCU:*') { return [pscustomobject]@{SteamExe=$Fake} }
}
function Start-Process {
    param($FilePath,$ArgumentList,$WindowStyle)
    if ($FilePath -ne $Fake -or ($ArgumentList -join '|') -ne '-applaunch|4115450|--pbzmc' -or $WindowStyle -ne 'Hidden') {
        throw 'Incorrect process launch specification.'
    }
    $script:calls++
}
Start-PBZMCGame -AppId 4115450
if ($script:calls -ne 1) { throw 'Duplicate or absent launch.' }
$rejected=$false
try { Start-PBZMCGame -AppId 1 } catch { $rejected=$true }
if (-not $rejected -or $script:calls -ne 1) { throw 'Wrong app was launched.' }
function Get-ItemProperty { param($LiteralPath,$ErrorAction) }
$rejected=$false
try { Start-PBZMCGame -AppId 4115450 } catch { $rejected=$true }
if (-not $rejected -or $script:calls -ne 1) { throw 'Missing Steam silently accepted.' }
Write-Output 'PASS launch helper: arguments, spaced path, missing Steam, wrong app, no extra process.'
''', 'utf-8')
    result = subprocess.run(['powershell.exe', '-NoProfile', '-File', str(test), '-Source', str(source), '-Fake', str(fake)],
                            check=True, capture_output=True, text=True)
    print(result.stdout.strip())


def main(proxy: Path):
    from package_release import check_proxy
    check_proxy(proxy)
    folder = Path(tempfile.mkdtemp(prefix='pbzmc-launcher-check-')).resolve()
    game = folder / '\u542f\u52a8\u6d4b\u8bd5 with spaces' / 'platform/steam'
    game.mkdir(parents=True)
    installed = game / 'dwmapi.dll'
    shutil.copy2(proxy, installed)
    fake = build_stub(folder)
    loader = game / 'ue4ss/UE4SS.dll'
    loader.parent.mkdir()
    shutil.copy2(fake, loader)
    # These used to influence upstream loading. None may enable a vanilla launch.
    shutil.copy2(fake, game / 'UE4SS.dll')
    (game / 'override.txt').write_text(str(fake), 'utf-8')
    env = dict(os.environ, PBZMC='1', PBZMC_ENABLED='1', UE4SS_MODS_PATHS=str(game))
    before = {str(p.relative_to(game)): hashlib.sha256(p.read_bytes()).hexdigest()
              for p in game.rglob('*') if p.is_file()}
    def command(enabled, flags, hold=False):
        return [sys.executable, str(Path(__file__).resolve()), '--child', str(installed),
                '--expected', 'on' if enabled else 'off'] + (['--hold'] if hold else []) + flags
    cases = [([], False), (['--pbzmc'], True), (['--pbzmc', '--pbzmc'], True),
             (['--disable-ue4ss', '--pbzmc'], False), (['--pbzmc', '--disable-ue4ss'], False),
             (['--pbzmc=no'], False), (['prefix--pbzmc'], False), (['prefix --pbzmc suffix'], False),
             (['--PBZMC'], False), (['--ue4ss-path', str(fake)], False)]
    for flags, enabled in cases:
        result = subprocess.run(command(enabled, flags), env=env, cwd=game, capture_output=True,
                                text=True, timeout=20)
        assert result.returncode == 0, (flags, result.stdout, result.stderr)
        assert json.loads(result.stdout)['loader_loaded'] == enabled
    # Unexpected process death needs no cleanup; the next launch is still vanilla.
    proc = subprocess.Popen(command(True, ['--pbzmc'], True), env=env, cwd=game, stdout=subprocess.PIPE, text=True)
    try:
        assert json.loads(proc.stdout.readline())['loader_loaded']
    finally:
        proc.kill()
        proc.wait(timeout=10)
    subprocess.run(command(False, []), env=env, cwd=game, check=True, capture_output=True, timeout=20)
    after = {str(p.relative_to(game)): hashlib.sha256(p.read_bytes()).hexdigest()
             for p in game.rglob('*') if p.is_file()}
    assert before == after, 'A launch modified persistent installation state'
    # Vanilla also works with the mod DLL absent; no dialogs or fallback loaders.
    loader.rename(loader.with_suffix('.disabled'))
    subprocess.run(command(False, []), env=env, cwd=game, check=True, capture_output=True, timeout=20)
    launcher_script_test(folder)
    print(f'PASS {len(cases) + 3} isolated proxy runs: exact opt-in, disable override, forwarding, abnormal exit, missing loader; no file changes.')
    print('Fixture retained at ' + str(folder))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--proxy', type=Path, default=ROOT / 'build/launcher-proxy/dwmapi.dll')
    parser.add_argument('--child', type=Path)
    parser.add_argument('--expected', choices=['on', 'off'])
    parser.add_argument('--hold', action='store_true')
    args, _ = parser.parse_known_args()
    if args.child:
        child(args.child, args.expected == 'on', args.hold)
    else:
        main(args.proxy)
