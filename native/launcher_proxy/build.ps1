[CmdletBinding()]
param([string]$BuildToolsRoot)
$ErrorActionPreference='Stop'
# A build started by another PowerShell edition can inherit its module search path.
Import-Module (Join-Path $PSHOME 'Modules/Microsoft.PowerShell.Utility/Microsoft.PowerShell.Utility.psd1') -ErrorAction Stop
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$build=Join-Path $root 'build/launcher-proxy'
if (-not $BuildToolsRoot) {
    $vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere)) { throw 'Install Visual Studio Build Tools with the C++ desktop workload.' }
    $BuildToolsRoot=& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
}
$devcmd=Join-Path $BuildToolsRoot 'Common7/Tools/VsDevCmd.bat'
if (-not (Test-Path -LiteralPath $devcmd)) { throw 'MSVC setup was not found.' }
$environment=& $env:ComSpec /d /s /c "`"$devcmd`" -no_logo -arch=x64 -host_arch=x64 >nul && set"
if ($LASTEXITCODE -ne 0) { throw 'MSVC setup failed.' }
foreach ($line in $environment) { if ($line -match '^([^=]+)=(.*)$') { [Environment]::SetEnvironmentVariable($matches[1],$matches[2],'Process') } }
& python (Join-Path $PSScriptRoot 'generate.py') $build
if ($LASTEXITCODE -ne 0) { throw 'Proxy export generation failed.' }
& ml64 /nologo /c ('/Fo'+(Join-Path $build 'dwmapi.obj')) (Join-Path $build 'dwmapi.asm')
if ($LASTEXITCODE -ne 0) { throw 'Proxy thunks failed to assemble.' }
& cl /nologo /c /std:c++20 /MT /O2 /EHsc /W4 /WX /utf-8 /Brepro ('/I'+$build) ('/Fo'+(Join-Path $build 'main.obj')) (Join-Path $PSScriptRoot 'main.cpp')
if ($LASTEXITCODE -ne 0) { throw 'Proxy compilation failed.' }
& link /NOLOGO /DLL /MACHINE:X64 /OPT:REF /OPT:ICF /DYNAMICBASE /NXCOMPAT /Brepro ('/DEF:'+(Join-Path $build 'dwmapi.def')) ('/OUT:'+(Join-Path $build 'dwmapi.dll')) (Join-Path $build 'main.obj') (Join-Path $build 'dwmapi.obj') shell32.lib user32.lib
if ($LASTEXITCODE -ne 0) { throw 'Proxy link failed.' }
$sources=@{}
foreach ($name in @('main.cpp','launch_policy.hpp','generate.py','dwmapi.exports','build.ps1')) {
    $sources[$name]=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $name)).Hash.ToLowerInvariant()
}
$receipt=@{schema=1;policy='PBZMC_LAUNCH_OPT_IN_V1';sha256=(Get-FileHash -LiteralPath (Join-Path $build 'dwmapi.dll')).Hash.ToLowerInvariant();sources=$sources}
[IO.File]::WriteAllText((Join-Path $build 'proxy-build.json'),($receipt | ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))
Write-Host "Built opt-in launcher proxy: $build"
