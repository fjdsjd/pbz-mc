# PBZMC {version} 免下载版（自备资源）

适用于已经安装过 PBZMC 的玩家，也支持把自己在另一台电脑上准备好的资源拷到离线电脑。这个 ZIP 提供模组、UE4SS 和资源校验清单。没有缓存、需要首次获取素材的玩家请下载 [标准安装包](https://github.com/fjdsjd/pbz-mc/releases/download/v{version}/PBZMC-{version}-win64.zip)。

1. 在游戏内保存并退出，备份 PBZ 存档与模组数据。
2. 将本包解压到包含 `platform/steam/PBZ.exe` 的游戏根目录。原地升级时保留已有的 `PBZMC` 目录。
3. 如果是新电脑，将自己已安装 PBZMC 的电脑上的 `PBZMC/cache/runtime-assets` 整个目录复制到新电脑游戏目录的相同位置。
4. 双击 `Launch-PBZMC.cmd`。安装器会核验本地资源并启动游戏。旧安装的缓存已清理时，也会检查原有安装目录中的资源副本。资源不完整时会提示缺失并停止，全程不会联网补文件。

本发行版沿用 alpha.3 的 3172 项资源。游戏本体和 Steam 的离线运行条件仍由 Steam 决定。备份位置、卸载与故障处理见 [安装教程](docs/INSTALLATION.md)。
