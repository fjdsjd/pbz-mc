# 安装与维护

## 准备

需要合法安装的 PBZ Steam Windows x64 版本及可用的 Steam。游戏构建必须与 [兼容列表](COMPATIBILITY.md) 一致。为首次工具、资源下载和转换预留至少 3 GB 空间。

先在游戏中通过原生保存入口保存，再正常退出。安装和备份期间不要运行游戏。关闭任何旧版本加载器或模组管理器的自动部署功能，避免两个工具同时写文件。

## 解压与一键启动

在 Steam 库右键 PBZ → 管理 → 浏览本地文件。把 Release 压缩包中的内容直接解压到该目录：

```text
PBZ/
├─ Launch-PBZMC.cmd
├─ Backup-PBZMC.cmd
├─ Uninstall-PBZMC.cmd
├─ PBZMC/                  # 本模组安装工具、运行文件和许可证
├─ platform/steam/PBZ.exe  # 原游戏文件，压缩包不提供
└─ ProjectPBZ/
```

双击 `Launch-PBZMC.cmd`。首次运行会检查版本及文件冲突，备份存档，在 `PBZMC/cache` 中准备固定版本的资源，再把正式运行文件安装到 `platform/steam`。最后通过 Steam 启动游戏。首次准备比以后启动耗时长，窗口会报告当前转换步骤；不要提前关闭。

原始资源由 Mojang 的官方分发端点、固定提交的 Bedrock samples 及其镜像获取；工具同样固定版本。每个候选来源必须匹配同一个哈希，校验失败的文件不会被安装，会尝试下一来源。无需修改系统 PATH、关闭杀毒软件或以管理员身份运行。若目录不可写，先将 Steam 游戏移到当前账户可写的库目录。

第一次安装后可离线复用资源缓存，但 Steam 和游戏本身的离线要求仍按原游戏执行。不要删除 `PBZMC` 文件夹中的安装记录，否则自动卸载无法区分本模组与其他工具拥有的文件。

## 中国大陆网络与下载失败

双击启动脚本即可使用以下线路，无需另装下载工具或手动替换资源：

