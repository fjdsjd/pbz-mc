# 命令与命令方块

本说明对应命令扩展开发版 `0.1.0-alpha.6-dev.11`。公开的 alpha.5 尚不包含此功能。目录、语法和调度参考 Minecraft Java 26.3；PBZ 没有原版 Minecraft 服务器、维度或世界生成器，因此**收录命令名称不代表已实现其全部参数和系统**。

## 使用

按 `/` 打开命令行，Enter 执行、Esc 关闭、Tab／Shift+Tab 补全，↑／↓ 查看本次运行的历史。支持 Home／End、方向键及 Ctrl+A。当前输入使用物理键位，尚未接入剪贴板和中文输入法；文件中的 UTF-8 命令不受此限制。排队中的命令显示等待，只有实际执行成功才关闭输入框；失败显示具体原因。

在 **B → 红石** 中领取脉冲、循环、连锁命令方块。放置后对准方块右键打开编辑器，可以修改命令、种类、条件模式、红石需求及输出记录。点击“完成”保存设置，不直接执行命令；Esc 取消编辑。使用 MC 原始方块纹理、动画、图标和按钮资源。

- 脉冲型：红石从无到有时执行一次；“保持开启”在激活时执行一次。
- 循环型：激活后每个游戏刻执行一次，停止供电后结束；已排入当前刻的一次执行仍会完成。
- 连锁型：沿前一个命令方块箭头方向继续，条件型要求背后的方块执行成功。“保持开启”不代表脱离命令链自行执行。
- 链条顺序在同一逻辑游戏刻内保持。较长链会分多个渲染帧处理，不能用缩短等待或无限循环阻塞游戏线程。
- 比较器读取成功次数，输出强度最多 15。编辑器的上次输出和成功次数来自实际完成的命令，不把入队当作成功。

## 实体、坐标和安全边界

`@s`、`@p`、`@a`、`@r`、`@e`、`@n` 共用 MC／PBZ 实体选择器。可组合 `type`、`name`、`tag`、`team`、`distance`、`x/y/z`、`dx/dy/dz`、`limit`、`sort`、`scores`、`nbt` 和角度过滤；未实现的过滤条件报错。`@s` 在玩家命令中指玩家，命令方块本身没有实体执行者，应使用 `@p` 或 `execute as`。

MC 生物类型使用 `minecraft:zombie` 等 ID；PBZ 类型由实际加载的原生类生成 `pbz:...`，不硬编码敌人名字。用 `/data get entity @n` 查看最近生物的 ID 和数据。可使用该生物的 UUID 精确选择。原生召唤只允许已经识别并验证的当前关卡角色类，找不到或冲突的类型会报错。

坐标单位为格，1 格对应 PBZ 的 100 厘米。X/Z 为水平、Y 为高度，以当前地图既有 MC 网格为原点。支持绝对、`~` 相对和 `^` 局部坐标。`/tp` 是直接传送，可能把角色放进地形；请先用附近可见位置测试。原版场景不是 MC 方块，`fill/clone/setblock` 只操作模组建筑，不挖掉原地图。

`@e` 包含 PBZ 角色和玩家，`kill @e` 会触发实际死亡。测试建议先给临时生物加专用标签，再以标签选择，避免影响剧情角色。Boss 的原生阶段、护盾、伤害免疫和死亡事件仍由 PBZ 判定；操作被原生拒绝时显示错误。

## 已接入的范围

当前有 45 个独立命令处理器，另支持 `tp`、`tell`、`w`、`tm` 四个别名。下表中的限制是实际实现范围，不能按原版全部子命令理解。

