# 更新日志

版本号遵循 [语义化版本 2.0.0](https://semver.org/lang/zh-CN/)，
变更记录格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)。

## [1.2.0] - 2026-10-08

### 新增 · GitHub 下载加速（dbeaver/windterm/tinyrdm/redis 共用）

- **DBeaver 改为 GitHub Release 组件**：官网 dbeaver.io 的下载链接最终重定向到
  `dbeaver/dbeaver` 的 Release 资产（国内直连很慢的根因），现在直接从 GitHub API 解析
  精确版本（结构同 windterm/redis），缓存文件名带上版本号，升级时不会误用旧缓存
- 新增 `download.githubAccelerators`（默认内置 3 个当前实测可用的加速镜像）：
  下载 `github.com` 直链时自动叠加「镜像前缀 + 原始地址」候选，HEAD 预检可用者优先，
  镜像全挂自动回退直链；置 `[]` 可关闭。所有落在 GitHub 的组件下载统一受益
- GitHub Release 类组件解析新增 `fallbackVersion` 兜底：接口失败且无本地缓存时
  改用配置的精确版本，不再拼出带 `latest` 的死链

### 修复 · Apifox 安装失败：把 zip 外壳本体误当安装器做 PE 预检

- `innerInstaller` 未配置时，「解壳后取包里体积最大的 exe」回退逻辑被外层 zip 路径
  短路（`$setupFile` 预先初始化成了 zip 自身路径，回退条件永远不成立），导致拿 zip
  本体做 PE 校验、误报「缺少 MZ 头」——实际上下载与解壳都已成功
- 解壳后现在始终重新定位安装器：优先按 `innerInstaller` 名字查找，找不到则取包里
  体积最大的 exe；PE 预检失败时同步清理解壳临时目录（此前每次失败会在缓存残留约 200MB）
- 「直启被拒自动改走 Shell 重试」对 zip 壳组件（Apifox）此前必然失败：外层重试还没开始，
  解壳临时目录就连同安装器一起被删了；现在临时目录保留到重试结束（成功/最终失败）才清理

### 修复 · PowerShell 5.1 下版本排序错乱（VM 上解析到错误版本的根因）

- `Sort-Object` 在 Windows PowerShell 5.1 中对 `[version]` 对象、以及超过 int32 的大整数键都会
  排出错误顺序（pwsh 7 正常，因此开发机验证未能暴露）：「取最新」会命中同线的 GA 别名
  （如 `idea-2025.3.win.zip`），「回退最近正式版本」甚至可能列出 2024.2.x 这类老版本——
  这正是 v1.1.1 之后 VM 上仍下载 `idea-2025.3.win.zip` 而非 `2025.3.6.1` 的根因
- 改为加权数值排序键 + 手写插入排序（纯运算符比较，PowerShell 5.1 / 7 结果一致）；
  版本线匹配改为显式取版本最大的条目，不再依赖列表顺序

### 变更 · IDEA 版本策略（默认 2026.2 版本线，最低 2025.3 硬限制）

- **默认版本线改为 `2026.2`**：自动取该线最新补丁（当前 2026.2.3）；离线兜底 `fallbackVersion`
  同步改为精确补丁 `2026.2.3`（实测直链 `idea-2026.2.3.win.zip` 长期有效）
- **最低版本硬限制 `2025.3`**（统一分发版起点）：发布列表解析时直接过滤 2025.3 以下条目，
  任何回退路径都不再出现 2024.x 等老版本；配置写死低于 2025.3 的版本会直接报错并给出改法
  （新增 `components.ide.minVersion`，默认 `2025.3`）
- 发布列表不可用时，「版本线」写法自动改用**同线 `fallbackVersion` 的精确补丁地址**：
  接口故障/离线也能拿到真实存在的内部小版本直链，而不是碰运气的 GA 别名
- 下载候选全部返回 HTTP 404 时，失败摘要新增专项提示：这些官方地址本身存在，
  404 多为出口网络/代理劫持，附 hosts / DNS / `download.proxy` 自查步骤
- IDEA 显示名不再带 Community/Ultimate 后缀（2025.3 起为统一分发版，无社区/旗舰之分）

## [1.1.1] - 2026-10-08

### 修复 · IDEA 版本解析（适配 2025.3 统一分发版）

- **适配 IDEA 2025.3 社区/旗舰合并**：合并后新版本（含 2025.3.x 补丁与 2026.x）只挂在 `IIU`
  产品代码下，下载文件名去掉了 IC/IU 前缀（如 `idea-2025.3.6.1.win.zip`）；`IIC` 停在
  2025.3 GA——旧逻辑只查 IIC，`latest` 永远解析到过期的 GA，且 `ideaIC-2025.3.*` 前缀已下线直接 404
