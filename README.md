# PBZMC

在《影之刃零》（PBZ）的关卡里使用 Minecraft 风格的背包、装备、建造与红石玩法。史蒂夫外观与玩法模式独立，PBZ 原版武器仍走原生战斗逻辑。

[![实机演示](docs/media/demo.jpg)](https://github.com/fjdsjd/pbz-mc/releases/download/v0.1.0-alpha.1/PBZMC-demo.mp4)

[观看／下载演示视频](https://github.com/fjdsjd/pbz-mc/releases/download/v0.1.0-alpha.1/PBZMC-demo.mp4) · [下载模组](https://github.com/fjdsjd/pbz-mc/releases) · [安装教程](docs/INSTALLATION.md) · [按键说明](docs/CONTROLS.md)

演示为本项目开发期间的真实游戏录像，包含角色、剑盾、放拆方块、末影珍珠和背包预览。录像早于当前发行版，部分 UI 和初始装备已有更新。

## 安装

1. **退出游戏并备份存档。** 原生存档和模组数据需要一起保存，具体位置见[备份说明](docs/INSTALLATION.md#备份与恢复)。
2. 在 Releases 下载 `PBZMC-0.1.0-alpha.1-win64.zip`，不要下载 GitHub 自动生成的 Source code 压缩包作为模组。
3. 将压缩包内容解压到 PBZ 游戏根目录，也就是包含 `platform/steam/PBZ.exe` 的目录。解压后 `Launch-PBZMC.cmd` 应与 `platform` 文件夹并列。
4. 双击 **`Launch-PBZMC.cmd`**。首次运行会备份存档、校验游戏版本、下载并在本机转换资源，然后安装模组并通过 Steam 启动。以后使用同一脚本直接启动。

首次准备需要联网及额外磁盘空间，不需要自行安装 Python、编译器、Java 或 Minecraft 模组加载器。资源来自固定版本的原始来源并校验哈希；不会安装到系统 Python，不会改动 Minecraft 安装目录。下载受阻时保留缓存、重试即可。普通游戏启动前务必完成第一次准备。

仅支持 Windows x64 和[已验证的 PBZ 构建](docs/COMPATIBILITY.md)。这是早期测试版，不承诺跨所有章节、所有模组组合或未来 PBZ 更新兼容。游戏更新后，启动脚本和原生桥会拒绝未经验证的版本；请等待对应更新，不要删除版本检查。

## 当前玩法

- 常驻史蒂夫、MC 第一人称与 PBZ 原版视角、实时背包人物预览。
- 27 格背包、9 格快捷栏、副手、护甲、分类分页目录、垃圾槽与物品名称提示。PBZ 原生槽位作为引用物品进入同一个快捷栏。
- 多材质剑、镐、铲、斧、弓与盾；MC 装备没有耐久消耗。PBZ 原生战斗与 MC 物品按当前选择切换。
- 红心、护甲、金心与效果显示，经验条映射 PBZ 体力。金苹果、附魔金苹果、图腾、末影珍珠、紫菘果、鞘翅及烟花。
- 放置和挖掘模组方块、TNT、船、门、水与岩浆、活塞、粘性活塞、红石器件、粘液块、蜂蜜块与观察者。不能任意挖掘 PBZ 原地图。
- `/gamemode creative` 与 `/gamemode survival`，支持 Tab 补全。创造模式具有飞行与伤害免疫；不开放其他命令。

**新存档初始快捷栏：** PBZ 武器引用、木剑、金苹果 ×1、附魔金苹果 ×1、末影珍珠、泥土、TNT、打火石、空格。盾牌在副手。PBZ 槽位来自实际原生装备，不生成额外武器。已有模组存档保留原有物品和布局。

背包、数量和建筑先在内存中提交，**只在 PBZ 原生保存入口保存时落盘**。退出前请正常保存；强退或在最近保存后继续建造，可能丢失后续改动。安装脚本的文件备份不等于替你在游戏里保存进度。

## 卸载、更新和故障

先退出游戏，再使用 `Backup-PBZMC.cmd` 备份。`Uninstall-PBZMC.cmd` 只删除安装记录中且内容未被修改的模组文件，保留原生存档、模组数据和备份。更新、恢复、与其他 UE4SS 模组共存的处理见[安装教程](docs/INSTALLATION.md)。

问题反馈：[GitHub Issues](https://github.com/fjdsjd/pbz-mc/issues)。请提供发行版本、游戏版本、复现步骤和相关日志片段；不要上传完整存档、账号信息或含个人路径的日志。

## 源码与许可

源码公开，按 **PolyForm Noncommercial 1.0.0** 提供。该许可限制商业用途，因此本项目不能被当作 MIT 等允许任意商业使用的开源代码。复用的玩法基线为 [wukong-steve 0.11.0](https://github.com/nicedoctors/wukong-steve/tree/9f213556519dca4498fd46f02af6236ae121ecae)，保留作者声明；其余依赖遵循各自许可。见 [LICENSE](LICENSE)、[NOTICE](NOTICE) 和[构建说明](docs/BUILDING.md)。

Minecraft 原始贴图、模型、字体、音效以及 PBZ 游戏文件不包含在源码仓库或发行压缩包中，也不适用本项目源码许可。首次启动在玩家本机准备所需资源；请遵守原游戏的条款与 [Minecraft 使用规范](https://www.minecraft.net/en-us/usage-guidelines)。本模组不附带游戏本体或任何个人存档。

**非官方 Minecraft 产品，未经 Mojang 或 Microsoft 批准，亦与其无关联。非《影之刃零》官方产品。** Minecraft 属于 Mojang／Microsoft，《影之刃零》属于其权利人。
