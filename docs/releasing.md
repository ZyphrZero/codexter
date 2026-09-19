# 双平台发布

## 构建基线

使用 Flutter 3.44.9 和仓库锁文件；Windows 在 `windows-2022` 上构建，MacOS 在 `macos-15` 上构建。平台命令和目录必须保持小写 `macos`，README 展示文字使用 `MacOS` 不影响程序。

Mac 构建执行 `flutter build macos --release --no-pub`，使用固定 SDK 的 Universal 默认目标。随后检查 `.app` 版本、所有 Mach-O 文件的 arm64/x86_64 架构和签名完整性，再用 `ditto` 打包、解包复核。不要用 Windows 压缩工具重新压缩 `.app`，否则可能丢失执行权限或 framework 符号链接。

当前 Xcode 工程使用本机临时签名（ad-hoc），**不是 Developer ID 身份签名或 Apple 公证**。自动生成 ZIP 不等于获得 Gatekeeper 信任；面向普通用户的顺畅分发仍需单独配置 Developer ID 签名和公证，本流程不关闭系统保护，也不伪造已公证状态。

## 验证和发布

先提交代码并推送测试分支。在 Actions → Build and Release 手动选择该分支，填写与 pubspec 一致的 Tag，例如 `v1.0.7`，保持 `publish=false`。这种模式允许 Tag 尚不存在，只构建并上传 Actions 附件，不修改 Release。

验收后更新并提交正式版本号，例如 `version: 1.0.7+8`，再推送对应 Tag：

```bash
git tag v1.0.7
git push origin v1.0.7
```

请使用尚未发布的版本号。工作流只接受 `v主版本.次版本.补丁版本`，不发布预览版本；Tag 与 pubspec 不一致会提前停止。手动选择 `publish=true` 时，构建源是该 Tag 的提交，而不是所选分支最新代码。各构建 job 使用 prepare 得到的同一提交 SHA。

Windows 和 Mac 构建均成功后，发布 job 才取得写权限，生成包含双平台信息的 `latest.json`。先创建草稿、上传全部资产、校验名称/大小和可用的 SHA256 摘要，最后一次性公开草稿。Mac 构建或上传失败不会留下 Windows-only 的公开新版。

草稿上传失败可以重新运行；已公开版本拒绝覆盖，必须增加版本号。仓库内发布工作流串行执行，且拒绝低于或等于现有最新正式版本的发布，避免旧任务回退更新入口。发布和删除 Tag、删除历史 Release 是不同操作；本流程不删除旧版本。

## 仓库配置

默认无需额外变量，发布到当前仓库并使用当前仓库的 `latest.json`。

| 配置 | 用途 |
| --- | --- |
| `vars.RELEASE_REPOSITORY` | 可选，公开下载仓库的 `owner/repo` |
| `secrets.RELEASE_TOKEN` | 独立发布仓库必需，需拥有目标仓库内容写权限 |
| `vars.UPDATE_MANIFEST_URL` | 可选，自定义 HTTPS 更新清单地址；两平台构建都会注入 |

使用独立发布仓库时，维护者必须提前在目标仓库准备同名 Tag（`--verify-tag`）；工作流不会在不明目标提交上静默创建 Tag。使用自托管更新清单 URL 时，发布仍上传到 GitHub，镜像同步由维护者配置。

## 更新兼容

`latest.json` 保留 `schema: 1`、`windows.installer_url`、`windows.installer_sha256` 等既有字段，旧 Windows 客户端继续可用。新增的 `macos` 节点声明 Universal ZIP、SHA256、架构及 `update_mode: manual`。

两平台使用相同的版本提示弹窗。Windows 保留自动下载安装；Mac 只打开清单 `release_url` 指定的 GitHub 版本页，不下载安装器、不关闭应用。GitHub 地址必须使用 HTTPS 并指向相应 Tag；Mac 不会因为旧 Windows-only 清单而误报可安装更新。

## 官方依据

- Flutter 构建：https://docs.flutter.dev/deployment/macos
- Mac 分发与公证：https://docs.flutter.dev/platform-integration/macos/building
- GitHub job 间资产传递：https://docs.github.com/en/actions/tutorials/store-and-share-data
- GitHub 草稿发布：https://cli.github.com/manual/gh_release_create
- GitHub 发布草稿：https://cli.github.com/manual/gh_release_edit
