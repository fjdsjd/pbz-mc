# 兼容性

当前测试平台：Windows x64、Steam app `4115450`，PBZ 可执行文件位于 `platform/steam/PBZ.exe`。

| 组件 | 固定版本／身份 |
| --- | --- |
| Steam 构建 26266538（CL-301524） | `7b4fcd286a350780faf0824d73aa150b21cbf1bccde883e6a96386cbe09973b4` |
| Steam 构建 26367565（CL-302256） | `4415933ce33476f14c837abb61a1b60af8b78cd81783896501913a7aac69e423` |
| UE4SS | `3.0.1-1183-gcdbc0b66`，KintaroModding/ue4ss |
| UE4SS.dll SHA-256 | `c273e7228687b647226fd63d7ca65888d313ece6be18996ec1320d00a5efe1f8` |
| 玩法参考 | wukong-steve 0.11.0，commit `9f213556519dca4498fd46f02af6236ae121ecae` |
| 资源版本 | Minecraft Java 1.21.1、26.3；固定提交的 Bedrock samples |

运行路径均从安装目录解析，不要求相同盘符、Steam 库位置或 Windows 用户名。模组不替换 PBZ.exe，不分发游戏 DLL、存档或账号配置。

高于表中最新 CL 的官方 Windows x64 构建，只要仍使用 UE 5.7，就可以直接双击 `Launch-PBZMC.cmd`。启动器校验游戏产品信息，在本机检查 UE4SS 的两个全局变量、四个战斗函数与两个死亡重试调用点。每处都必须唯一匹配，重试调用必须仍指向对应的状态函数。游戏进程还会复核实际加载的指令。成功后自动运行，玩家无需填写地址或下载地址表。

任何入口无法匹配、出现多个匹配或目标改变时，启动器会显示 `PBZMC-HOST`、游戏 CL 和失败位置，并停止启动模组。请在 [GitHub Issues](https://github.com/fjdsjd/pbz-mc/issues) 附上错误全文和 `UE4SS.log` 中的相关行。更新前建议使用 `Backup-PBZMC.cmd`。已知版本更改过的可执行文件及跨引擎版本须单独适配。

尚未承诺的范围包括所有剧情节点、其他修改输入／相机／角色模型的模组组合、多人同步及无限规模的建筑和红石负载。世界掉落物与 PBZ 原地图任意开采不在本版玩法内。
