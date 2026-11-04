import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import '../core/crypto.dart';
import '../core/document.dart';
import '../core/totp.dart';
import '../services/controller.dart';
import 'common.dart';
import 'design.dart';

Future<void> copySensitive(String value) async {
  if (Platform.isIOS || Platform.isAndroid) {
    await const MethodChannel(
      'six_tick/privacy',
    ).invokeMethod('copyCode', {'code': value, 'clear': true});
  } else {
    await Clipboard.setData(ClipboardData(text: value));
    Timer(const Duration(seconds: 30), () async {
      try {
        if ((await Clipboard.getData(Clipboard.kTextPlain))?.text == value) {
          await Clipboard.setData(const ClipboardData(text: ''));
        }
      } catch (_) {
        /* Clipboard access is best effort on desktop. */
      }
    });
  }
}

Future<bool> confirmRecoveryKey(
  BuildContext context,
  AppController app,
  String recovery,
) async =>
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _RecoveryDialog(app: app, recovery: recovery),
    ) ??
    false;

class _RecoveryDialog extends StatefulWidget {
  final AppController app;
  final String recovery;
  const _RecoveryDialog({required this.app, required this.recovery});
  @override
  State<_RecoveryDialog> createState() => _RecoveryDialogState();
}

class _RecoveryDialogState extends State<_RecoveryDialog> {
  bool check = false;
  final answer = TextEditingController();
  @override
  void dispose() {
    answer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    return AppDialog(
      title: Text(
        tr(
          app,
          check ? '确认已保存' : '保存恢复密钥',
          check ? 'Confirm your copy' : 'Save your recovery key',
        ),
      ),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FlowStep(
                label: tr(
                  app,
                  check ? '核对恢复密钥' : '保存恢复密钥',
                  check ? 'Verify your copy' : 'Save your recovery key',
                ),
                current: check ? 2 : 1,
                total: 2,
              ),
              Text(
                tr(
                  app,
                  '恢复密钥和所有授权设备同时丢失时，平台无法找回数据。请将密钥保存在独立、安全的位置，不要发送给任何人。',
                  'If you lose this key and every authorized device, no one can recover your vault. Keep it somewhere separate and safe. Never send it to anyone.',
                ),
              ),
              const SizedBox(height: 24),
              if (!check) ...[
                SelectableText(
                  widget.recovery,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 20,
                    height: 1.6,
                  ),
                ),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: () async {
                    try {
                      await copySensitive(widget.recovery);
                    } catch (e) {
                      if (context.mounted) showError(context, app, e);
                    }
                  },
                  icon: const Icon(Icons.copy),
                  label: Text(
                    tr(
                      app,
                      '复制（30 秒后尝试清除）',
                      'Copy (attempt to clear after 30s)',
                    ),
                  ),
                ),
              ],
              if (check)
                TextField(
                  controller: answer,
                  autofocus: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    labelText: tr(
                      app,
                      '请输入第 3 组字符',
                      'Enter the third group of characters',
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(tr(app, '取消', 'Cancel')),
        ),
        if (!check)
          FilledButton(
            onPressed: () => setState(() => check = true),
            child: Text(tr(app, '我已安全保存', 'I saved it safely')),
          )
        else
          FilledButton(
            onPressed:
                answer.text.trim().toUpperCase() ==
                    widget.recovery.split('-')[2]
                ? () => Navigator.pop(context, true)
                : null,
            child: Text(tr(app, '确认', 'Confirm')),
          ),
      ],
    );
  }
}

class SecurityPage extends StatefulWidget {
  final AppController app;
  const SecurityPage({super.key, required this.app});
  @override
  State<SecurityPage> createState() => _SecurityPageState();
}

class _SecurityPageState extends State<SecurityPage> {
  bool busy = false;
  bool biometricAvailable = false;
  AppController get app => widget.app;
  String t(String zh, String en) => tr(app, zh, en);
  @override
  void initState() {
    super.initState();
    app.store.biometricAvailable().then((available) {
      if (mounted) setState(() => biometricAvailable = available);
    });
  }

