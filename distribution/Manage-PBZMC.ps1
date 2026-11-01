[CmdletBinding()]
param(
    [ValidateSet('Launch','Install','Verify','Backup','Uninstall')][string]$Action='Launch',
    [string]$GameRoot
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
# Windows PowerShell 5.1 may evaluate parameter defaults before PSScriptRoot
# is available when launched via a .cmd. Resolve the portable root in the body.
if ([string]::IsNullOrWhiteSpace($GameRoot)) { $GameRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')) }
$root=[IO.Path]::GetFullPath($GameRoot).TrimEnd('\','/')
$exe=Join-Path $root 'platform/steam/PBZ.exe'
$receiptPath=Join-Path $PSScriptRoot 'installed-files.json'
$dataRelative='platform/steam/ue4ss/Mods/PBZMCProbe/Scripts/pbzmc-data'
$assetsRelative='platform/steam/ue4ss/Mods/PBZMCProbe/Scripts/pbzmc-assets'
$manifest=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'release.json') -Raw | ConvertFrom-Json
$lockStream=$null

function Resolve-Child([string]$Base,[string]$Relative) {
    if ([IO.Path]::IsPathRooted($Relative)) { throw 'Absolute package path rejected.' }
    $parent=[IO.Path]::GetFullPath($Base).TrimEnd('\','/')
    $path=[IO.Path]::GetFullPath((Join-Path $parent $Relative))
    if (-not $path.StartsWith($parent+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'Package path escapes its root.' }
    # Do not follow user-created junctions out of an installation directory.
    $current=$path
    while ($current.Length -gt $parent.Length) {
        if ((Test-Path -LiteralPath $current) -and ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Linked destination rejected: $current" }
        $current=Split-Path $current -Parent
    }
    return $path
}
function Hash([string]$Path) {
    $stream=[IO.File]::OpenRead($Path);$algorithm=[Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($algorithm.ComputeHash($stream)).Replace('-','').ToLowerInvariant() }
    finally { $stream.Dispose();$algorithm.Dispose() }
}
function Game-IsRunning {
    return [bool]@(Get-Process PBZ -ErrorAction SilentlyContinue | Where-Object {
        try { $_.Path -and $_.Path.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase) } catch { $true }
    }).Count
}
function Save-Json([string]$Path,$Value) {
    $temp=$Path+'.tmp'
    [IO.File]::WriteAllText($temp,($Value|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
    if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temp,$Path,[NullString]::Value) }
    else { [IO.File]::Move($temp,$Path) }
}
function Backup-Saves {
    if (Game-IsRunning) { throw 'Close PBZ before backing up; a running game can change the save during copying.' }
    $backup=Join-Path $PSScriptRoot ('backups/'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[Guid]::NewGuid().ToString('N').Substring(0,6))
    New-Item -ItemType Directory -Force -Path $backup | Out-Null
    $sources=@()
    foreach ($relative in @('ProjectPBZ/Saved/SaveGames',$dataRelative)) {
        $path=Resolve-Child $root $relative
        if (Test-Path -LiteralPath $path) { $sources+=Get-ChildItem -LiteralPath $path -Recurse -File -Force }
    }
    $saved=Resolve-Child $root 'ProjectPBZ/Saved'
    if (Test-Path -LiteralPath $saved) { $sources+=Get-ChildItem -LiteralPath $saved -File -Filter '*.sav' }
    $files=@()
    foreach ($file in $sources) {
        if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Linked save file rejected.' }
        $relative=$file.FullName.Substring($root.Length+1)
        $null=Resolve-Child $root $relative
        $to=Resolve-Child $backup $relative
        New-Item -ItemType Directory -Force -Path (Split-Path $to -Parent) | Out-Null
        $before=Hash $file.FullName;Copy-Item -LiteralPath $file.FullName -Destination $to
        if ((Hash $to) -ne $before -or (Hash $file.FullName) -ne $before) { throw 'Save changed during backup.' }
        $files+=@{path=$relative;sha256=$before}
    }
    Save-Json (Join-Path $backup 'backup.json') @{schema=1;created=(Get-Date).ToUniversalTime().ToString('o');files=$files}
    Write-Host "Save backup: $backup ($($files.Count) files)"
    return $backup
}
function Expand-Safe([string]$Archive,[string]$Destination) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip=[IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        foreach ($entry in $zip.Entries) {
            $to=Resolve-Child $Destination $entry.FullName
            if (-not $entry.Name) { New-Item -ItemType Directory -Force -Path $to | Out-Null;continue }
            New-Item -ItemType Directory -Force -Path (Split-Path $to -Parent) | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry,$to,$true)
        }
    } finally {$zip.Dispose()}
}
function Prepare-Resources {
    $result=Join-Path $PSScriptRoot 'cache/runtime-assets'
    $ready=Join-Path $result 'ready.json'
    if (Test-Path -LiteralPath $ready) {
        $record=Get-Content -LiteralPath $ready -Raw | ConvertFrom-Json
        if ($record.recipe -eq $manifest.asset_recipe_sha256) {
            # Code-only updates reuse identical resources. Install still checks
            # every resource hash before copying; a new recipe must be rebuilt.
            if ($record.release -ne $manifest.version) { $record.release=$manifest.version;Save-Json $ready $record }
            return $result
        }
    }
    Write-Host 'First launch: preparing original resources locally. Keep this window open; subsequent launches reuse the result.'
    $cache=Join-Path $PSScriptRoot 'cache/downloads'
    New-Item -ItemType Directory -Force -Path $cache | Out-Null
    . (Join-Path $PSScriptRoot 'Download-PBZMC.ps1')
    $env:PBZMC_DOWNLOAD_LOG=Join-Path $PSScriptRoot 'cache/downloads.jsonl'
    $tools=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'toolchain.lock.json') -Raw | ConvertFrom-Json
    foreach ($key in @('python','pillow','json5','ffmpeg')) {
        $spec=$tools.$key;Download-Pinned $spec (Join-Path $cache $spec.filename)
    }
    $pythonRoot=Join-Path $PSScriptRoot 'cache/python'
    Expand-Safe (Join-Path $cache $tools.python.filename) $pythonRoot
    foreach ($key in @('pillow','json5')) { Expand-Safe (Join-Path $cache $tools.$key.filename) $pythonRoot }
    [IO.File]::WriteAllText((Join-Path $pythonRoot 'python312._pth'),"python312.zip`r`n.`r`n../asset-work/tools`r`n../../source/tools`r`nimport site`r`n",[Text.Encoding]::ASCII)
    $ffmpegRoot=Join-Path $PSScriptRoot 'cache/ffmpeg'
    Expand-Safe (Join-Path $cache $tools.ffmpeg.filename) $ffmpegRoot
    $ffmpeg=@(Get-ChildItem -LiteralPath $ffmpegRoot -Recurse -File -Filter ffmpeg.exe)
    if ($ffmpeg.Count -ne 1) { throw 'Ambiguous FFmpeg archive.' }
    $python=Join-Path $pythonRoot 'python.exe'
    $work=Join-Path $PSScriptRoot 'cache/asset-work'
    $script=Join-Path $PSScriptRoot 'source/tools/prepare_release_assets.py'
    & $python $script --work $work --cache $cache --ffmpeg-bin $ffmpeg[0].DirectoryName --resume --output $result --release $manifest.version | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { throw 'Resource preparation failed. Keep cache and retry; completed stages are retained.' }
    $record=Get-Content -LiteralPath $ready -Raw | ConvertFrom-Json
    if ($record.release -ne $manifest.version -or $record.recipe -ne $manifest.asset_recipe_sha256) { throw 'Prepared resource receipt mismatch.' }
    return $result
}

try {
    # One writer per extracted package. File locks are released on process exit.
    $lockStream=[IO.File]::Open((Join-Path $PSScriptRoot 'install.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    if (-not (Test-Path -LiteralPath $exe)) { throw 'Extract this archive into the PBZ root containing platform/steam/PBZ.exe.' }
    if ($Action -eq 'Backup') { $null=Backup-Saves;exit 0 }
    if (Game-IsRunning) { throw 'PBZ is running. Close it before installation, verification or removal.' }
    if ($Action -eq 'Uninstall') {
        if (-not (Test-Path -LiteralPath $receiptPath)) { throw 'No ownership receipt; refusing to remove unknown files.' }
        $receipt=Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
        $proxyEntry=$receipt.files | Where-Object path -eq 'platform/steam/dwmapi.dll'
        $proxy=Resolve-Child $root 'platform/steam/dwmapi.dll'
        if ((Test-Path -LiteralPath $proxy) -and (-not $proxyEntry -or (Hash $proxy) -ne $proxyEntry.sha256)) {
            throw 'Loader proxy was modified by another installation. Resolve the conflict before uninstalling; no files were removed.'
        }
        $null=Backup-Saves
        foreach ($entry in $receipt.files) {
            $path=Resolve-Child $root $entry.path
            if (Test-Path -LiteralPath $path) {
                if ((Hash $path) -ne $entry.sha256) { Write-Warning "Keeping modified file: $($entry.path)";continue }
                Remove-Item -LiteralPath $path
            }
        }
        $receipt | Add-Member -NotePropertyName uninstalled -NotePropertyValue $true -Force
        Save-Json $receiptPath $receipt
        Write-Host 'Mod files removed. Native saves, mod data, resource cache and backups are retained.'
        exit 0
    }
    if ((Hash $exe) -notin $manifest.supported_exe_sha256) {
        # Only disable the proxy owned by this release, never another loader.
        $proxy=Resolve-Child $root 'platform/steam/dwmapi.dll'
        $expected=$manifest.files | Where-Object path -eq 'platform/steam/dwmapi.dll'
        if ((Test-Path -LiteralPath $receiptPath) -and (Test-Path -LiteralPath $proxy) -and (Hash $proxy) -eq $expected.sha256) {
            Move-Item -LiteralPath $proxy -Destination ($proxy+'.pbzmc-disabled') -Force
        }
        throw 'Unsupported PBZ build. The mod was not started; obtain a compatible release. Do not bypass the version guard.'
    }
    $installed=$null
    if (Test-Path -LiteralPath $receiptPath) { $installed=Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json }
    $ownedHashes=@{}
    if ($installed) { foreach ($entry in $installed.files) { $ownedHashes[$entry.path]=$entry.sha256 } }
    if ($Action -eq 'Verify') {
        if (-not $installed -or $installed.uninstalled) { throw 'Not installed.' }
        foreach ($entry in $installed.files) {
            $path=Resolve-Child $root $entry.path
            if (-not (Test-Path -LiteralPath $path) -or (Hash $path) -ne $entry.sha256) { throw "Changed or missing: $($entry.path)" }
        }
        Write-Host 'Installed files and game build verified.';exit 0
    }
    $current=$installed -and -not $installed.uninstalled -and $installed.version -eq $manifest.version
    if ($current) {
        foreach ($critical in @('platform/steam/dwmapi.dll','platform/steam/ue4ss/UE4SS.dll',
            'platform/steam/ue4ss/Mods/PBZMCJsonBridge/dlls/main.dll','platform/steam/ue4ss/Mods/PBZMCProbe/Scripts/main.lua',
            ($assetsRelative+'/ready.json'))) {
            $path=Resolve-Child $root $critical
            $entry=$installed.files | Where-Object path -eq $critical
            if (-not $entry -or -not (Test-Path -LiteralPath $path)) { $current=$false;break }
            if ((Hash $path) -ne $entry.sha256) { throw "Modified installation: $critical. Restore the file or inspect the conflict before launching." }
        }
    }
    if (-not $current) {
        foreach ($entry in $manifest.files) {
            $source=Resolve-Child (Join-Path $PSScriptRoot 'payload') $entry.path
            if (-not (Test-Path -LiteralPath $source) -or (Hash $source) -ne $entry.sha256) { throw "Damaged release file: $($entry.path)" }
            $to=Resolve-Child $root $entry.path
            if (Test-Path -LiteralPath $to) {
                $actual=Hash $to
                $owned=$ownedHashes.ContainsKey($entry.path) -and $ownedHashes[$entry.path] -eq $actual
                if (-not $owned -and $actual -ne $entry.sha256) { throw "Existing mod file differs: $($entry.path). Use a clean installation or merge manually; nothing was overwritten." }
            }
        }
        $backup=Backup-Saves
        $resources=Prepare-Resources
        $resourceManifest=Get-Content -LiteralPath (Join-Path $resources 'ready.json') -Raw | ConvertFrom-Json
        $files=@();$written=@()
        try {
            # The loader proxy is copied last, after code and resources succeed.
            $entries=@($manifest.files|Where-Object path -ne 'platform/steam/dwmapi.dll')
            $entries+=@($resourceManifest.files|ForEach-Object {[pscustomobject]@{path=$assetsRelative+'/'+$_.path;sha256=$_.sha256;resource=$_.path}})
            $entries+=@([pscustomobject]@{path=$assetsRelative+'/ready.json';sha256=(Hash (Join-Path $resources 'ready.json'));resource='ready.json'})
            $entries+=@($manifest.files|Where-Object path -eq 'platform/steam/dwmapi.dll')
            $newPaths=@{};foreach ($entry in $entries) { $newPaths[$entry.path]=$true }
            # Retain ownership of earlier-version files until explicit uninstall.
            # This avoids deleting a shared loader dependency during an upgrade.
            if ($installed) {
                foreach ($old in $installed.files) {
                    if (-not $newPaths.ContainsKey($old.path)) {
                        $oldPath=Resolve-Child $root $old.path
                        if ((Test-Path -LiteralPath $oldPath) -and (Hash $oldPath) -eq $old.sha256) {
                            $files+=@{path=$old.path;sha256=$old.sha256}
                        }
                    }
                }
            }
            foreach ($entry in $entries) {
                $to=Resolve-Child $root $entry.path
                if (Test-Path -LiteralPath $to) {
                    $actual=Hash $to
                    $owned=$ownedHashes.ContainsKey($entry.path) -and $ownedHashes[$entry.path] -eq $actual
                    if (-not $owned -and $actual -ne $entry.sha256) { throw "Resource conflict: $($entry.path). No runtime files were replaced." }
                }
            }
            foreach ($entry in $entries) {
                $to=Resolve-Child $root $entry.path
                $source=if ($entry.PSObject.Properties.Name -contains 'resource') { Resolve-Child $resources $entry.resource } else { Resolve-Child (Join-Path $PSScriptRoot 'payload') $entry.path }
                if ((Hash $source) -ne $entry.sha256) { throw 'Install source changed.' }
                if (Test-Path -LiteralPath $to) {
                    if ((Hash $to) -eq $entry.sha256) {
                        $files+=@{path=$entry.path;sha256=$entry.sha256};continue
                    }
                    $copy=Resolve-Child $backup ('replaced/'+$entry.path)
                    New-Item -ItemType Directory -Force -Path (Split-Path $copy -Parent)|Out-Null
                    Copy-Item -LiteralPath $to -Destination $copy
                }
                New-Item -ItemType Directory -Force -Path (Split-Path $to -Parent)|Out-Null
                Copy-Item -LiteralPath $source -Destination ($to+'.pbzmc-new')
                if ((Hash ($to+'.pbzmc-new')) -ne $entry.sha256) { throw 'Install copy checksum mismatch.' }
                Move-Item -LiteralPath ($to+'.pbzmc-new') -Destination $to -Force
                $written+=$entry.path;$files+=@{path=$entry.path;sha256=$entry.sha256}
            }
            # Lua's file API cannot create directories on a new machine.
            foreach ($relative in @($dataRelative,($dataRelative+'/player-store'))) {
                $directory=Resolve-Child $root $relative
                New-Item -ItemType Directory -Force -Path $directory | Out-Null
            }
            Save-Json $receiptPath @{schema=1;version=$manifest.version;files=$files;backup=$backup}
        } catch {
            foreach ($relative in $written) {
                $to=Resolve-Child $root $relative;$copy=Resolve-Child $backup ('replaced/'+$relative)
                if (Test-Path -LiteralPath $copy) { Copy-Item -LiteralPath $copy -Destination $to -Force }
                elseif (Test-Path -LiteralPath $to) { Remove-Item -LiteralPath $to }
            }
            throw
        }
        Write-Host 'PBZMC installed and verified.'
    }
    if ($Action -eq 'Launch') { Start-Process 'steam://rungameid/4115450' -WindowStyle Hidden }
} catch {
    Write-Host ('PBZMC: '+$_.Exception.Message) -ForegroundColor Red
    exit 1
} finally {
    if ($lockStream) { $lockStream.Dispose() }
}
