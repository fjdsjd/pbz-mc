[CmdletBinding()]
param([string]$UE4SSDll, [string]$SdkRoot, [string]$BuildToolsRoot)
$ErrorActionPreference='Stop'
# Resolve Get-FileHash from this host when a parent process uses another PowerShell edition.
Import-Module (Join-Path $PSHOME 'Modules/Microsoft.PowerShell.Utility/Microsoft.PowerShell.Utility.psd1') -ErrorAction Stop
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
if (-not $SdkRoot) { $SdkRoot=Join-Path $root 'build/dependencies' }
if (-not $UE4SSDll) { $UE4SSDll=Join-Path $root 'build/loader/ue4ss/UE4SS.dll' }
if (-not (Test-Path -LiteralPath $UE4SSDll)) { throw 'Pass -UE4SSDll pointing to the pinned UE4SS DLL; see docs/BUILDING.md.' }
if ((Get-FileHash -LiteralPath $UE4SSDll).Hash.ToLowerInvariant() -ne 'c273e7228687b647226fd63d7ca65888d313ece6be18996ec1320d00a5efe1f8') { throw 'Unsupported UE4SS binary.' }
if (-not $BuildToolsRoot) {
    $vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere)) { throw 'Install Visual Studio Build Tools with the C++ desktop workload.' }
    $BuildToolsRoot=& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
}
New-Item -ItemType Directory -Force -Path $SdkRoot | Out-Null
foreach ($dep in @(
    @('ue4ss-cdbc0b66','https://codeload.github.com/KintaroModding/ue4ss/zip/cdbc0b66','9e64a3c08a93a62b21b6367e43d2f4ebdd61e15980bf043b8b806e5caf219a01'),
    @('fmt-11.2.0','https://codeload.github.com/fmtlib/fmt/zip/refs/tags/11.2.0','ebb31f63e14048ffba9200bbe27b339ec50226cbe8e96ca8b62ee16a0a4fb1af')
)) {
    $archive=Join-Path $SdkRoot ($dep[0]+'.zip')
    if (-not (Test-Path -LiteralPath $archive)) { Invoke-WebRequest -Uri $dep[1] -OutFile $archive }
    if ((Get-FileHash -LiteralPath $archive).Hash.ToLowerInvariant() -ne $dep[2]) { throw 'SDK checksum mismatch.' }
    if (-not (Test-Path -LiteralPath (Join-Path $SdkRoot $dep[0]))) { Expand-Archive -LiteralPath $archive -DestinationPath $SdkRoot }
}
$sdk=Join-Path $SdkRoot 'ue4ss-cdbc0b66'
$header=[IO.File]::ReadAllText((Join-Path $sdk 'UE4SS/include/Mod/CppUserModBase.hpp'))
if (-not $header.Contains('#include <GUI/GUITab.hpp>')) { throw 'SDK header shape changed.' }
$header=$header.Replace('#include <GUI/GUITab.hpp>','namespace RC::GUI { class GUITab; }').Replace('GUI::GUITab::RenderFunctionType','void (*)(CppUserModBase*)')
$build=Join-Path $root 'build/native-release'
New-Item -ItemType Directory -Force -Path (Join-Path $build 'include/Mod') | Out-Null
[IO.File]::WriteAllText((Join-Path $build 'include/Mod/CppUserModBase.hpp'),$header,[Text.UTF8Encoding]::new($false))
$devcmd=Join-Path $BuildToolsRoot 'Common7/Tools/VsDevCmd.bat'
if (-not (Test-Path -LiteralPath $devcmd)) { throw 'MSVC setup was not found.' }
$environment=& $env:ComSpec /d /s /c "`"$devcmd`" -no_logo -arch=x64 -host_arch=x64 >nul && set"
if ($LASTEXITCODE -ne 0) { throw 'MSVC setup failed.' }
foreach ($line in $environment) { if ($line -match '^([^=]+)=(.*)$') { [Environment]::SetEnvironmentVariable($matches[1],$matches[2],'Process') } }
$exports=& dumpbin /nologo /exports $UE4SSDll
$symbols=@($exports | ForEach-Object { if ($_ -match '^\s+\d+\s+[0-9A-F]+\s+[0-9A-F]+\s+(\S+)') { $matches[1] } })
if ($symbols.Count -lt 1000) { throw 'Invalid UE4SS export table.' }
@('LIBRARY UE4SS.dll','EXPORTS')+$symbols | Set-Content -LiteralPath (Join-Path $build 'UE4SS.def') -Encoding ascii
& lib /nologo /machine:x64 ('/def:'+(Join-Path $build 'UE4SS.def')) ('/out:'+(Join-Path $build 'UE4SS.lib'))
if ($LASTEXITCODE -ne 0) { throw 'Import library failed.' }
$includes=@((Join-Path $build 'include'),(Join-Path $sdk 'UE4SS/include'),(Join-Path $SdkRoot 'fmt-11.2.0/include'))
foreach ($name in @('String','File','Input','LuaMadeSimple','LuaRaw')) { $includes+=Join-Path $sdk ('deps/first/'+$name+'/include') }
Push-Location $root
try {
    $opts=@('/nologo','/c','/std:c++latest','/MD','/O2','/EHsc','/W4','/permissive-','/Zc:__cplusplus','/utf-8','/Brepro','/DNDEBUG','/DPBZMC_RELEASE','/D_ITERATOR_DEBUG_LEVEL=0','/DNOMINMAX','/DWIN32_LEAN_AND_MEAN')
    $opts+=@($includes|ForEach-Object {'/I'+$_})
    & cl @opts ('/Fo'+(Join-Path $build 'main.obj')) 'native/json_bridge/main.cpp'
    if ($LASTEXITCODE -ne 0) { throw 'Native bridge compilation failed.' }
    $objects=@((Join-Path $build 'main.obj'))
    foreach ($file in @('buffer','hook','trampoline','hde/hde64')) {
        $object=Join-Path $build ($file.Replace('/','-')+'.obj')
        & cl /nologo /c /TC /MD /O2 /DNDEBUG ('/Fo'+$object) ('third_party/minhook-1.3.4/src/'+$file+'.c')
        if ($LASTEXITCODE -ne 0) { throw 'MinHook compilation failed.' }
        $objects+=$object
    }
    & link /NOLOGO /DLL /MACHINE:X64 /OPT:REF /OPT:ICF /DYNAMICBASE /NXCOMPAT /Brepro ('/OUT:'+(Join-Path $build 'main.dll')) @objects (Join-Path $build 'UE4SS.lib') bcrypt.lib user32.lib xaudio2.lib
    if ($LASTEXITCODE -ne 0) { throw 'Native bridge link failed.' }
    & cl /nologo /std:c++latest /MT /O2 /EHsc /utf-8 /DNOMINMAX /DWIN32_LEAN_AND_MEAN /Brepro ('/Fo'+(Join-Path $build 'check-host.obj')) ('/Fe'+(Join-Path $build 'Check-PBZHost.exe')) 'native/json_bridge/check_host.cpp' /link /Brepro
    if ($LASTEXITCODE -ne 0) { throw 'Future host compatibility checker build failed.' }
    & dumpbin /nologo /imports (Join-Path $build 'main.dll') | Set-Content -LiteralPath (Join-Path $build 'imports.txt')
} finally { Pop-Location }
Get-FileHash -LiteralPath (Join-Path $build 'main.dll')
