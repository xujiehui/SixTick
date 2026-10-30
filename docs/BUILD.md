# GitHub Actions 构建

工作流位于 `.github/workflows/build.yml`，固定使用 Flutter 3.35.7。
推送到 `main`、推送 `v*` 标签、提交面向 `main` 的 Pull Request 时自动运行。
也可以在仓库 **Actions → Build applications → Run workflow** 中手动运行。
手动运行入口需要该工作流已提交到默认分支。

工作流先在 Ubuntu 上执行 Python 服务测试、Flutter 静态分析及全部客户端测试，
包括通过回环地址连接临时 Python 服务的集成测试。通过后，在各平台 runner 上构建应用。
仅测试命令开启 `ALLOW_INSECURE_LOCALHOST`；应用构建保持默认 HTTPS 限制。

## 下载产物

打开对应的 Actions 运行记录，在 **Artifacts** 区域下载，保留期为 14 天。

| Artifact | 内容与用途 |
|---|---|
| `six-tick-android-debug-apk` | 调试签名的 APK，可用于 Android 安装测试；不作为正式发行包 |
| `six-tick-android-release-unsigned-aab` | 未签名的 Release AAB，正式发行前需上传密钥签名 |
| `six-tick-ios-release-unsigned` | ZIP 内含真机架构的未签名 `Runner.app`；不是可直接安装的 IPA，需 Apple 证书及描述文件签名 |
| `six-tick-macos-release-unsigned` | ZIP 内含 macOS 12+ 的 Intel / Apple Silicon 通用 `Six Tick.app`；未签名，正式分发需签名与公证 |
| `six-tick-windows-x64-release` | ZIP 内含 EXE、DLL 和 data；完整解压后运行，不要只复制 EXE |

Apple 的 ZIP 使用 `ditto` 保留应用包中的权限与符号链接。
Windows 使用 Windows Server 2022 runner 的 Visual Studio 工具链构建 x64 应用。
iOS 使用 macOS 14 runner；macOS 使用 `macos-15-intel` runner。
macOS 上传前检查主程序及所有 Mach-O 动态库同时包含 `x86_64` / `arm64`，
检查应用和动态库的最低系统版本不高于 macOS 12，并在 Intel runner 上启动应用、确认主窗口出现。
该启动检查运行于 runner 的 macOS 15，不能替代 macOS 12.7.6 实机验收。
Android 使用 Java 17 和 runner 预装的 Android SDK。
当前流程无需仓库 Secrets，也不会创建 GitHub Release 或发布到应用商店。

### macOS 12 安装

2019 款 Intel MacBook Pro（macOS 12.7.6）应使用包含上述兼容性检查的新产物，
旧产物要求 macOS 14，重新解压旧 ZIP 不会改变最低版本。
解压 GitHub 下载的 Artifact 后，再解压其中的应用 ZIP，将 `Six Tick.app` 拖到“应用程序”。
当前包未经 Developer ID 签名及公证；若系统提示无法验证开发者，请在确认下载来源为本仓库后，
在 Finder 中按住 Control 点击应用、选择“打开”，或在“系统偏好设置 → 安全性与隐私 → 通用”中允许这一次打开。
若提示“已损坏”或仍无法启动，请保留完整错误文字进一步排查，不要关闭系统的 Gatekeeper。

## 首次启用

仓库必须包含 `client/`、`server/` 和工作流本身，不能只上传 YAML。
项目的 `.gitignore` 会排除本机缓存、生成目录及 Android 密钥。
若仓库禁止 Actions，需要在 **Settings → Actions → General** 中允许使用工作流引用的 Actions。

提交并推送后，在 Actions 页面检查 `Analyze and test` 以及四个平台构建任务的结果。
只有运行成功且五项 Artifacts 均存在，才能确认本次云端构建交付完成。
本地 YAML 校验、分析和单元测试不能替代原生平台的实际构建验证。

## 本地复现验证

```bash
python3 -m pip install -r server/requirements.txt
python3 -m unittest discover -s server/tests -v
cd client
flutter pub get --enforce-lockfile
flutter analyze
flutter test --dart-define=ALLOW_INSECURE_LOCALHOST=true --reporter expanded
```

打包步骤见工作流。Apple 构建需 macOS/Xcode/CocoaPods；Windows 构建需 Windows/Visual Studio。
