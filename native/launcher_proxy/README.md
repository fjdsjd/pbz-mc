# Per-launch loader

`dwmapi.dll` always forwards the Windows DWM APIs. It loads the adjacent
`ue4ss/UE4SS.dll` only when the current process has an exact `--pbzmc` argument.
`--disable-ue4ss` takes precedence; argument parsing failure also keeps mods off.
There is no persistent enable flag, environment switch, exit watcher or
per-launch file replacement. Ordinary Steam launches never initialize UE4SS.

The forwarding scheme and `dwmapi.exports` come from the MIT-licensed UE4SS
`cdbc0b66`, `UE4SS/proxy_generator`:
https://github.com/KintaroModding/ue4ss/tree/cdbc0b66/UE4SS/proxy_generator
See `LICENSE`. The gate, build script and tests are local adaptations under the
same MIT license. This directory reads no PBZ binary and contains no game code.

Build with x64 MSVC, MASM, Windows SDK and Python 3:

```powershell
powershell -NoProfile -File native/launcher_proxy/build.ps1
python tools/check_launcher.py
```

Output is `build/launcher-proxy/dwmapi.dll` with a source/hash receipt. The release
packager requires this receipt and rejects the always-on upstream proxy. Runtime
tests use a temporary fake loader and compare real Windows DWM calls, then launch
each test case in a new process. They do not run PBZ or touch Steam settings.