| 命令 | 实现与限制 |
| --- | --- |
| `help`、`list` | 列出可执行命令、查询原版语法、列出本机玩家 |
| `gamemode` | 玩家生存／创造；不实现旁观或冒险规则 |
| `teleport` / `tp`、`rotate` | 玩家、MC 生物、PBZ 角色传送／转向；船只须通过空间检查 |
| `summon` | 目录中的 91 种 MC 生物，以及当前已识别的 PBZ 类型；遵守召唤物数量上限 |
| `kill`、`damage` | 对真实实体调用死亡／伤害入口；`damage` 数字为该实体生命单位，不是百分比；伤害类型和来源仅接受已接入路径 |
| `effect` | 支持的实际效果包括速度、缓慢、回血、中毒、凋零、瞬间治疗／伤害；MC 生物另有力量、虚弱、抗性、防火和吸收。玩家复用既有效果服务；不支持的目标／效果组合报错，不能把玩家移动字段强改当作加速成功 |
| `attribute` | 最大生命、移动速度、攻击力查询及有限的基础值修改；原生攻击／生命属性不能任意覆盖。不支持属性 modifier 子命令 |
| `tag`、`team`、`teammsg` / `tm` | 标签、队伍成员和显示元数据；可用于选择器。队伍不会自动改写 PBZ 仇恨或碰撞，相关选项报错 |
| `ride` | 玩家或 PBZ 生物乘坐模组船／离船；不承诺任意实体互相骑乘 |
| `give`、`clear`、`item` | 玩家真实背包和装备；保留 PBZ 武器槽引用、检查容量及物品唯一归属。`item` 当前支持 `replace entity … with …` |
| `setblock`、`fill`、`clone` | 模组方块、状态和已支持的方块数据；保留碰撞与内存事务。填充最多 8192 格、复制最多 4096 格，体积超限在修改前报错 |
| `scoreboard`、`trigger` | dummy／trigger 目标、分数操作和触发授权；按原版 32 位整数计算。自动游戏统计准则及原版侧栏没有接入 |
| `data` | 实体／方块可写字段、独立 storage 数据、路径查询及 merge/modify/remove；禁止写原生指针或未验证字段 |
| `execute` | as/at、相对位置／旋转／朝向／锚点、if/unless、score/data/block/entity 条件和 store；不支持不存在的跨维度、数据包 predicate 等路径 |
| `function`、`return`、`schedule` | 本机 `.mcfunction` 文件、函数返回及延迟执行；不支持数据包函数标签或宏。定时任务与逻辑时钟随原生存档点保存 |
| `say`、`me`、`msg` / `tell` / `w`、`tellraw`、`title` | 本机文本提示；基础文本组件，不是多人聊天。标题当前使用模组提示层，不模拟原版完整标题排版、交互文本和本地化组件 |
| `gamerule` | 命令反馈开关、最大连锁数、execute 分支数及方块修改预算；不支持管理员广播和未接入的生存／服务器规则 |
| `random` | `value` / `roll` 范围随机整数；没有持久化随机序列 |
| `compute` | default／entity／block 上下文中的整数／浮点常量求值；其它 number provider 报错 |
| `bossbar` | 自定义血条增删、名称、颜色、分段、数值及玩家显示范围；MC 原图，最多 64 条，随命令状态保存。支持 `execute store … bossbar`。不替换 PBZ 原生 Boss 血条 |
| `spreadplayers` | MC／PBZ 生物安全分散，支持组队及 `under` 高度；先检查地面、完整身体空间和所有目标，再分批传送。最多 128 个目标；失败回滚，船只不接受此命令 |
| `enchant` | 为玩家主手重锤添加实际生效的致密 1–5、破甲 1–4、风爆 1–3，保留物品实例及附魔光效；致密与破甲互斥。未接入的附魔及原生装备明确报错 |
| `playsound`、`stopsound` | 164 种已导入的 MC 声音事件，位置、音量、音调与分类；停止操作会真正释放声音，不影响 PBZ 原生音效。其它资源 ID 报错 |
| `particle` | 已导入的 `crit`、`enchanted_hit`、`portal`、`gust`、`small_gust`；位置、散布、速度、数量及观察玩家，最多同时 96 个。不支持的资源／粒子参数报错 |
| `swing` | MC 模式玩家和具有对应手臂的 MC 生物可播放左右手 `whack`／`stab`／`none`；纯动作，不触发攻击或伤害。PBZ 原生武器姿态及未适配实体报错 |
| `version`、`time` | 查询实际模组版本和 `time query gametime` 逻辑刻。PBZ 没有 MC 昼夜时钟，修改时间及 daytime/day 查询报错 |
| `stopwatch` | 本次运行中的实时时钟 create/restart/query/remove；不随存档恢复 |

实际保留全部 94 个原版根命令名称供补全和语法查询。以下 41 个名称所需系统尚不存在，调用显示 `command-requires-unavailable-system:<名称>`：

