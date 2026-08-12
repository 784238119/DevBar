# DevBar

DevBar 是一个 macOS 菜单栏开发服务管理器。它把多个本地项目及其前台服务集中到一个界面中，适合在 vibe coding 开始前一键启动 Web、API、数据库代理等开发进程，并持续查看状态和日志。

> 当前版本为早期本地发布版：最低支持 macOS 15，产物使用 ad-hoc 签名，未经过 Apple Developer ID 签名和公证。

## 界面预览

> 以下图片用于展示 DevBar 的主要使用方式，具体文案和控件细节以当前版本为准。

### 集中配置工作区与服务

![DevBar 工作区与服务配置界面](docs/superpowers/specs/assets/devbar-settings-warm-prism-v2.png)

在主窗口中统一维护工作区、服务启动命令、健康检查和环境变量，并决定哪些服务参与“启动全部”。

### 从菜单栏快速控制服务

<p align="center">
  <img src="docs/superpowers/specs/assets/devbar-menubar-warm-prism.png" alt="DevBar 菜单栏服务控制界面" width="520">
</p>

无需反复切换终端，即可从菜单栏查看服务状态、启动或停止单个服务，并快速进入主窗口。

## 适合解决什么问题

- 每次开始编码前，需要在多个终端中重复进入目录并执行启动命令。
- 同一工作区包含多个服务，希望一键启动或停止，同时保留单个服务控制能力。
- AI 编码工具需要依赖本地服务，但服务是否启动、是否健康、日志在哪里不够直观。
- 不希望 DevBar 自动把服务设为开机启动；启动动作仍由使用者控制。

DevBar 只管理你明确配置的命令。它不会安装项目依赖，也不会猜测或自动修复失败的服务。

## 直接安装

1. 下载 DMG，打开后将 `DevBar.app` 拖入“应用程序”。
2. 首次打开若被 macOS 拦截，在“系统设置 → 隐私与安全性”中确认打开。
3. 添加工作区，填写项目根目录。
4. 为工作区添加服务，例如：

   - 名称：`Web`
   - 工作目录：`.`
   - 命令：`npm run dev`
   - 健康检查：`http://127.0.0.1:3000`

5. 回到菜单栏，点击“启动全部”开始 vibe coding。

命令通过非交互 zsh 在前台运行。若命令依赖只在交互式 shell 中初始化的工具，请先确认该工具可从当前 zsh 环境解析，或在服务环境变量中显式补充 `PATH`。

## 本地开发启动

前置条件：

- macOS 15 或更高版本
- Xcode（包含 macOS SDK）
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)，仅在修改 `project.yml` 后重新生成工程时需要

```bash
brew bundle
xcodegen generate
open DevBar.xcodeproj
```

在 Xcode 中选择 `DevBar` Scheme，运行到 `My Mac`。

也可以用命令行构建：

```bash
xcodebuild \
  -project DevBar.xcodeproj \
  -scheme DevBar \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/DerivedData \
  build
```

## Vibe coding 启动清单

在把 DevBar 交给 Codex、Claude Code 或其他 AI 编码工具前，建议按下面顺序配置：

1. 每个仓库建立一个工作区，根目录指向仓库根路径。
2. 每个长期运行的前台进程建立一个服务；不要把一次性迁移、删除或发布命令放入“启动全部”。
3. 优先配置 HTTP/TCP 健康检查，避免“进程存在”被误认为“服务可用”。
4. 密钥通过项目自身的安全配置或服务环境变量提供，不要写入启动命令。
5. 先在 DevBar 中手动启动一次并检查日志，再让 AI 工具依赖这些服务执行浏览器或接口验证。

推荐让 AI 工具先读取本 README，再读取 `project.yml` 和相关模块源码。修改服务调度、退出逻辑或日志目录时，应同时运行对应测试，不要只验证界面。

## 配置与日志

- 主配置：`~/Library/Application Support/DevBar/config.json`
- 配置备份：`~/Library/Application Support/DevBar/config.json.bak`
- 默认日志目录：由偏好设置中的“日志目录”决定
- 服务日志按 `工作区 UUID/服务 UUID/YYYY/MM/DD/` 分目录保存；默认保留 7 天，并在日志活动时定期清理过期日期目录

配置文件当前 schema 版本为 `1`。不要手工写入更高版本；应用会拒绝无法理解的未来 schema，避免静默破坏配置。

停止服务时，DevBar 按 `SIGINT → SIGTERM → SIGKILL` 的顺序回收进程组。退出应用时若仍有服务运行，会要求确认，不应通过强制退出替代正常停止。

## 版本更新

偏好设置中可以启用“自动检查更新”，也可以通过应用菜单或设置页立即检查。更新清单由公开仓库根目录的 `appcast.xml` 提供，安装包从 GitHub Releases 下载，并使用 Sparkle Ed25519 签名校验。

v0.1.0 尚未集成更新器，因此必须手动安装一次 v0.2.0 或更高版本；之后才能通过应用检查新版本。当前发布包仍是 ad-hoc 签名、未经 Apple 公证，默认只自动检查并提示，不启用后台静默安装。

## 测试

完整测试：

```bash
xcodebuild \
  -project DevBar.xcodeproj \
  -scheme DevBar \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/DerivedData \
  test
```

UI 测试依赖 macOS Accessibility/XCTest UI 会话，必须在已登录的图形桌面运行。只看到编译成功不能代表菜单栏和窗口流程已经通过。

## 打包

```bash
./Scripts/package-release.sh
```

脚本会执行 Release 构建、校验 app 与内嵌 `DevBarRunner`、验证 ad-hoc 签名，并在 `dist/` 生成：

- 面向普通用户安装的 DMG，其中包含 `DevBar.app` 和“Applications”快捷方式；
- 便于自动化分发的 ZIP；
- 两种产物各自的 SHA-256 文件。
- 使用本机钥匙串中的 `DevBar` Sparkle 私钥签名 DMG，并更新仓库根目录的 `appcast.xml`。

发布时应先提交代码与新生成的 `appcast.xml`，将对应 tag 推到 GitHub 后创建 Release 并上传 DMG；确认下载地址可访问后，最后再推送包含新 appcast 的主分支。这样客户端不会在安装包尚未就绪时看到更新。不要提交或导出 Sparkle 私钥。

正式对外分发前仍需：

1. 设置唯一且稳定的 Bundle ID 和版本号。
2. 使用 Developer ID Application 证书签名。
3. 提交 Apple Notary Service 并 staple 公证票据。
4. 在一台未安装开发证书的干净 Mac 上验证安装、首次启动、服务停止和升级。
