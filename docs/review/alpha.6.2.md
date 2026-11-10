# Verifying PBZMC 0.1.0-alpha.6.2

The two uploads for Phantom Blade Zero mod 374 use source commit `9f3d1791c1b9a1daa6d6513abb2b13918dcdde0b`, tagged `v0.1.0-alpha.6.2`. [Nexus files](https://www.nexusmods.com/phantombladezero/mods/374?tab=files) · [Exact source](https://github.com/fjdsjd/pbz-mc/tree/9f3d1791c1b9a1daa6d6513abb2b13918dcdde0b) · [Release checksums](https://github.com/fjdsjd/pbz-mc/releases/download/v0.1.0-alpha.6.2/SHA256SUMS.txt)

| Nexus file | Submitted ZIP | SHA-256 |
| --- | --- | --- |
| 3153 | PBZMC-0.1.0-alpha.6.2-win64.zip | `ba7bdd7ccc0bc3e43aa1230f22d84c9e7331c24ce690c5503579febebb4a5ed6` |
| 3154 | PBZMC-0.1.0-alpha.6.2-win64-offline-cache.zip | `88e38bbda579786bfc4b943104fba4796bba99c42d583ae4fc495d61343fba4c` |

File 3153 downloads pinned tools and resource inputs over HTTPS when the player needs to prepare their cache. It verifies hashes and converts the resources locally. File 3154 verifies and reuses the player's own cache and stops if required resources are unavailable. Both public ZIPs exclude original Minecraft assets, PBZ game files and player saves. [Downloader and setup scripts](https://github.com/fjdsjd/pbz-mc/tree/v0.1.0-alpha.6.2/distribution) · [Resource sources](https://github.com/fjdsjd/pbz-mc/blob/v0.1.0-alpha.6.2/distribution/asset-recipes/sources.lock.json)

## Native files in both packages

| File | Purpose and source | Submitted SHA-256 |
| --- | --- | --- |
| `dwmapi.dll` | Forwards Windows DWM calls to the system DLL. The exact `--pbzmc` argument enables the adjacent UE4SS loader in the current game process. `--disable-ue4ss` takes precedence. [Proxy source](https://github.com/fjdsjd/pbz-mc/tree/v0.1.0-alpha.6.2/native/launcher_proxy) | `7d8065309e4f94159292852a0c4f06a7fa732dc70f12f5f7eae0b2c7b658bc1e` |
| `PBZMCJsonBridge/dlls/main.dll` | UE4SS mod that connects Lua gameplay to PBZ, including native input, saves and combat hooks. [Bridge source and build script](https://github.com/fjdsjd/pbz-mc/tree/v0.1.0-alpha.6.2/native/json_bridge) | `f3f90ca3dd2b9feaed30276f6c26462342ef3804cc85acbfed398b8ee2fa5b85` |
| `Check-PBZHost.exe` | Reads the game executable to check compatibility before launching. [Checker source](https://github.com/fjdsjd/pbz-mc/blob/v0.1.0-alpha.6.2/native/json_bridge/check_host.cpp) | `7b928dc606c48d3ae7e05891068dfc24ce6502371fd6e493d4a054775c45d779` |
| `ue4ss/UE4SS.dll` | Upstream UE4SS loader supplied by the pinned dependency below. [Upstream source](https://github.com/KintaroModding/ue4ss/tree/cdbc0b66) | `c273e7228687b647226fd63d7ca65888d313ece6be18996ec1320d00a5efe1f8` |

On 10 November 2026, VirusTotal showed a Bkav Pro detection on both ZIPs and on the proxy. Cynet also flagged the proxy and the native bridge individually. [Standard ZIP](https://www.virustotal.com/gui/file/ba7bdd7ccc0bc3e43aa1230f22d84c9e7331c24ce690c5503579febebb4a5ed6) · [Offline ZIP](https://www.virustotal.com/gui/file/88e38bbda579786bfc4b943104fba4796bba99c42d583ae4fc495d61343fba4c) · [Proxy](https://www.virustotal.com/gui/file/7d8065309e4f94159292852a0c4f06a7fa732dc70f12f5f7eae0b2c7b658bc1e) · [Bridge](https://www.virustotal.com/gui/file/f3f90ca3dd2b9feaed30276f6c26462342ef3804cc85acbfed398b8ee2fa5b85)

## Build and check

Use Windows x64, Git, Python 3.12, Visual Studio C++ Build Tools with the x64 compiler and MASM, and the Windows SDK. Start a Windows PowerShell 5.1 session. The comparison below used Python 3.12.7 and MSVC 19.51.36246.

```powershell
git clone --branch v0.1.0-alpha.6.2 --depth 1 https://github.com/fjdsjd/pbz-mc.git
Set-Location pbz-mc
git rev-parse HEAD
```

An exact source build uses the commit at the top of this page. Download `phantombladezero_ue4ss_v3.0.1-1183-gcdbc0b66.zip` from the [upstream release](https://github.com/KintaroModding/ue4ss/releases/tag/v3.0.1-1183-gcdbc0b66). In this build session, put the host's own modules first so that a parent shell from another PowerShell edition cannot shadow `Get-FileHash`.

```powershell
$env:PSModulePath = (Join-Path $PSHOME 'Modules') + [IO.Path]::PathSeparator + $env:PSModulePath
$archive = Read-Host 'Path to the downloaded UE4SS ZIP'
if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne '5328f91d13bd93f080fafae9e7c07790ae838d65e94545831d6676c4c1870d4d') {
    throw 'Unexpected upstream archive'
}
Expand-Archive -LiteralPath $archive -DestinationPath build/loader
& ./native/launcher_proxy/build.ps1
& ./native/json_bridge/build-portable.ps1
Get-FileHash -Algorithm SHA256 -Path build/launcher-proxy/dwmapi.dll,build/native-release/main.dll,build/native-release/Check-PBZHost.exe
python tools/check_launcher.py
```

Build each ZIP into a new output directory. The installer tests use temporary mock game directories. The launcher test uses a local stub for UE4SS and exercises the real proxy in separate processes.

```powershell
python tools/package_release.py --loader build/loader --version 0.1.0-alpha.6.2 --output build/review-standard
python tools/check_release.py build/review-standard/stage --installer-test
python tools/package_offline.py --release build/review-standard/stage --cache-only --output build/review-cache
python tools/check_release.py build/review-cache/stage --installer-test
```

## Expected comparison

A fresh checkout reproduced the submitted proxy and host checker byte for byte. The bundled UE4SS DLL matched upstream. The bridge's 386,048-byte PE `.text` section matched exactly with SHA-256 `cb7d01612e1275ab6d342309782efd9ad1984801a48ec04359627d1205efff55`. The complete bridge differed in 55 bytes across build identifiers, linker timestamps and one compiler-generated C++ type name.

Both rebuilt ZIPs contained exactly the submitted paths. The other differences were text line endings in 74 files in the standard package and 22 in the offline package, and the corresponding checksums in `PBZMC/release.json`, which also records the bridge digest. Use the ZIP hashes above to identify the uploaded files. The clean-build comparison uses individual members and PE sections.
