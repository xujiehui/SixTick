# Six Tick

面向 iOS、Android、Windows 和 macOS 的个人 TOTP 验证器。Flutter 客户端离线生成验证码；可选 Python/SQLite 服务只保存端到端加密数据。

> 当前为开发版本，不是已经签名、审计并上线的正式产品。功能、测试与剩余发布验证见 [交付与验收](docs/ACCEPTANCE.md)。

## 已实现

- RFC 6238：SHA-1 / SHA-256 / SHA-512、6 / 8 位、1–300 秒周期。
- 本地加密仓库、系统认证或独立密码、自动锁定与隐私遮罩。
- 手动密钥、标准 URI、二维码图片、多二维码选择、手机相机、桌面拖放。
- 搜索、收藏、单层分组、账号编辑删除、敏感操作重新认证、单条迁移二维码。
- 独立密码加密备份、导入预览、重复项处理和原子持久化。
- 邮箱验证码、恢复密钥、X25519 设备配对、设备授权与撤销。
- 加密增量同步、CAS 并发控制、幂等重试、字段冲突保留、永久删除标记。
- 恢复密钥轮换、同步关闭、退出、云账号注销及独立云仓库重建。
- 中英文、浅深色主题、手机与桌面布局、键盘搜索与取码、帮助内容。

## 项目结构

```text
client/              Flutter 应用及四端原生工程
  lib/core/          TOTP、加密、不可变变更 DAG
  lib/services/      本地存储、同步、设备配对、二维码识别
  lib/ui/            首次使用、取码、同步、安全与设置
  test/              标准向量、安全、存储、同步集成与界面测试
server/              Python 服务、SQLite、SMTP 与 HTTP 接口
  tests/             鉴权、设备、同步、注销与传输测试
docs/                需求、协议、安全模型、部署及验收记录
scripts/             验证和备份维护工具
.github/workflows/   测试与原生构建 CI
```

## 客户端开发

使用 Flutter **3.35.7 / Dart 3.9.2**，依赖锁定在 `client/pubspec.lock`。

```bash
cd client
flutter pub get
flutter run -d <device>
```

本地模式无需服务器。要预设同步服务地址：

```bash
flutter run -d <device> --dart-define=SYNC_URL=https://your-sync.example.com
```

默认只允许 HTTPS，不包含公共服务、默认账号或演示密钥。首次启动选择本机解锁方式，再添加你自己的账号。

| 平台 | 最低系统 | 构建条件 |
|---|---|---|
| iOS | 17 | macOS、Xcode、CocoaPods、Apple 签名配置 |
| Android | 10 / API 29 | Java 17、Android SDK，发布时配置签名 |
| Windows | 11 | Windows、Visual Studio C++ Desktop 工具链 |
| macOS | 14 | macOS、Xcode、CocoaPods；分发需签名与公证 |

```bash
flutter build apk --debug
flutter build appbundle --release
flutter build ios --release --no-codesign
flutter build macos --release
flutter build windows --release
```

Android 发布构建不会使用调试证书冒充正式签名。请在发布流水线注入自己的签名设置。

## 本机同步服务

Python 3.10+；安装 `server/requirements.txt` 的依赖。

```bash
python3 -m venv .venv
.venv/bin/python -m pip install -r server/requirements.txt
.venv/bin/python -m server.app --development
```

开发服务只绑定 `127.0.0.1:8080`，验证码写入权限为 `0600` 的 `.local/development-mail.json`，不向真实邮箱发送邮件。该模式不可对公网开放。

开发客户端可明确允许回环 HTTP：

```bash
cd client
flutter run --dart-define=ALLOW_INSECURE_LOCALHOST=true --dart-define=SYNC_URL=http://127.0.0.1:8080
```

Android 模拟器将地址改为 `http://10.0.2.2:8080`，仅调试清单允许明文通信。iOS/macOS 开发测试优先使用本机受信任 HTTPS，不提供全局 ATS 放行配置。

正式部署需要 SMTP、随机服务端 pepper、HTTPS 反向代理及备份生命周期配置，见 [部署指南](docs/DEPLOYMENT.md)。

## GitHub Actions 构建

推送到 `main` 后，`Build applications` 工作流会先运行分析与测试，再构建 Android、iOS、macOS 和 Windows 应用。也可在 Actions 页面手动触发。
构建产物在运行记录的 **Artifacts** 中下载，保留 14 天。Android 提供调试 APK 和未签名 Release AAB，Apple 提供未签名应用包，Windows 提供完整应用 ZIP。
使用方法与签名边界见 [构建指南](docs/BUILD.md)。

## 验证

从仓库根目录运行后端测试：

```bash
python3 -m unittest discover -s server/tests -v
```

运行客户端分析和全部测试（集成测试需要同机 Python 和 `cryptography`）：

```bash
cd client
flutter analyze
flutter test --dart-define=ALLOW_INSECURE_LOCALHOST=true --reporter expanded
```

集成测试启动临时回环服务，邮件只写入临时文件，不需要真实 SMTP。普通 `flutter test` 会跳过这一项联网集成测试，其余测试照常运行。

## 文档

- [产品需求与需求映射](docs/PRD.md)
- [架构、协议与加密设计](docs/ARCHITECTURE.md)
- [安全边界与评审清单](docs/SECURITY.md)
- [部署与运行手册](docs/DEPLOYMENT.md)
- [交付与验收状态](docs/ACCEPTANCE.md)
