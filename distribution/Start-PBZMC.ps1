# Launch arguments apply to this Steam launch only. Never edit the user's
# persistent Steam launch options, registry values or game files here.
function Get-PBZMCSteamPath {
    $candidates=@()
    $user=Get-ItemProperty -LiteralPath 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue
    if ($user -and $user.SteamExe) { $candidates+=$user.SteamExe }
    foreach ($key in @('HKLM:\SOFTWARE\WOW6432Node\Valve\Steam','HKLM:\SOFTWARE\Valve\Steam')) {
        $machine=Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
        if ($machine -and $machine.InstallPath) { $candidates+=Join-Path $machine.InstallPath 'steam.exe' }
    }
    foreach ($candidate in $candidates) {
        if ([IO.Path]::GetFileName($candidate) -ieq 'steam.exe' -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }
    throw 'Steam was not found. Install and sign in to Steam, then run Launch-PBZMC.cmd again.'
}

function Start-PBZMCGame {
    param([uint32]$AppId)
    if ($AppId -ne 4115450) { throw 'Unexpected PBZ Steam app ID; extract the matching PBZMC release again.' }
    $steam=Get-PBZMCSteamPath
    Start-Process -FilePath $steam -ArgumentList @('-applaunch', [string]$AppId, '--pbzmc') -WindowStyle Hidden
    Write-Host 'Starting PBZMC for this session. Use Steam Play for the unmodded game; no uninstall is needed after exit.'
}
