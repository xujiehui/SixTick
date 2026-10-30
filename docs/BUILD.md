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
| `six-tick-macos-release-unsigned` | ZIP 内含未签名的 `Six Tick.app`；正式运行验证和分发需签名，公证后分发 |
| `six-tick-windows-x64-release` | ZIP 内含 EXE、DLL 和 data；完整解压后运行，不要只复制 EXE |

Apple 的 ZIP 使用 `ditto` 保留应用包中的权限与符号链接。
Windows 使用 Windows Server 2022 runner 的 Visual Studio 工具链构建 x64 应用。
Apple 使用 macOS 14 runner。Android 使用 Java 17 和 runner 预装的 Android SDK。
当前流程无需仓库 Secrets，也不会创建 GitHub Release 或发布到应用商店。

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
