# Shared bootstrap transport. All candidates must match the same pinned SHA-256.
function Get-PBZDownloadHash([string]$Path) {
    $stream=[IO.File]::OpenRead($Path);$algorithm=[Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($algorithm.ComputeHash($stream)).Replace('-','').ToLowerInvariant() }
    finally { $stream.Dispose();$algorithm.Dispose() }
}
function Open-PBZDownload([string]$Url,[long]$Offset) {
    $current=[Uri]$Url
    for ($redirect=0;$redirect -lt 8;$redirect++) {
        if ($current.Scheme -ne 'https') { throw 'Insecure download redirect rejected.' }
        $request=[Net.HttpWebRequest]::Create($current)
        $request.UserAgent='PBZMC/0.1 resource-downloader'
        $request.Headers['Accept-Encoding']='identity'
        $request.Timeout=20000;$request.ReadWriteTimeout=20000
        $request.AllowAutoRedirect=$false
        if ($env:PBZMC_DOWNLOAD_PROXY -eq 'direct') { $request.Proxy=$null }
        if ($Offset -gt 0) { $request.AddRange($Offset) }
        $response=$request.GetResponse()
        if ([int]$response.StatusCode -in @(301,302,303,307,308)) {
            try { $current=[Uri]::new($current,$response.Headers['Location']) }
            finally { $response.Dispose() }
        } else { return $response }
    }
    throw 'Too many download redirects.'
}
function Write-PBZDownloadEvent($Entry) {
    if ($env:PBZMC_DOWNLOAD_LOG) {
        [IO.File]::AppendAllText($env:PBZMC_DOWNLOAD_LOG,($Entry|ConvertTo-Json -Compress)+[Environment]::NewLine,[Text.UTF8Encoding]::new($false))
    }
}
function Download-Pinned($Spec,[string]$Destination) {
    if ($Spec.sha256 -notmatch '^[0-9a-f]{64}$') { throw 'Invalid bootstrap digest.' }
    if ((Test-Path -LiteralPath $Destination) -and (Get-PBZDownloadHash $Destination) -eq $Spec.sha256) {
        Write-PBZDownloadEvent @{file=$Spec.filename;status='cached';digest=$Spec.sha256}
        return
    }
    $mode=$env:PBZMC_DOWNLOAD_SOURCE
    if ($mode -and $mode -notin @('auto','official')) { throw 'PBZMC_DOWNLOAD_SOURCE must be auto or official.' }
    $urls=@()
    if ($Spec.prefer_origin -and $mode -ne 'official') { $urls+=@($Spec.url) }
    if ($mode -ne 'official') { $urls+=@($Spec.mirrors) }
    $urls+=@($Spec.url)
    $urls=@($urls|Select-Object -Unique)
    foreach ($url in $urls) {
        $uri=[Uri]$url
        if ($uri.Scheme -ne 'https' -or $uri.Host -notin @('www.python.org','files.pythonhosted.org','www.gyan.dev',
                'mirrors.huaweicloud.com','repo.huaweicloud.com','ghfast.top')) { throw 'Unapproved bootstrap download host.' }
    }
    $temp=$Destination+'.download';$meta=$temp+'.sha256'
    $compatible=(Test-Path -LiteralPath $meta) -and ([IO.File]::ReadAllText($meta) -eq $Spec.sha256)
    if (-not $compatible -and (Test-Path -LiteralPath $temp)) { Remove-Item -LiteralPath $temp }
    [IO.File]::WriteAllText($meta,$Spec.sha256,[Text.Encoding]::ASCII)
    if ((Test-Path -LiteralPath $temp) -and (Get-PBZDownloadHash $temp) -eq $Spec.sha256) {
        Move-Item -LiteralPath $temp -Destination $Destination -Force;Remove-Item -LiteralPath $meta
        Write-PBZDownloadEvent @{file=$Spec.filename;status='resumed-complete';digest=$Spec.sha256}
        return
    }
    $failures=@()
    for ($attempt=1;$attempt -le 2;$attempt++) {
        foreach ($url in $urls) {
            $uri=[Uri]$url;$offset=0L
            if (Test-Path -LiteralPath $temp) { $offset=(Get-Item -LiteralPath $temp).Length }
            Write-Host "Downloading $($Spec.filename) via $($uri.Host) (resume $offset bytes)..."
            $response=$null;$inputStream=$null;$outputStream=$null
            try {
                $response=Open-PBZDownload $url $offset
                $encoding=$response.Headers['Content-Encoding']
                if ($encoding -and $encoding -ne 'identity') { throw 'Unexpected transfer encoding.' }
                $status=[int]$response.StatusCode;$total=-1L
                if ($status -eq 206) {
                    $range=$response.Headers['Content-Range']
                    if ($range -notmatch '^bytes (\d+)-(\d+)/(\d+)$') { throw 'Invalid resume range.' }
                    if ([long]$Matches[1] -ne $offset -or [long]$Matches[2] -lt $offset -or [long]$Matches[2] -ge [long]$Matches[3]) { throw 'Invalid resume range.' }
                    $total=[long]$Matches[3]
                } elseif ($status -eq 200) {
                    $offset=0;$total=$response.ContentLength
                } else { throw "Unexpected HTTP status: $status" }
                $fileMode=[IO.FileMode]::Create
                if ($offset -gt 0) { $fileMode=[IO.FileMode]::Append }
                $outputStream=[IO.File]::Open($temp,$fileMode,[IO.FileAccess]::Write,[IO.FileShare]::None)
                $inputStream=$response.GetResponseStream();$buffer=New-Object byte[] (256KB)
                $timer=[Diagnostics.Stopwatch]::StartNew();$lastNotice=0.0
                while (($count=$inputStream.Read($buffer,0,$buffer.Length)) -gt 0) {
                    $outputStream.Write($buffer,0,$count)
                    if ($timer.Elapsed.TotalSeconds-$lastNotice -gt 15) {
                        Write-Host ("  {0:N1} MB received" -f ($outputStream.Position/1MB));$lastNotice=$timer.Elapsed.TotalSeconds
                    }
                    if ($timer.Elapsed.TotalSeconds -gt 300) { throw 'Transfer timed out; retained partial file.' }
                }
                $outputStream.Dispose();$outputStream=$null
                if ($total -ge 0 -and (Get-Item -LiteralPath $temp).Length -ne $total) { throw 'Incomplete response.' }
                if ((Get-PBZDownloadHash $temp) -ne $Spec.sha256) {
                    Remove-Item -LiteralPath $temp;throw 'Download checksum mismatch.'
                }
                Move-Item -LiteralPath $temp -Destination $Destination -Force;Remove-Item -LiteralPath $meta
                Write-PBZDownloadEvent @{file=$Spec.filename;status='verified';source=$url;final_host=$response.ResponseUri.Host;
                    resumed_bytes=$offset;digest=$Spec.sha256;bytes=(Get-Item -LiteralPath $Destination).Length}
                return
            } catch {
                $failure=$_.Exception
                while ($failure -isnot [Net.WebException] -and $failure.InnerException) { $failure=$failure.InnerException }
                $reason=$failure.GetType().Name
                if ($failure -is [Net.WebException] -and $failure.Response) {
                    $code=[int]$failure.Response.StatusCode;$reason="HTTP $code"
                    $failure.Response.Dispose()
                    if ($code -eq 416 -and (Test-Path -LiteralPath $temp)) { Remove-Item -LiteralPath $temp }
                }
                $failures+="$($uri.Host): $reason"
                Write-Host "Download retry: $($Spec.filename) via $($uri.Host) ($reason)"
                Write-PBZDownloadEvent @{file=$Spec.filename;status='retry';host=$uri.Host;reason=$reason;attempt=$attempt}
            } finally {
                if ($outputStream) { $outputStream.Dispose() }
                if ($inputStream) { $inputStream.Dispose() }
                if ($response) { $response.Dispose() }
            }
        }
    }
    throw "Download failed: $($Spec.filename). $($failures -join '; '). Keep cache and run the launcher again."
}