  Future<void> changeBiometricUnlock(bool enabled) async {
    final password = await askText(
      context,
      enabled
          ? t('启用 Touch ID', 'Enable Touch ID')
          : t('关闭 Touch ID', 'Disable Touch ID'),
      t('本机解锁密码', 'Local unlock password'),
      t('继续', 'Continue'),
      secret: true,
      helper: t(
        '验证现有密码。启用后仍可使用此密码解锁。',
        'Verify your existing password. It remains available after enabling Touch ID.',
      ),
    );
    if (password == null || !mounted || app.locked) return;
    await app.setBiometricUnlock(enabled, password);
  }

  Future<void> run(Future<void> Function() work) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await work();
    } catch (e) {
      if (mounted) showError(context, app, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> export() async {
    if (!await reauthenticate(context, app) || !mounted) return;
    final password = await askText(
      context,
      t('加密备份', 'Encrypt backup'),
      t('独立备份密码', 'Separate backup password'),
      t('下一步', 'Continue'),
      secret: true,
      helper: t(
        '至少 12 个字符。丢失后无法找回，登录邮箱和恢复密钥不能替代它。',
        'At least 12 characters. Your email and recovery key cannot replace this password.',
      ),
    );
    if (password == null || !mounted || app.locked) return;
    VaultCrypto.validatePassword(password);
    final repeat = await askText(
      context,
      t('再次输入备份密码', 'Repeat backup password'),
      t('备份密码', 'Backup password'),
      t('导出', 'Export'),
      secret: true,
    );
    if (repeat == null || !mounted || app.locked) return;
    if (password != repeat) throw const FormatException('decryption_failed');
    final data = await VaultCrypto.passwordSeal(
      app.document!.backup(),
      password,
      'backup',
    );
    if (!mounted || app.locked) return;
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(data)));
    final name =
        'six-tick-${DateTime.now().toIso8601String().substring(0, 10)}.sixtick';
    if (Platform.isAndroid || Platform.isIOS) {
      final box = context.findRenderObject() as RenderBox?;
      await SharePlus.instance.share(
        ShareParams(
          files: [
            XFile.fromData(
              bytes,
              mimeType: 'application/octet-stream',
              name: name,
            ),
          ],
          fileNameOverrides: [name],
          sharePositionOrigin: box == null
              ? null
              : box.localToGlobal(Offset.zero) & box.size,
        ),
      );
    } else {
      final location = await getSaveLocation(
        suggestedName: name,
        acceptedTypeGroups: [
          const XTypeGroup(label: 'Six Tick backup', extensions: ['sixtick']),
        ],
      );
      if (location == null) return;
      await XFile.fromData(bytes).saveTo(location.path);
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            t(
              '加密备份已交付，请确认保存位置。',
              'Encrypted backup handed off. Check where it was saved.',
            ),
          ),
        ),
      );
    }
  }

  Future<void> restore() async {
    if (!await reauthenticate(context, app) || !mounted) return;
    final file = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(
          label: 'Six Tick backup',
          extensions: ['sixtick'],
          uniformTypeIdentifiers: ['public.data'],
        ),
      ],
    );
    if (file == null || !mounted || app.locked) return;
    if (await file.length() > 32 * 1024 * 1024) {
      throw const FormatException('file_too_large');
    }
    if (!mounted) return;
    final password = await askText(
      context,
      t('恢复加密备份', 'Restore encrypted backup'),
      t('备份密码', 'Backup password'),
      t('解密并预览', 'Decrypt & preview'),
      secret: true,
    );
    if (password == null || app.locked) return;
    final data = await VaultCrypto.passwordOpen(
      jsonDecode(await file.readAsString()) as Map<String, dynamic>,
      password,
      'backup',
    );
    VaultDocument.validateBackup(data);
    if (!mounted || app.locked) return;
    final entries = data['entries'] as List;
    final existing = app.document!.entries
        .map((e) => e.otp.fingerprint)
        .toSet();
    var duplicates = 0;
    for (final e in entries) {
      if (!existing.add(
        OtpAccount.fromJson(Map<String, dynamic>.from(e as Map)).fingerprint,
      )) {
        duplicates++;
      }
    }
    final keep = await showDialog<bool>(
      context: context,
      builder: (context) => AppDialog(
        title: Text(t('确认合并导入', 'Confirm import')),
        content: Text(
          t(
            '有效账号 ${entries.length} 个，疑似重复 $duplicates 个，无效 0 个。导入不会覆盖整个仓库，也不会自动开启同步。',
            '${entries.length} valid accounts, $duplicates possible duplicates, 0 invalid. This will merge into your vault without enabling sync.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(t('取消', 'Cancel')),
          ),
          if (duplicates > 0)
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(t('保留重复账号', 'Keep duplicates')),
            ),
          FilledButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(t('导入并跳过重复', 'Import, skip duplicates')),
          ),
        ],
      ),
    );
    if (keep == null || app.locked) return;
    await app.importBackup(data, keep);
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(t('恢复完成', 'Restore complete'))));
    }
  }

  @override
  Widget build(BuildContext context) => PageList(
    children: [
      PageHeading(
        title: t('安全与备份', 'Security & backup'),
        subtitle: t(
          '为设备丢失、换机和意外做好准备。',
          'Be ready for a new device, a lost phone, or the unexpected.',
        ),
      ),
      if (busy) const LinearProgressIndicator(),
      SectionCard(
        title: t('应用锁', 'App lock'),
        subtitle: app.store.usesSystem
            ? t('使用设备系统认证保护本机仓库。', 'Protected with device authentication.')
            : t('使用独立的本机密码保护仓库。', 'Protected with your local unlock password.'),
        icon: Icons.lock_outline,
        children: [
          if (!app.store.usesSystem &&
              (biometricAvailable || app.store.biometricEnabled)) ...[
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.fingerprint),
              title: Text(t('使用 Touch ID 解锁', 'Unlock with Touch ID')),
              subtitle: Text(
                t(
                  '使用这台 Mac 的指纹解锁，保留本机密码作为备用。指纹更改后需重新启用。',
                  'Unlock with this Mac’s fingerprints and keep your local password as a fallback. Enable again after fingerprint changes.',
                ),
              ),
              value: app.store.biometricEnabled,
              onChanged: busy
                  ? null
                  : (value) => run(() => changeBiometricUnlock(value)),
            ),
            const SizedBox(height: 16),
          ],
          DropdownButtonFormField<int>(
            isExpanded: true,
            initialValue: app.settings['lockSeconds'] as int,
            decoration: InputDecoration(
              labelText: t('进入后台后的自动锁定时间', 'Auto-lock after backgrounding'),
            ),
            items: [
              DropdownMenuItem(value: 0, child: Text(t('立即', 'Immediately'))),
              DropdownMenuItem(value: 30, child: Text(t('30 秒', '30 seconds'))),
              DropdownMenuItem(value: 60, child: Text(t('1 分钟', '1 minute'))),
              DropdownMenuItem(value: 300, child: Text(t('5 分钟', '5 minutes'))),
            ],
            onChanged: (v) => run(() => app.preferences({'lockSeconds': v})),
          ),
          const SizedBox(height: 12),
          Text(
            t(
              '闲置时也会自动锁定；选择“立即”时，闲置锁定为 1 分钟。系统锁屏会立即锁定。',
              'Idle sessions also lock; “Immediately” uses a 1-minute idle timeout. System lock locks the app immediately.',
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: app.lock,
            icon: const Icon(Icons.lock),
            label: Text(t('立即锁定', 'Lock now')),
          ),
        ],
      ),
      const SizedBox(height: 12),
      SectionCard(
        title: t('加密备份', 'Encrypted backups'),
        subtitle: t(
          '备份密码独立于本机密码和云恢复密钥。备份包含账号、分组和收藏，不包含登录会话。',
          'A backup has its own password. It contains accounts, groups and favorites, never sign-in sessions.',
        ),
        icon: Icons.inventory_2_outlined,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              FilledButton.icon(
                onPressed: busy ? null : () => run(export),
                icon: const Icon(Icons.file_download_outlined),
                label: Text(t('导出加密备份', 'Export encrypted backup')),
              ),
              OutlinedButton.icon(
                onPressed: busy ? null : () => run(restore),
                icon: const Icon(Icons.restore),
                label: Text(t('恢复备份', 'Restore backup')),
              ),
            ],
          ),
        ],
      ),
      const SizedBox(height: 12),
      SectionCard(
        title: t('剪贴板保护', 'Clipboard protection'),
        subtitle: t(
          '不持续读取剪贴板。复制后仅在清理时检查内容，避免覆盖你后来复制的文字。',
          'No clipboard monitoring. Cleanup checks once to avoid overwriting anything you copied later.',
        ),
        icon: Icons.content_paste_outlined,
        children: [
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: Text(
              t('30 秒后尝试清除验证码', 'Try to clear codes after 30 seconds'),
            ),
            value: app.settings['clearClipboard'] == true,
            onChanged: (v) => run(() => app.preferences({'clearClipboard': v})),
          ),
          Text(
            t(
              '后台限制、其他应用和系统剪贴板历史可能影响清理；无法保证删除已被其他应用读取的内容。',
              'Background limits and clipboard history may prevent cleanup. Content already read by another app cannot be recalled.',
            ),
          ),
        ],
      ),
    ],
  );
}

