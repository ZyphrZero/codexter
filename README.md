# Codexter

给网页版 ChatGPT 使用的本地 MCP 工具服务，支持 **Windows 和 MacOS**。将本地项目映射为独立 MCP 地址，统一管理文件读写、代码搜索、命令执行、Skills、下游 MCP 和 Cloudflare Tunnel。

![Codexter](docs/screenshot.png)

## 下载与安装

前往 **[GitHub Releases](https://github.com/meesii/codexter/releases/latest)**，按系统选择附件：

| 平台 | 下载文件 | 安装方式 |
| --- | --- | --- |
| Windows x64 | `Codexter-x.x.x-Setup.exe` | 运行安装向导 |
| Windows x64 便携版 | `Codexter-x.x.x-windows-x64.zip` | 解压后运行 |
| MacOS 12+ | `Codexter-x.x.x-macos-universal.zip` | 解压，将 `Codexter.app` 拖入“应用程序” |

MacOS 包同时包含 Apple Silicon 和 Intel 架构；从包含双平台发布流程的版本开始提供，旧版 Release 可能只有 Windows 附件。当前未配置 Windows 代码签名或 MacOS Developer ID 签名、公证，请核对下载来源；遇到系统安全拦截时不要关闭系统保护。

## 快速开始

1. 准备 Cloudflare 账号和已接入 Cloudflare 的域名。
2. 完成首次向导：`Cloudflared → 域名 → Tunnel → 完成`。授权未自动打开时，复制界面中的完整链接。
3. 新建工作区、选择本地项目目录，复制生成的 HTTPS MCP 地址。
4. 将地址添加到支持远程 MCP 的 ChatGPT 中。

```text
https://mcp.example.com/{workspace-uuid}/mcp
```

工作区共用本地服务和 Tunnel。**多台电脑独立运行时，应使用不同的 Tunnel 名称和子域名**，避免覆盖另一台电脑的 DNS。重新授权不会补回已有 Tunnel 的运行凭据；不要把凭据提交到 Git。

完成向导后，应用直接显示主界面，在后台启动本地服务、连接 Tunnel 并完成一次环境检查。各检查项异步并行执行，每项完成后立即更新结果；左侧“环境检查”导航显示完成进度及失败、注意或全部通过的结果。列表默认将失败和需注意的项目置顶，同类项目保持固定顺序。进入或切换“环境检查”页面会复用本次运行中的检查结果，不重复发起请求。需要刷新时点击“重新检查”，完成时间显示在页面顶部。服务连接失败会在主页提示，检查详情与修复操作保留在环境检查列表中。

## 平台差异

两端均支持工作区、文件工具、命令执行、Skills、下游 MCP 和 Tunnel；外部命令仍需在各自电脑上安装。

| 功能 | Windows | MacOS |
| --- | --- | --- |
| 窗口 | 自绘标题栏、系统托盘 | 系统标题栏、顶部菜单、菜单栏状态图标 |
| 内置 Computer Use | 支持，依赖本机 Codex runtime | 暂不支持 |
| 检查更新 | 下载并启动安装程序 | 提示新版本，跳转 GitHub 手动下载 |

MacOS 的关闭按钮和 `⌘W` 隐藏窗口，后台服务继续运行；`⌘Q` 正常退出。两端均可通过“帮助 → 检查更新”或侧栏版本提醒查看更新。

## 开发运行

使用 **Flutter 3.44.9 / Dart 3.12.2**。Windows 需要 Visual Studio C++ 桌面工具链；Mac 需要完整 Xcode 和 CocoaPods。环境安装参考 [Windows](https://docs.flutter.dev/platform-integration/windows/setup) / [MacOS](https://docs.flutter.dev/platform-integration/macos/setup)。

```bash
flutter doctor -v
flutter pub get --enforce-lockfile
flutter run -d windows    # Windows
flutter run -d macos      # MacOS，在 Mac 上执行
```

修改 Swift 或原生窗口配置后，需要停止并重新运行，不能只热重载。

### 配置目录

| 环境 | Windows | MacOS |
| --- | --- | --- |
| Debug | `%APPDATA%\codexter-dev` | `~/Library/Application Support/codexter-dev` |
| Release | `%APPDATA%\codexter` | `~/Library/Application Support/codexter` |

也可通过“文件 → 打开配置目录”访问。两种环境的数据独立；跨电脑同步源码即可，不要直接覆盖整份应用配置。

### 检查与打包

```bash
flutter analyze --no-pub
flutter test --no-pub
```

Windows 执行 `./scripts/build_windows.ps1`，MacOS 执行 `bash scripts/build_macos.sh`，产物输出到 `dist/`。

## 自动发布

更新 `pubspec.yaml` 后，推送对应正式版本的 `v*` Tag。GitHub Actions 分别构建 Windows 和 MacOS；两端成功后，统一上传安装包和 `latest.json`，再公开 Release。普通分支推送不会发布。

也可在 Actions 的 **Build and Release** 中选择分支，填写对应版本 Tag，保持 `publish` 关闭，只验证打包并下载构建附件。

发布变量、失败重试和签名限制见 [发布说明](docs/releasing.md)；平台实现与开发排查见 [平台适配说明](docs/platform-adaptation.md)。