- 解析改为**合并 `IIC`+`IIU` 双代码**取版本序最新；`version` 新增「版本线」写法：写 `"2025.3"`
  自动解析为该线最新补丁（当前 2025.3.6.1），默认配置与示例配置随之改为 `2025.3`；
  精确版本与 pinned 老版本（≤2025.2 的 `ideaIC-`/`ideaIU-` 前缀）行为不变
- 解析日志标注产品代码（如「JetBrains 发布列表（产品代码 IIU）」），回退候选列表同样来自合并后的双线

## [1.1.0] - 2026-10-08

### 新增 · 组件

- **WindTerm**（SSH/SFTP 远程管理终端）：开源便携 zip，版本从 GitHub Release 实时解析，解压即用
- **Apifox**（API 设计/调试/测试一体化）：官方固定 latest 链接；官方 zip 内是 NSIS 安装器，
  新增 `zipWrapped` 安装器形态——解壳后以 `/S /currentuser /D=` 静默装进安装目录
- **Tiny RDM**（Redis 可视化管理）：约 12MB 便携 zip，版本从 GitHub Release 实时解析，解压即用
- 三个新组件默认启用并进入 `standard` profile 与默认桌面快捷方式清单；同组工具会给出"同类提醒"（ssh / apitool / redisgui 分组）

### 新增 · 开机自启

- **PostgreSQL / Redis 开机自启默认开启**（登录时经「启动」文件夹静默拉起，全程无需管理员）：
  通过生成的 wscript 隐藏启动器（`pg-autostart.vbs` / `redis-tray.vbs`）拉起，连短暂的黑框也不出现
- **DSH 桌面端支持开机自启**（`components.dsh.autostart`，默认关闭）
- **Redis 托盘管理器**（`bin\redis-tray.ps1`，原生 PowerShell WinForms，零第三方依赖）：
  Redis 改为无窗口后台运行，任务栏不再挂着命令提示符窗口；通知区域小图标支持
  双击打开日志、右键重启 / 停止 / 退出托盘（保持 Redis 运行）；「Redis-启动/停止」快捷方式与自启项均已切到托盘方案
- 新增独立动作 `install.cmd -Action autostart`：改完 `user.json` 的自启开关后单独应用，无需重跑完整安装
- 开关语义完善：`autostart` 改为 `false` 后重跑即移除「启动」文件夹里的旧条目；`uninstall` 一并清理；`doctor` 增加自启检查项

### 变更 · 图标