| 内容 | 优先来源 | 失败时回退 |
| --- | --- | --- |
| MC 客户端资源、索引、声音、字体 | [BMCLAPI](https://bmclapidoc.bangbang93.com/) | Mojang 原始地址 |
| Bedrock 分类 UI，固定提交 | [jsDelivr Gcore](https://www.jsdelivr.com/network) | jsDelivr 默认线路、Mojang 的 GitHub 原始地址 |
| Python、Pillow、json5 | [华为云镜像](https://mirrors.huaweicloud.com/) | Python／PyPI 原始地址 |
| 固定版本 FFmpeg | [Gyan 原始地址](https://www.gyan.dev/ffmpeg/builds/) | [ghfast](https://ghfast.top/) 转发 Gyan 的公开发行文件 |

镜像是第三方服务，会按地区调度，也可能临时不可用；BMCLAPI 在部分地区会转回 Mojang。下载器连接／读取超时为 20 秒，自动切换来源并重试。支持 Range 的服务器会续传；不支持的服务器会重新下载该文件。损坏的下载会丢弃，完整文件先校验再使用，不关闭 TLS 或哈希校验。

下载中断时**保留 `PBZMC/cache`，重新双击启动脚本**。完整文件不会重复下载，未完成的 `.download` 文件会继续使用。下载记录位于 `PBZMC/cache/downloads.jsonl`；已有安装更新到相同资源配方时无需重新下载或转换。

如需排查镜像问题，可在游戏根目录用 PowerShell 临时切回原站：

```powershell
$env:PBZMC_DOWNLOAD_SOURCE='official'
.\Launch-PBZMC.cmd
```

关闭这个 PowerShell 窗口即可恢复默认镜像策略。若本机代理配置失效，可在同一窗口设置 `$env:PBZMC_DOWNLOAD_PROXY='direct'` 后重试；这仅对本次启动有效，不改变系统代理设置。

Release 页面无法下载时，可使用 README 中的备用链接；对应[校验文件](https://ghfast.top/https://github.com/fjdsjd/pbz-mc/releases/download/v0.1.0-alpha.3/SHA256SUMS.txt)与原 Release 一致。可用 `Get-FileHash .\PBZMC-0.1.0-alpha.3-win64.zip -Algorithm SHA256` 核对。

alpha.3 已从空缓存完整下载并校验 4 个工具包和 166 个不同的资源输入，生成的 3172 个运行资源逐个匹配固定哈希；该完整下载在关闭进程代理的日本出口完成。另通过 Globalping 的中国大陆电信、联通、移动节点进行 HTTPS Range 下载抽查，确认各类资源至少有一条可用线路，并据此将 Bedrock 切到 Gcore、FFmpeg 原站优先。节点抽查不等于每个地区的完整安装测试，第三方线路也不能保证永久可用。

## 备份与恢复

需要一起备份：

- `ProjectPBZ/Saved/SaveGames/`：PBZ 原生存档。
- `ProjectPBZ/Saved/*.sav`：原生设置／关联数据。
- `platform/steam/ue4ss/Mods/PBZMCProbe/Scripts/pbzmc-data/`：MC 背包、建筑及原生存档检查点关联数据。

`Backup-PBZMC.cmd` 会在游戏关闭时逐文件复制并校验，保存到 `PBZMC/backups/日期-编号/`。首次安装也会做一次备份。建议另留一份在游戏目录以外，避免卸载整个游戏时一并丢失。Steam 云存档通常不会替你备份模组数据。

恢复时先关闭游戏和自动同步，保留当前文件的另一份备份，再将**同一次备份**中的原生存档和模组数据按原路径一起恢复。不要混合不同时间点的两套数据。确认恢复正确后再决定 Steam 云冲突采用哪一份；本脚本不替你选择或覆盖云存档。

建筑和物品变化只在原生保存入口保存时写入检查点。文件备份无法取代尚未发生的游戏内保存。

## 更新与卸载

更新前保存、退出、备份，查看新版本说明后再解压覆盖安装工具并运行启动脚本。脚本仅更新它能确认归属的文件；手动改过的文件或其他模组的冲突文件会阻止覆盖。

双击 `Uninstall-PBZMC.cmd`，脚本再次备份并只移除记录内、哈希匹配的运行文件。不删除存档、模组数据或缓存。被修改的文件会保留并显示其路径，需自行检查。回退版本时，程序文件与存档数据格式需要同时兼容，不能只把旧 DLL 覆盖回来。

已有其他 UE4SS 模组的安装不能直接视作兼容。特别是同名 `dwmapi.dll`、UE4SS 版本或全局配置不同，脚本会拒绝覆盖。请使用干净的游戏安装，或由熟悉 UE4SS 的使用者手动合并；不要把本包中的配置当作其他模组的通用配置。

## 常见问题

- **提示版本不支持：** 游戏的可执行文件哈希与已验证版本不同。获取适配版本，不能用改校验值的方法“适配”。
- **资源准备失败：** 检查网络和磁盘空间，保留 `PBZMC/cache` 后重试。转换日志位于 `PBZMC/cache/asset-work/`。哈希错误应重新下载该缓存文件，勿关闭校验。
- **仍是原版人物／没有 MC UI：** 确认使用启动脚本完成首次准备；检查 `platform/steam/ue4ss/UE4SS.log`。不能在游戏运行时替换 DLL。
- **缺少 VC 运行库 DLL：** 安装微软官方 [Visual C++ 2015–2022 x64 运行库](https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist)。不要从不明网站下载单个 DLL。
- **检查安装文件：** 在 PowerShell 中执行 `powershell -NoProfile -ExecutionPolicy Bypass -File .\PBZMC\Manage-PBZMC.ps1 -Action Verify`。
- **卡顿：** 首次游戏着色器编译和资源转换分别属于游戏／安装阶段。大量实体、透明方块与复杂红石仍有开销，早期版本建议逐步增加建筑规模。
