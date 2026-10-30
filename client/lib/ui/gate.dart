import 'package:flutter/material.dart';
import '../services/controller.dart';
import 'common.dart';

class GateScreen extends StatefulWidget {
  final AppController app;
  final ValueChanged<int> onRestore;
  const GateScreen({super.key, required this.app, required this.onRestore});
  @override
  State<GateScreen> createState() => _GateScreenState();
}

class _GateScreenState extends State<GateScreen> {
  final password = TextEditingController(), repeat = TextEditingController();
  bool configuring = false,
      busy = false,
      systemAvailable = false,
      useSystem = false;
  String? method, error;
  int failures = 0;
  DateTime? retryAt;
  AppController get app => widget.app;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final supported = await app.store.systemAvailable();
      final saved = app.exists ? await app.store.unlockMethod() : null;
      if (mounted) {
        setState(() {
          systemAvailable = supported;
          useSystem = supported;
          method = saved;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = errorText(app, e));
    }
  }

  Future<void> submit() async {
    if (retryAt != null && DateTime.now().isBefore(retryAt!)) {
      setState(
        () => error = tr(app, '请稍等片刻再试。', 'Please wait before trying again.'),
      );
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (app.exists) {
        await app.unlock(password: method == 'password' ? password.text : null);
      } else {
        if (!useSystem && password.text != repeat.text) {
          setState(
            () => error = tr(app, '两次输入的密码不一致。', 'The passwords do not match.'),
          );
          return;
        }
        await app.create(password: useSystem ? null : password.text);
      }
    } catch (e) {
      failures++;
      if (failures >= 5) {
        retryAt = DateTime.now().add(const Duration(seconds: 30));
      }
      if (mounted) setState(() => error = errorText(app, e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void setup(int page) {
    widget.onRestore(page);
    setState(() => configuring = true);
  }

  @override
  void dispose() {
    password.dispose();
    repeat.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 78,
                      height: 78,
                      decoration: BoxDecoration(
                        color: cs.primary,
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: Icon(
                        Icons.shield_outlined,
                        size: 42,
                        color: cs.onPrimary,
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'Six Tick',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineLarge,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    tr(
                      app,
                      '每一次登录，都安心。',
                      'A little peace of mind. Every sign-in.',
                    ),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 36),
                  if (!app.exists && !configuring) ...[
                    Text(
                      tr(
                        app,
                        '你的验证码，始终由你掌握。离线即可使用，无需创建账号。',
                        'Your codes, in your hands. Works offline. No account required.',
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    FilledButton.icon(
                      onPressed: () => setup(0),
                      icon: const Icon(Icons.arrow_forward),
                      label: Text(tr(app, '开始使用', 'Get started')),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: () => setup(2),
                      icon: const Icon(Icons.restore),
                      label: Text(
                        tr(app, '从加密备份恢复', 'Restore an encrypted backup'),
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: () => setup(1),
                      child: Text(tr(app, '恢复云端仓库', 'Restore a cloud vault')),
                    ),
                  ] else ...[
                    Text(
                      app.exists
                          ? tr(app, '解锁你的验证器', 'Unlock your authenticator')
                          : tr(app, '先保护这台设备', 'Secure this device first'),
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 16),
                    if (!app.exists)
                      Text(
                        tr(
                          app,
                          '本机解锁方式仅保护这台设备。恢复密钥与备份密码需单独保管。',
                          'This unlock method protects this device. Recovery keys and backup passwords are separate.',
                        ),
                      ),
                    if (!app.exists && systemAvailable)
                      SwitchListTile.adaptive(
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          tr(app, '使用系统认证', 'Use device authentication'),
                        ),
                        value: useSystem,
                        onChanged: busy
                            ? null
                            : (value) => setState(() => useSystem = value),
                      ),
                    if (app.exists ? method == 'password' : !useSystem) ...[
                      const SizedBox(height: 16),
                      TextField(
                        controller: password,
                        obscureText: true,
                        autocorrect: false,
                        enableSuggestions: false,
                        onSubmitted: (_) => submit(),
                        decoration: InputDecoration(
                          labelText: tr(app, '本机解锁密码', 'Local unlock password'),
                          helperText: app.exists
                              ? null
                              : tr(app, '至少 12 个字符', 'At least 12 characters'),
                        ),
                      ),
                      if (!app.exists) ...[
                        const SizedBox(height: 16),
                        TextField(
                          controller: repeat,
                          obscureText: true,
                          autocorrect: false,
                          enableSuggestions: false,
                          onSubmitted: (_) => submit(),
                          decoration: InputDecoration(
                            labelText: tr(app, '再次输入密码', 'Repeat password'),
                          ),
                        ),
                      ],
                    ],
                    const SizedBox(height: 24),
                    FilledButton.icon(
                      onPressed: busy || app.exists && method == null
                          ? null
                          : submit,
                      icon: busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.lock_open),
                      label: Text(
                        app.exists
                            ? tr(app, '解锁', 'Unlock')
                            : tr(app, '创建本地仓库', 'Create local vault'),
                      ),
                    ),
                    if (!app.exists)
                      TextButton(
                        onPressed: busy
                            ? null
                            : () => setState(() => configuring = false),
                        child: Text(tr(app, '返回', 'Back')),
                      ),
                  ],
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: Text(error!, style: TextStyle(color: cs.error)),
                    ),
                  const SizedBox(height: 32),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.wifi_off, size: 15),
                      const SizedBox(width: 8),
                      Text(
                        tr(
                          app,
                          '离线优先 · 本地加密 · 无广告',
                          'Offline first · Encrypted · No ads',
                        ),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                  TextButton(
                    onPressed: () => setState(
                      () => app.settings['language'] =
                          app.settings['language'] == 'en' ? 'zh' : 'en',
                    ),
                    child: const Text('中文 / English'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