class SettingsPage extends StatelessWidget {
  final AppController app;
  final VoidCallback onSecurity;
  const SettingsPage({super.key, required this.app, required this.onSecurity});
  String t(String zh, String en) => tr(app, zh, en);
  @override
  Widget build(BuildContext context) {
    Future<void> change(Map<String, dynamic> values) async {
      try {
        await app.preferences(values);
      } catch (e) {
        if (context.mounted) showError(context, app, e);
      }
    }

    final help = [
      [
        t('如何添加两步验证账号？', 'How do I add an account?'),
        t(
          '在目标网站开启“验证器应用”两步验证，扫描其二维码或输入密钥。先用生成的验证码完成网站验证，再保管好网站提供的备用恢复码。',
          'Enable authenticator-based verification on the website, then scan its QR code or enter its secret. Verify the code on the website and save its backup codes.',
        ),
      ],
      [
        t('验证码为什么无效？', 'Why is a code rejected?'),
        t(
          '检查是否选择了正确账号，开启设备“自动日期与时间”，等下一周期后再试。服务名称只是标签，修改它不能修复错误密钥。应用不会自行调整时间偏移。',
          'Check the account, enable automatic date and time, and try the next code. A service name is only a label. The app does not alter time offsets.',
        ),
      ],
      [
        t('四种凭据有什么区别？', 'What are the different credentials?'),
        t(
          '邮箱验证码用于确认云账号身份；本机认证用于解锁当前设备；恢复密钥用于找回云仓库；备份密码仅用于解密对应备份。它们不能互相替代。',
          'Email codes identify your cloud account. Device authentication unlocks this device. Recovery keys unlock your cloud vault. A backup password decrypts its backup. They are not interchangeable.',
        ),
      ],
      [
        t('如何更换手机或添加电脑？', 'How do I add or replace a device?'),
        t(
          '开启云同步后，在新设备登录相同邮箱，使用已有设备配对授权或恢复密钥解锁。也可以在本机导出加密备份，在新设备合并导入。',
          'Sign into the same email on the new device, then authorize it from an existing device or use the recovery key. Alternatively, export and import an encrypted backup.',
        ),
      ],
      [
        t('设备丢失后怎么办？', 'What if I lose a device?'),
        t(
          '使用另一台授权设备撤销丢失设备的同步权限。撤销无法保证擦除其本地密钥。请到相关网站重置两步验证密钥，并尽快启用设备远程锁定。',
          'Revoke its sync access from another authorized device. Revocation cannot erase keys already on that device. Rotate two-step verification secrets on the affected websites and use the device’s remote lock tools.',
        ),
      ],
      [
        t('什么时候无法恢复数据？', 'When is recovery impossible?'),
        t(
          '所有授权设备与恢复密钥同时丢失时，云数据无法恢复。备份密码丢失时，对应备份也无法恢复。邮箱登录成功并不代表能够解密。请保留邮箱服务自身的备用登录方式。',
          'Losing every authorized device and the recovery key makes cloud recovery impossible. Losing a backup password makes that backup unreadable. Email sign-in alone cannot decrypt data. Keep a backup sign-in method for your email account.',
        ),
      ],
      [
        t('如何迁移或退出？', 'How do I transfer or leave?'),
        t(
          '账号菜单可显示单条迁移二维码，需重新认证。安全与备份可导出完整加密备份。同步页面可关闭同步、退出或注销云账号；删除应用中的账号不会关闭网站的两步验证。',
          'The account menu exports one transfer QR after reauthentication. Security & backup exports the encrypted vault. The sync page lets you disable sync, sign out or delete your cloud account. Removing an account here does not disable verification on its website.',
        ),
      ],
      [
        t('平台可以看到哪些信息？', 'What can the service see?'),
        t(
          '云服务可见邮箱、设备注册信息、连接信息、密文大小及版本；无法读取账号密钥、服务名称、分组或验证码。本地模式不上传仓库。没有广告 SDK、产品分析和自动崩溃上传。',
          'The service sees email, device registration, connection metadata, ciphertext size and versions. It cannot read account secrets, service names, groups or codes. Local mode does not upload your vault. There are no ads, analytics or automatic crash uploads.',
        ),
      ],
    ];
    return PageList(
      children: [
        PageHeading(
          title: t('设置与帮助', 'Settings & help'),
          subtitle: t('让 Six Tick 更适合你。', 'Make Six Tick feel like yours.'),
        ),
        Card(
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 24,
              vertical: 8,
            ),
            leading: const Icon(Icons.shield_outlined),
            title: Text(t('安全与备份', 'Security & backup')),
            subtitle: Text(
              t(
                '应用锁、加密备份与剪贴板保护',
                'App lock, encrypted backups and clipboard protection',
              ),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: onSecurity,
          ),
        ),
        const SizedBox(height: 16),
        SectionCard(
          title: t('外观与语言', 'Appearance & language'),
          subtitle: t('设置只影响当前设备。', 'These preferences stay on this device.'),
          icon: Icons.tune,
          children: [
            DropdownButtonFormField<String>(
              isExpanded: true,
              initialValue: app.settings['theme'] as String,
              decoration: InputDecoration(labelText: t('主题', 'Theme')),
              items: [
                DropdownMenuItem(
                  value: 'system',
                  child: Text(t('跟随系统', 'System')),
                ),
                DropdownMenuItem(value: 'light', child: Text(t('浅色', 'Light'))),
                DropdownMenuItem(value: 'dark', child: Text(t('深色', 'Dark'))),
              ],
              onChanged: (v) => change({'theme': v}),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              isExpanded: true,
              initialValue: app.settings['language'] as String,
              decoration: InputDecoration(labelText: t('语言', 'Language')),
              items: const [
                DropdownMenuItem(value: 'zh', child: Text('简体中文')),
                DropdownMenuItem(value: 'en', child: Text('English')),
              ],
              onChanged: (v) => change({'language': v}),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Text(
          t('使用帮助', 'Help & guidance'),
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 12),
        ...help.map(
          (item) => Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Card(
              child: ExpansionTile(
                title: Text(item[0]),
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                children: [Text(item[1])],
              ),
            ),
          ),
        ),
        const SizedBox(height: 24),
        const BrandMark(size: 40),
        const SizedBox(height: 12),
        Text('Six Tick 1.0.0', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(
          t(
            '个人验证器 · RFC 6238 · 首版免费\n本构建需通过平台验收与独立安全评审后正式发布。',
            'Personal authenticator · RFC 6238 · Free v1\nPlatform acceptance and independent security review are required before release.',
          ),
        ),
      ],
    );
  }
}
