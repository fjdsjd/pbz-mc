# 离线安装与维护

此包为 **PBZMC {version} 离线便携版**，已包含全部模型、纹理、字体、UI、音效及资源清单。首次运行只校验和复制本地文件，不下载工具或资源，也不现场转换资源。需要已经安装的 PBZ Steam Windows x64 版本；支持范围见 [兼容列表](COMPATIBILITY.md)。

## 安装与启动

先在游戏内保存并正常退出。Steam 库右键 PBZ → 管理 → 浏览本地文件，将压缩包内容直接解压到该目录：

```text
PBZ/
├─ Launch-PBZMC.cmd
├─ Backup-PBZMC.cmd
├─ Uninstall-PBZMC.cmd
├─ PBZMC/
│  ├─ payload/
│  └─ cache/runtime-assets/  # 全部运行资源，须完整保留
└─ platform/steam/PBZ.exe    # 用户已安装的原游戏
```

双击 `Launch-PBZMC.cmd`。首次运行会备份存档并校验本地文件，安装完成后通过 Steam 启动。以后仍使用该脚本启动。首次校验和复制需要一些时间，不要提前关闭窗口；为资源缓存、安装副本和备份预留至少 1 GB 空间。

## 备份与恢复

原生存档 `ProjectPBZ/Saved/SaveGames/`、`ProjectPBZ/Saved/*.sav` 与模组数据 `platform/steam/ue4ss/Mods/PBZMCProbe/Scripts/pbzmc-data/` 应一起备份。

双击 `Backup-PBZMC.cmd`，备份位于 `PBZMC/backups/日期-编号/`。建议另留一份在游戏目录以外。恢复时关闭游戏和自动同步，先保留当前文件，再将同一次备份的原生存档和模组数据按原路径一起恢复。不要混合不同时间点的数据。

建筑和物品变化仅在原生存档点实际保存时写入，文件备份不能代替游戏内保存。Steam 云存档通常不会替你备份模组数据。

## 更新、卸载与故障

- 更新前保存、退出并备份，然后完整解压对应的新包。不要混用不同版本的安装器与资源清单。
- `Uninstall-PBZMC.cmd` 会再次备份，只删除归属记录和哈希匹配的模组文件，保留存档、缓存和修改过的文件。
- 资源缺失或损坏时会报错并停止，不尝试联网。重新完整解压同版离线包后启动即可。
- 游戏版本不受支持时会拒绝启动模组，请等待适配版本，不要删除版本检查。
- 已安装其他 UE4SS 加载器或模组时，同名文件可能冲突；脚本不会强行覆盖不同文件。
- 检查安装：`powershell -NoProfile -ExecutionPolicy Bypass -File .\PBZMC\Manage-PBZMC.ps1 -Action Verify`。

模组资源本身不需要联网；Steam 和游戏是否可以离线启动，仍由原游戏决定。
