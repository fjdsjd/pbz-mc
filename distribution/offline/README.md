# PBZMC {version} 离线便携包

本包包含模组、加载器及全部 3172 个已转换并校验的运行资源。**首次安装也不下载资源，不需要安装 Python、Java 或 FFmpeg。**

1. 退出 PBZ，备份原生存档和模组数据。
2. 将压缩包里的所有内容解压到 PBZ 游戏根目录，使 `Launch-PBZMC.cmd` 与 `platform` 文件夹并列。
3. 双击 **`Launch-PBZMC.cmd`**，脚本自动备份、校验并安装，然后通过 Steam 启动游戏。首次本地文件校验和复制需要一些时间，请保留窗口。

`Backup-PBZMC.cmd` 用于备份，`Uninstall-PBZMC.cmd` 用于卸载模组并保留存档。

详细说明见 [安装与维护](docs/INSTALLATION.md)、[按键](docs/CONTROLS.md) 和 [支持的游戏构建](docs/COMPATIBILITY.md)。游戏内 B 打开背包，F5 切换视角，H 开关操作提示。

请完整保留 `PBZMC/cache/runtime-assets`。缺少资源时本包会停止安装，不会联网补文件；重新完整解压同版离线包即可修复。模组资源准备可全程离线，Steam／游戏自身的启动与离线模式要求仍按原游戏执行。

本包不含个人存档、账号配置、开发日志或原游戏可执行文件；运行资源来源和原作者权利见 `NOTICE`。