- PostgreSQL / Redis 启停快捷方式换用合成图标：官方 logo 为主体、右下角叠加 Windows 风格
  启动（绿）/ 停止（红）角标；成品 `.ico` 内置 16–256 全尺寸，随安装复制到 `<root>\icons\`
- 图标素材与生成脚本归档在 `assets\icons\src\`（PostgreSQL 官方大象 PNG + Redis 官方 logo ico + Pillow 脚本），可复现

### 变更 · 引擎

- GitHub Release 解析逻辑从 redis 专属重构为通用形态（`githubRepo` + `assetPattern` + `tagPrefix`），新组件零成本接入

### 修复 · 安装器

- **Apifox 等安装器启动前增加 PE 预检与精确诊断**：解壳出的安装器先做文件头校验（架构 / 是否完整），
  启动失败时不再抛出难懂的 `not a valid application for this OS platform`，
  而是给出可行动的中文归因——杀毒软件解压后拦截清空（实测 0 字节/PE 残缺均报 Win32 193）、
  精简系统缺 32 位兼容层（SysWOW64）等，附隔离区核查与白名单建议
- **直启被拒自动改走 Shell 重试**：文件完好但 `CreateProcess` 被拒时（典型为安全软件行为拦截——
  只拦“控制台进程静默拉起安装器”、不拦用户双击），自动改用与双击同路径的 ShellExecute 再试一次，
  两种方式都失败才报错并说明归因
- **32 位 Windows 自动改用官方 win32 安装包**（`Apifox-win32-latest.zip`，`urlTemplates32` 可覆盖）

## [1.0.0] - 2026-09-30

首个公开版本。

### 新增 · 组件

- **JDK**：Temurin（Adoptium API 取最新 GA，默认 21，支持多版本共存），写入 `JAVA_HOME` 与 `JAVA_HOME_<大版本>`
- **Maven 3.9.9**：多镜像回退，自动生成 `settings.xml`（可切阿里云镜像、可选本地仓库位置）
- **Git 2.46.0**：MinGit 免安装版，只把 `cmd\` 加进 PATH，不污染系统 Git
- **Node.js 20.18.0**：可切 npmmirror 源，可选写用户级 `.npmrc`
- **DSH（DeepSeek Harness）**：默认安装官方**桌面端**，版本从官方更新清单 `nightly.yml` 解析，
  静默装到安装目录并复用已有安装；可选组件 `dsh-cli` 提供终端 `dsh web` / `dsh tui` / `dsh headless`
- **IntelliJ IDEA**：官方 `windowsZip`（默认社区版，可切 Ultimate），自动生成便携模式配置
- **PostgreSQL 17.2**：免安装二进制 + `initdb` 本地实例，端口被占用时自动顺延，脚本启停、可选开机自启
- **Redis 8.10.2**：Windows 构建，配置文件由参数生成，脚本启停
- **DBeaver CE**（默认）/ **HeidiSQL**（默认关闭，两者定位相同，二选一）
- **自定义软件**：`components.extras` 可加入任意 zip 包

### 新增 · 安装流程

- 版本动态解析：JetBrains API / Adoptium API / GitHub Release / 官方更新清单，逐级回退到本地缓存与配置里的兜底版本
- 下载：流式下载 + `Range` 断点续传 + 多镜像自动切换 + BITS 兜底；HEAD 预检会列出每个候选地址的探测结果
- 已有安装探测复用：环境变量 → PATH → 注册表 → 各磁盘常见目录；`existingPolicy=prefer` 时直接复用，不往别人的安装目录写文件
- 用户级环境变量与 PATH 管理：写入前自动备份、支持回滚，托管配置块可重复写入而不重复
- 数据库实例初始化与建库、连接信息汇总，且只在“二进制由本工具安装”时才创建实例

### 新增 · 定制化

- `config/user.json` 与 `config/default.json` 深度合并，可覆盖版本、镜像、端口、密码、快捷方式、组件开关
- 组件组合：`minimal` / `standard` / `full` 或自定义 profile；`-Components` 支持按 key 或分组名选择，并自动补齐依赖
- 快捷方式可自定义名称、图标、窗口样式与生成目录；数据库可随登录自动启动

### 新增 · 运维

- `status` 环境状态、`doctor` 自检（可执行文件版本、网络连通性、端口、长路径）
- `uninstall` 卸载/回滚：会先调用组件自带的卸载程序（如 DSH 桌面端），可保留数据库数据
- `restore` 从环境变量备份文件回滚
- 安装报告与运行日志统一落到 `<root>\logs\`

### 新增 · 工程约束

- 编码守门：`.ps1` 必须带 UTF-8 BOM、`.cmd` 必须无 BOM；`.gitattributes` 声明 `* -text`，
  禁止 Git 做任何行尾/编码转换，保证 clone 下来的字节与仓库完全一致
- `tools/Verify-Repo.ps1`：提交前自检（BOM、严格 UTF-8、语法解析、JSON、个人路径/令牌扫描、`config/user.json` 是否被忽略）
- GitHub Actions 在 `windows-latest` 上分别用 Windows PowerShell 5.1 与 PowerShell 7 各跑一遍自检

### 已知限制

- 仅支持 Windows 10 / 11 / Server 2019+ 与 Windows PowerShell 5.1+，未在 Linux / macOS 上验证
- 数据库启停依赖官方 `pg_ctl`；在提权会话中 PostgreSQL 官方限制可能导致实例无法启动
- DSH 桌面端是官方 NSIS 安装包，会在“添加/删除程序”里登记，不具备纯绿色形态（脚本会在卸载时一并清理）
- 需要管理员权限的场景（系统级环境变量、Windows 服务）不在本工具范围内，默认全部只写当前用户

[未发布]: https://github.com/italycalibur2019/Java-Dev-Env-Script/compare/v1.2.0...HEAD
[1.2.0]: https://github.com/italycalibur2019/Java-Dev-Env-Script/compare/v1.1.1...v1.2.0
[1.1.1]: https://github.com/italycalibur2019/Java-Dev-Env-Script/releases/tag/v1.1.1
[1.1.0]: https://github.com/italycalibur2019/Java-Dev-Env-Script/releases/tag/v1.1.0
[1.0.0]: https://github.com/italycalibur2019/Java-Dev-Env-Script/releases/tag/v1.0.0