`advancement`, `ban`, `ban-ip`, `banlist`, `datapack`, `debug`, `deop`, `dialog`, `experience`, `fetchprofile`, `fillbiome`, `forceload`, `jfr`, `kick`, `locate`, `loot`, `op`, `pardon`, `pardon-ip`, `perf`, `place`, `posteffect`, `publish`, `recipe`, `reload`, `save-all`, `save-off`, `save-on`, `seed`, `setidletimeout`, `spectate`, `stop`, `test`, `tick`, `transfer`, `unpublish`, `waypoint`, `weather`, `whitelist`, `worldborder`, `xp`。

`defaultgamemode`、`difficulty`、`setworldspawn`、`spawnpoint` 没有经过验证的 PBZ 映射，显示 `command-unsupported-host-mapping:<名称>`。已接入命令中未实现的参数也明确报错，不记录虚假的成功状态。

## 示例

```mcfunction
gamemode creative
give @s minecraft:command_block 1
summon minecraft:zombie ~3 ~ ~ {Tags:["demo"],NoAI:1b}
data get entity @e[tag=demo,limit=1]
damage @e[tag=demo,limit=1] 2
tp @e[tag=demo] ~4 ~ ~
scoreboard objectives add counter dummy
scoreboard players add clock counter 1
execute as @e[tag=demo] at @s run say demo
kill @e[tag=demo]
```

循环命令方块可填写 `scoreboard players add clock counter 1`；其箭头方向放一个“连锁／有条件／保持开启”方块，填写 `execute if score clock counter matches 20 run say tick20`。先在聊天中建立 `counter` 目标，再激活循环方块。

函数位置为游戏目录的 `platform/steam/ue4ss/Mods/PBZMCProbe/Scripts/pbzmc-data/functions/<命名空间>/<名称>.mcfunction`。例如 `functions/minecraft/demo.mcfunction` 可用 `/function minecraft:demo` 运行，或 `/schedule function minecraft:demo 2s replace` 两秒后运行。每行一条命令，`#` 开头为注释。文件最多 1 MiB，不会作为 Lua 或系统脚本执行。

## 性能、保存和报错

`fill`、`setblock` 和 `clone` 是命令世界编辑，允许目标格与玩家、MC 生物或 PBZ 实体相交；不会因为玩家站在目标区域就整条失败，也不会悄悄跳过该格。普通右键放置、活塞推动及读档恢复仍使用各自的碰撞规则。命令不关闭角色或方块的实际碰撞，不改动 PBZ 原地图；现有 MC 方块占位、容量与事务冲突仍会检查。

相对坐标按玩家脚部位置解析，范围包含两个端点。例如 `/fill ~ ~ ~ ~10 ~1 ~10 minecraft:tnt` 会填充 11×2×11，共 242 格，包含玩家当前所在格；若只想铺脚下的一层，可使用 `/fill ~ ~-1 ~ ~10 ~-1 ~10 minecraft:tnt`。

单方块 `data` 修改在一次游戏线程回调内完成校验和提交；运行中的命令方块更新上次输出时不会阻止停用循环，未修改的最新输出会保留。并发编辑了命令或更换了方块仍返回冲突，不覆盖玩家的新修改。

实体列表同帧共享，写操作使缓存失效；效果只更新受影响对象。建筑修改分 8 格批次在游戏线程执行，普通命令每帧最多完成 8 项并使用约 2 毫秒调度预算；单次 Unreal 调用可能超过预算，预算不是绝对帧耗时保证。安全分散每步只查询一个目标位置或移动一名实体，最多 4096 次候选／32768 次地形查询；声音空间参数以 20 Hz 更新，最多 16 个声部。队列最多 64 条，递归深度 32，每次最多 65536 次规则操作。滥用大范围选择器或高频命令仍会增加开销。

命令行最多 32767 个 UTF-16 单元，命令方块最多 32500；命令状态数据最多 2 MiB，延迟函数队列最多 1024 项。读取／解析／原生调用／事务冲突都返回具体错误。执行中拆掉来源方块会取消尚未完成的命令。批量修改失败会回滚；若玩家挡住恢复位置，界面提示离开施工区域，并暂停新命令及 MC 保存，直到恢复完成。

命令方块、分数、标签、自定义血条、storage 和定时函数先存内存，只有 PBZ 原生存档点实际保存才落盘。原生 NPC 的 UUID 在本次世界绑定内稳定，重新加载的原生角色不承诺继承旧标签和队伍。MC 召唤物仍沿原规则在切图／读档时清理；命令不会改变这个生命周期。请定期同时备份原生存档和模组数据，避免把未保存的测试结果当作持久进度。
