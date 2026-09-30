# 贡献指南

先说结论：**提交前请务必跑一遍 `tools\Verify-Repo.ps1`**，它和 CI 里 Windows PowerShell 5.1 那一遍等价。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\Verify-Repo.ps1
```

这个项目没有构建步骤 —— 纯 PowerShell 脚本，改完直接跑。

---

## 一、欢迎什么样的贡献

- **Bug 报告**：请用 [Issue 模板](.github/ISSUE_TEMPLATE/bug_report.yml)，里面要求的 `doctor.cmd` 输出是最关键的信息
- **兼容性反馈**：在你机器上跑通/跑不通的结果都很有价值（尤其是杀软拦截、内网代理、非默认安装路径、已有环境复用这几类场景）
- **文档**：错别字、表述不清、缺少示例，直接 PR 即可
- **新组件 / 新镜像**：参见下面「五、加一个新组件」
- **不要提交**：第三方软件的安装包（仓库只放脚本，下载地址写在配置里）

---

## 二、编码铁律（最容易踩的坑）

这个项目对文件编码极其敏感，原因很实在：目标运行环境是 **Windows PowerShell 5.1**，
它读取**不带 BOM** 的文件时会按系统 ANSI（中文系统上是 GBK）解码 —— 中文注释变成乱码，
严重时直接破坏语法解析（报 `Missing closing ')' in expression` 之类莫名其妙的错）。

| 规则 | 说明 |
| --- | --- |
| `.ps1` **必须**带 UTF-8 BOM | 编辑器里保存为 “UTF-8 with BOM”；VS Code 可设 `"files.encoding": "utf8bom"` |
| `.cmd` / `.bat` **必须无** BOM | 有 BOM 时 `cmd.exe` 会把 BOM 当成第一条命令的一部分 |
| 其它文本文件用 UTF-8（无 BOM 即可） | `.json` / `.md` / `.yml` / `.gitignore` 都按 UTF-8 读取 |
| 不要改 `.gitattributes` 的 `* -text` | 它禁止 Git 做行尾/编码转换，保证 clone 出来的字节与仓库一致。改成 `text=auto` 会让 BOM 和 CRLF 在 checkout 时被动过 |

> 曾经出过三次事故：编辑后 BOM 被编辑器吞掉 → 整个脚本按 GBK 误读。
> `tools\Verify-Repo.ps1` 就是为这类问题写的，别绕过它。

---

## 三、PowerShell 陷阱清单（都是真实踩过的）

1. **变量名不区分大小写**：脚本参数 `$ConfigFile` 和局部变量 `$configFile` 是**同一个变量**。
   历史事故：解析默认配置路径时顺带把参数写成非空，导致 `config\user.json` 被静默忽略。
   改参数名/局部变量名时，务必确认全文没有重名。
2. **数组字面量里的 `+` 拼接必须整体加括号**：
   `@('a' + $x + 'b')` 会被解析成**三个元素**（逗号优先级高于 `+`），写文件时就变成三行。
   历史事故：生成的 `dsh-cli.cmd` 里 `set "PATH=..."` 被拆成三行，PATH 直接失效。
   正确写法：`@(('a' + $x + 'b'))`。
3. **别用自动变量/只读变量当普通变量名**：`$args`、`$home`、`$Host`、`$input`、`$error` 等。
   本项目里已经因此把 `$Host` 改成 `$BindHost`、`$home` 改成 `$homeDir`。
4. **外部命令统一走 `Invoke-Process`**，不要直接用 `Start-Process`：
   PowerShell 5.1 的 `Start-Process -PassThru` 在部分环境取不到 `ExitCode`（返回空）。
   `Invoke-Process` 还封装了超时与**有界读取**。
5. **会派生长驻子进程的命令不要捕获输出管道**：例如 `pg_ctl start` 会拉起常驻的 `postgres.exe`
   并继承输出管道，`ReadToEnd` 会永远等不到管道关闭（症状是脚本“卡死”在启动 PostgreSQL）。
   这类调用要加 `-InheritConsole`（输出直通），并用真实连通性（如 `pg_isready`）判断成功。
6. **往原生命令的 stdin 写行时会带 `\r`**：某些工具会因此把输出参数当成含控制字符的字符串
   加引号转义（`git check-ignore --stdin` 就是这样，导致精确匹配静默失效）。
   能不用 stdin 就用命令自身的输出（例如用 `git ls-files --cached --others --exclude-standard`
   取“会被提交的文件”，而不是自己拼 `check-ignore`）。
7. **语法细节**：`[IO.FileMode]::$mode` 这种写法不存在（要写 `[IO.FileMode]::Create`）；
   `if (Test-RemoteUrl ...).Ok` 缺少括号，必须先括起来再取属性。
8. **`Write-TextFile*` 的参数是 `[string[]]`**：传空字符串元素需要 `[AllowEmptyString()]`，
   否则会被参数绑定拒绝。

---

## 四、目录结构

```
Setup-JavaDevEnv.ps1        参数解析与流程调度（唯一入口）
lib\00-Common.ps1           日志、配置合并、下载（断点续传/BITS）、解压、用户环境变量、快捷方式
lib\10-Catalog.ps1          组件目录、版本解析、已有安装探测、安装引擎（archive/npm/installer）
lib\20-Configure.ps1        各组件初始化（Maven / IDEA / Node / PG / Redis / DBeaver / DSH）
lib\30-Actions.ps1          install / status / doctor / uninstall / 报告
config\default.json         全部默认值
config\user.example.json    定制示例（`config\user.json` 已被 .gitignore，含密码，别提交）
tools\Verify-Repo.ps1       编码与语法自检（CI 与本地共用）
docs\images\                README 用的截图（PNG，小写英文文件名）
```

---

## 五、加一个新组件

1. `config\default.json` → `components.<key>`：写 `enabled`、`version`（可 `latest` + `fallbackVersion`）、
   `urlTemplates`、`dirTemplate`，以及组件自己的配置项。
2. `lib\10-Catalog.ps1` → `Get-DetectionRules`：补一份探测规则
   （`Commands` / `EnvVars` / `Consumers` / `NameGlobs` / `Registry` / `HomeProbe` / `VersionCmd`），
   这样脚本能发现并复用机器上已有的安装。`HomeProbe` 同时也是注册表条目的过滤器。
3. `lib\10-Catalog.ps1` → `Get-ComponentCatalog`：加条目。`Kind` 三选一：
   - `archive`：压缩包（zip / tar.gz），走 `Install-ArchiveComponent`
   - `npm`：npm 全局包，走 `Install-NpmComponent`（需要 `Requires 'node'`）
   - `installer`：自带安装程序（NSIS 等），走 `Install-InstallerComponent`
4. 需要初始化配置就写 `Configure-<X>` 到 `lib\20-Configure.ps1`，用 `Add-SpecShortcut` 加快捷方式
   （`Item` 要与 `shortcuts.items` 里的名字对应）。
5. 同步 `config\user.example.json`、README 的组件表与 `-Components` 帮助文本。
6. 如果是需要联网取版本的组件，参考 `Resolve-DynamicVersions` 里 IDE / DSH 的写法：
   接口 → 缓存 `cache\versions.json` → 配置里的兜底版本，逐级回退，并且**日志里写清来源**。

---

## 六、怎么测（少踩坑的姿势）

- **一定用临时安装目录**：`-Root E:\tmp\javadevenv-test`，别拿自己的真实目录试。
- **别动环境变量**：加 `-NoEnv -NoShortcuts`，只验证下载/解压/探测逻辑。
- **先看计划**：`-Action plan`（等价于 `-DryRun`）能零副作用地检查版本解析与探测结果。
- **数据库组件要小心**：默认 `existingPolicy=prefer` 会复用已有实例；要测“新建实例”请显式改 `-Root` 与端口，
  并且确认不会往别人已装的目录里写文件。
- **需要真实执行安装器/命令时**：`Invoke-Process` 的超时与有界读取请保持有效，
  否则会重现“脚本卡死”那类问题。
- 改完自检三件套：`Verify-Repo.ps1` → `-Action plan` → `-Action status`。

---

## 七、PR 要求

- 一个 PR 解决一件事；涉及行为变化的，请在描述里写清**验证方式**与**影响面**
  （例如：改了哪个默认值、会不会影响已有用户、是否需要重跑安装）。
- 涉及编码、参数命名、组件默认开关的改动，请特别说明。
- CI 必须通过（`.github/workflows/verify.yml`，用 Windows PowerShell 5.1 与 PowerShell 7 各跑一遍自检）。
- 不需要提供截图，但涉及日志/表格输出的改动，贴一段真实输出会方便 review。
