# 从源码构建

需要 Windows x64、Python 3.12 或更高版本、Visual Studio Build Tools 的 C++ 桌面工作负载及 Windows SDK。正式运行只需发行包，玩家不需要这些编译工具。

## 原生桥

下载 [KintaroModding/ue4ss v3.0.1-1183-gcdbc0b66](https://github.com/KintaroModding/ue4ss/releases/tag/v3.0.1-1183-gcdbc0b66) 中的 `phantombladezero_ue4ss_v3.0.1-1183-gcdbc0b66.zip`，解压到 `build/loader`。

该压缩包 SHA-256：`5328f91d13bd93f080fafae9e7c07790ae838d65e94545831d6676c4c1870d4d`。解压后 `ue4ss/UE4SS.dll` 的 SHA-256 应为 `c273e7228687b647226fd63d7ca65888d313ece6be18996ec1320d00a5efe1f8`。

在仓库根目录执行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File native/json_bridge/build-portable.ps1
```

脚本自动查找 MSVC，下载并校验固定版本的 UE4SS SDK、fmt，输出 `build/native-release/main.dll`。也可以显式传入 `-UE4SSDll`、`-SdkRoot`、`-BuildToolsRoot`。使用动态 MSVC 运行库，与 UE4SS 的分配器边界保持一致。

## 打包

```powershell
python tools/package_release.py --loader build/loader --output build/package-0.1.0-alpha.3
python tools/check_release.py build/package-0.1.0-alpha.3/stage
```

输出目录必须为空。打包脚本使用明确的文件列表，输出可解压到游戏根目录的 ZIP 与 SHA256SUMS。不会复制本机存档、日志、原游戏文件、私有资源缓存或开发命令入口。

`distribution/loader` 保存本游戏需要的 UE4SS 设置与签名适配；不要换成任意 UE4SS 版本。Lua 运行代码在 `src`，宿主接口在 `src/host/pbz`，纯玩法规则在 `src/rules`，内容定义在 `src/content`。

### 本地离线便携包

已有通过校验的运行资源时，可以组合成首次启动也无需下载的离线包：

```powershell
python tools/package_offline.py --release build/package-0.1.0-alpha.3/stage --assets build/runtime-assets --output build/offline-0.1.0-alpha.3
python tools/check_release.py build/offline-0.1.0-alpha.3/stage --installer-test
```

`--assets` 必须包含 `ready.json`，且全部资源与固定配方逐项匹配。打包器只复制清单内的运行资源，不带个人存档、下载的客户端归档、转换工具或开发缓存。离线包包含 `PBZMC/cache/runtime-assets`，其安装器校验资源清单后直接使用；缺失或损坏时停止，不联网回退。游戏运行文件和在线包相同。

资源原作者归属保留在离线包的 NOTICE；资源缓存和生成的离线包继续保存在本地，不提交源码仓库。在线发布包仍使用上面的 `package_release.py` 流程。

## 资源准备与校验

首次安装由启动脚本准备独立的 Python、Pillow、json5、FFmpeg 环境，再调用 `tools/prepare_release_assets.py`。固定工具 URL／哈希在 `distribution/toolchain.lock.json`；原始资源来源在 `distribution/asset-recipes/sources.lock.json`。

`distribution/Download-PBZMC.ps1` 负责 Python 启动前的工具下载，`tools/resource_download.py` 负责资源下载。镜像列表不改变固定文件身份；新增镜像必须验证完整文件哈希。默认 `PBZMC_DOWNLOAD_SOURCE=auto`，也可选择 `official`。`PBZMC_DOWNLOAD_PROXY=direct` 只关闭下载进程使用的代理，不改系统设置。安装器将下载记录写到包内缓存；独立运行转换器时可用 `PBZMC_DOWNLOAD_LOG` 指定 JSONL 记录路径。

手动构建资源时，使用锁文件对应的 Pillow、json5 和 FFmpeg 版本：

```powershell
python tools/prepare_release_assets.py --work build/asset-work --cache build/downloads --ffmpeg-bin PATH_TO_FFMPEG_BIN --resume --output build/runtime-assets
```

共有 30 个转换步骤，生成文件逐个与固定资源清单对照。中断后可继续；脚本或配方改变会重新执行转换。最终 `ready.json` 记录实际运行资源的路径与哈希。这些资源只在本地使用，不应提交仓库或重新打进发行包。

## 验证边界

`tools/check_release.py` 检查发行内容、哈希、启动入口及 PowerShell 解析；加 `--installer-test` 可在临时模拟游戏目录验证安装、备份、冲突、卸载与版本保护，不启动游戏。安装器测试不会操作真实游戏目录。

运行 `python tools/check_downloads.py`，在本机 HTTP 故障服务器上验证 Python 和 Windows PowerShell 5.1 两套生产下载器的回退、断线续传、错误 Range、损坏文件、缓存及失败时保留已有文件。测试仅替换网络连接入口，不连接游戏或外部下载源；不把该检查当作大陆运营商网络实测。

安装 `lupa` 后可运行 `python tools/check_starter_loadout.py` 检查初始物品及原生槽位延迟发现。规则和安装器测试不能代替真实 PBZ 运行验证。游戏更新需重新验证接口、原生入口、生命／死亡和输入路径，再明确增加受支持的游戏哈希；不能只删除版本保护。
