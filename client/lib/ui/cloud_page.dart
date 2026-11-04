import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../core/crypto.dart';
import '../services/api.dart';
import '../services/cloud.dart';
import '../services/controller.dart';
import 'common.dart';
import 'design.dart';
import 'add_account.dart';
import 'security_page.dart';

class CloudPage extends StatefulWidget {
  final AppController app;
  const CloudPage({super.key, required this.app});
  @override
  State<CloudPage> createState() => _CloudPageState();
}

class _CloudPageState extends State<CloudPage> {
  List<Map<String, dynamic>> devices = [];
  bool busy = false;
  String? error;
  AppController get app => widget.app;
  String t(String zh, String en) => tr(app, zh, en);
  @override
  void initState() {
    super.initState();
    if (app.cloud != null) refresh();
  }

  Future<void> run(Future<void> Function() work) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await work();
    } catch (e) {
      if (mounted) setState(() => error = errorText(app, e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> refresh() async {
    try {
      final access = app.cloud;
      if (access == null) return;
      final result = await access.api.request('GET', '/v1/devices');
      if (mounted && !app.locked) {
        setState(
          () => devices = (result['devices'] as List)
              .cast<Map<String, dynamic>>(),
        );
      }
    } catch (e) {
      if (mounted) setState(() => error = errorText(app, e));
    }
  }

  Future<bool> freshEmail() async {
    if (!await reauthenticate(context, app) || !mounted) return false;
    final login = await showDialog<CloudLogin>(
      context: context,
      builder: (_) => CloudWizard(app: app, fresh: true),
    );
    if (login == null || app.locked) return false;
    await app.renewLogin(login);
    return true;
  }

  Future<void> enroll() async {
    if (!await reauthenticate(context, app) || !mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => CloudWizard(app: app),
    );
    if (app.cloud != null) await refresh();
  }

  Future<void> approve({bool scan = false}) async {
    if (!await reauthenticate(context, app) || !mounted) return;
    final String? code;
    if (scan) {
      code = await scanPairing(context, app);
    } else {
      code = await askText(
        context,
        t('授权新设备', 'Authorize a device'),
        t('粘贴新设备的完整配对码', 'Paste the full pairing code'),
        t('核对', 'Review'),
      );
    }
    if (code == null || app.locked) return;
    final info = await PairRequest.inspect(app.cloud!, code);
    if (!mounted || app.locked) return;
    if (!await confirm(
      context,
      t('核对两台设备', 'Compare both devices'),
      '${info['name']} · ${info['platform']}\n\n${t('核对码', 'Verification code')}: ${info['check']}\n\n${t('确认两端核对码一致，且新设备由你本人控制。请求 5 分钟后失效。', 'Confirm the codes match and you control the new device. Requests expire after 5 minutes.')}',
      t('一致，允许授权', 'Codes match — authorize'),
    )) {
      return;
    }
    if (app.locked) return;
    await PairRequest.approve(app.cloud!, code);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            t('已批准，请在新设备完成接入。', 'Approved. Complete setup on the new device.'),
          ),
        ),
      );
    }
  }

  Future<void> rotate() async {
    if (!await freshEmail() || !mounted) return;
    if (!await confirm(
          context,
          t('更换恢复密钥', 'Replace recovery key'),
          t(
            '其他设备下次连接需要重新授权。旧密钥不能恢复当前云仓库，但可能仍能解密此前取得的旧副本。',
            'Other devices will need authorization again. The old key cannot recover the current vault but may still decrypt previously obtained copies.',
          ),
          t('继续', 'Continue'),
        ) ||
        !mounted) {
      return;
    }
    final key = VaultCrypto.newRecoveryKey();
    if (!await confirmRecoveryKey(context, app, key) || app.locked) return;
    await app.rotateRecovery(key);
    await refresh();
  }

  Future<void> revoke(Map<String, dynamic> device) async {
    if (!await freshEmail() || !mounted) return;
    if (!await confirm(
          context,
          t('撤销设备', 'Revoke device'),
          t(
            '撤销后无法继续同步，但无法远程清除该设备已有密钥。设备失窃时，请到相关网站重置两步验证密钥。',
            'This stops sync but cannot erase secrets already on the device. If it was stolen, rotate two-step verification secrets on the websites.',
          ),
          t('撤销同步权限', 'Revoke access'),
          danger: true,
        ) ||
        app.locked) {
      return;
    }
    await app.cloud!.api.request('POST', '/v1/devices/revoke', {
      'deviceId': device['id'],
    });
    await refresh();
  }

  Future<void> signOut() async {
    if (!await reauthenticate(context, app) || !mounted) return;
    if (app.syncStatus != 'synced' &&
        !await confirm(
          context,
          t('可能有未同步的数据', 'Some changes may be unsynced'),
          t(
            '建议先同步或到“安全与备份”导出。移除本机数据后，未同步修改将丢失；保留本机副本可继续离线使用。',
            'Sync or export a backup first. Removing local data loses unsynced edits. Keeping a local copy preserves offline access.',
          ),
          t('继续选择', 'Continue'),
        )) {
      return;
    }
    if (!mounted) return;
    final keep = await showDialog<bool>(
      context: context,
      builder: (context) => AppDialog(
        title: Text(t('退出云账号', 'Sign out')),
        content: Text(
          t(
            '默认移除本机仓库。也可明确选择保留为独立本地副本，云数据不会被删除。',
            'The default removes the local vault. You can explicitly keep an independent local copy. Cloud data is not deleted.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(t('取消', 'Cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(t('保留本机副本并退出', 'Keep local copy')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(t('移除本机数据并退出', 'Remove local data')),
          ),
        ],
      ),
    );
    if (keep != null && !app.locked) {
      await app.detach(keepLocal: keep);
      if (mounted) setState(() => devices = []);
    }
  }

  Future<void> deleteCloud() async {
    if (!await freshEmail() || !mounted) return;
    final email = await askText(
      context,
      t('注销云账号', 'Delete cloud account'),
      t('输入登录邮箱以确认', 'Type your email to confirm'),
      t('下一步', 'Continue'),
      helper: t(
        '账号和云数据将删除，所有会话失效。本机保留为离线副本；无法保证擦除其他离线设备。',
        'The account, cloud data and sessions will be deleted. This device keeps a local copy. Other offline devices cannot be erased.',
      ),
    );
    if (email == null || !mounted || app.locked) return;
    if (!await confirm(
          context,
          t('最终确认注销', 'Confirm permanent deletion'),
          t(
            '此操作不可撤销。活跃云数据在 24 小时内删除，备份副本最长 30 天过期。',
            'This cannot be undone. Active cloud data is removed within 24 hours; backup copies expire within 30 days.',
          ),
          t('永久注销', 'Delete permanently'),
          danger: true,
        ) ||
        app.locked) {
      return;
    }
    await app.cloud!.api.request('POST', '/v1/account/delete', {
      'confirmation': email.trim().toLowerCase(),
    });
    await app.detach(keepLocal: true);
    if (mounted) setState(() => devices = []);
  }

  @override
  Widget build(BuildContext context) {
    final access = app.cloud;
    final status = switch (app.syncStatus) {
      'syncing' => t('同步中', 'Syncing'),
      'synced' => t('已同步', 'Up to date'),
      'pending' => t('等待同步', 'Changes pending'),
      'offline' => t('离线，稍后同步', 'Offline — sync pending'),
      'reauth' => t('需要重新登录或授权', 'Sign-in or authorization required'),
      'conflict' => t('同步繁忙，请重试', 'Concurrent updates — retry'),
      'error' => t('同步失败，本地仍可用', 'Sync failed — local codes still work'),
      _ => t('未开启', 'Disabled'),
    };
    return PageList(
      children: [
        PageHeading(
          title: t('同步与设备', 'Sync & devices'),
          subtitle: t(
            '你的设备相互连接，密钥始终由你掌握。',
            'Connect your devices. Keep your secrets yours.',
          ),
        ),
        StatusNotice(
          text: status,
          icon: app.syncStatus == 'synced'
              ? Icons.cloud_done_outlined
              : app.syncStatus == 'offline'
              ? Icons.cloud_off_outlined
              : Icons.sync_outlined,
          tone: ['error', 'reauth'].contains(app.syncStatus)
              ? NoticeTone.error
              : ['offline', 'conflict'].contains(app.syncStatus)
              ? NoticeTone.warning
              : app.syncStatus == 'synced'
              ? NoticeTone.success
              : NoticeTone.neutral,
        ),
        const SizedBox(height: 16),
        if (busy) const LinearProgressIndicator(),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: StatusNotice(
              text: error!,
              tone: NoticeTone.error,
              icon: Icons.error_outline,
            ),
          ),
        SectionCard(
          title: t('端到端加密同步', 'End-to-end encrypted sync'),
          subtitle: t(
            '服务器只保存密文。邮箱登录用于确认身份，解密还需要授权设备或恢复密钥。',
            'The server stores ciphertext. Email confirms your identity; decryption needs an authorized device or recovery key.',
          ),
          icon: Icons.cloud_done_outlined,
          children: [
            if (access == null)
              FilledButton.icon(
                onPressed: busy ? null : () => run(enroll),
                icon: const Icon(Icons.add_link),
                label: Text(
                  t('开启同步 / 恢复云仓库', 'Enable sync / restore cloud vault'),
                ),
              )
            else ...[
              Text(
                access.email,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              if (app.lastSync != null)
                Text(
                  '${t('最近同步', 'Last synced')}: ${app.lastSync!.toLocal().toString().substring(0, 19)}',
                ),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: Text(t('在此设备启用同步', 'Sync on this device')),
                value: access.enabled,
                onChanged: busy
                    ? null
                    : (value) => run(() => app.enableSync(value)),
              ),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  FilledButton.icon(
                    onPressed: busy || !access.enabled
                        ? null
                        : () => run(app.sync),
                    icon: const Icon(Icons.sync),
                    label: Text(t('立即同步', 'Sync now')),
                  ),
                  OutlinedButton(
                    onPressed: busy ? null : () => run(enroll),
                    child: Text(t('重新登录 / 恢复授权', 'Sign in / authorize again')),
                  ),
                ],
              ),
            ],
          ],
        ),
        if (access != null) ...[
          const SizedBox(height: 12),
          SectionCard(
            title: t('已授权设备', 'Authorized devices'),
            subtitle: t(
              '撤销设备无法使其已获得的 TOTP 密钥失效。',
              'Revocation cannot invalidate TOTP secrets a device already has.',
            ),
            icon: Icons.devices_outlined,
            children: [
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: busy ? null : () => run(approve),
                    icon: const Icon(Icons.phonelink_lock),
                    label: Text(t('授权新设备', 'Authorize a device')),
                  ),
                  if (Platform.isAndroid || Platform.isIOS)
                    OutlinedButton.icon(
                      onPressed: busy
                          ? null
                          : () => run(() => approve(scan: true)),
                      icon: const Icon(Icons.qr_code_scanner),
                      label: Text(t('扫码授权', 'Scan to authorize')),
                    ),
                  TextButton.icon(
                    onPressed: busy ? null : refresh,
                    icon: const Icon(Icons.refresh),
                    label: Text(t('刷新', 'Refresh')),
                  ),
                ],
              ),
              ...devices.map(
                (d) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    d['revoked'] == true ? Icons.block : Icons.devices,
                  ),
                  title: Text(
                    '${d['name']}${d['current'] == true ? t('（当前）', ' (this device)') : ''}',
                  ),
                  subtitle: Text(
                    '${d['platform']} · ${d['revoked'] == true ? t('已撤销', 'Revoked') : t('已授权', 'Authorized')}\n'
                    '${t('首次授权', 'Authorized')}: ${DateTime.fromMillisecondsSinceEpoch(((d['createdAt'] as num) * 1000).toInt()).toLocal().toString().substring(0, 16)}\n'
                    '${t('最近连接', 'Last seen')}: ${DateTime.fromMillisecondsSinceEpoch(((d['lastSeen'] as num) * 1000).toInt()).toLocal().toString().substring(0, 16)}',
                  ),
                  trailing: PopupMenuButton<String>(
                    onSelected: (action) => run(() async {
                      if (action == 'revoke') {
                        await revoke(d);
                      } else {
                        final name = await askText(
                          context,
                          t('重命名设备', 'Rename device'),
                          t('名称', 'Name'),
                          t('保存', 'Save'),
                          initial: d['name'] as String,
                        );
                        if (name != null && !app.locked) {
                          await app.cloud!.api.request(
                            'POST',
                            '/v1/devices/rename',
                            {'deviceId': d['id'], 'name': name},
                          );
                          await refresh();
                        }
                      }
                    }),
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: 'rename',
                        child: Text(t('重命名', 'Rename')),
                      ),
                      if (d['current'] != true && d['revoked'] != true)
                        PopupMenuItem(
                          value: 'revoke',
                          child: Text(t('撤销', 'Revoke')),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: t('恢复与账号管理', 'Recovery & account'),
            subtitle: t(
              '恢复密钥不能由平台找回。更换前请确保当前仓库可以正常解锁。',
              'The service cannot retrieve a recovery key. Make sure this device can unlock the vault before replacing it.',
            ),
            icon: Icons.key_outlined,
            children: [
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  OutlinedButton(
                    onPressed: busy ? null : () => run(rotate),
                    child: Text(t('更换恢复密钥', 'Replace recovery key')),
                  ),
                  OutlinedButton(
                    onPressed: busy ? null : () => run(signOut),
                    child: Text(t('退出账号', 'Sign out')),
                  ),
                  TextButton(
                    style: TextButton.styleFrom(
                      foregroundColor: Theme.of(context).colorScheme.error,
                    ),
                    onPressed: busy ? null : () => run(deleteCloud),
                    child: Text(t('注销云账号', 'Delete cloud account')),
                  ),
                ],
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class CloudWizard extends StatefulWidget {
  final AppController app;
  final bool fresh;
  const CloudWizard({super.key, required this.app, this.fresh = false});
  @override
  State<CloudWizard> createState() => _CloudWizardState();
}

class _CloudWizardState extends State<CloudWizard> {
  final url = TextEditingController(),
      email = TextEditingController(),
      code = TextEditingController(),
      recovery = TextEditingController();
  CloudLogin? login;
  PairRequest? pairing;
  bool sent = false, busy = false;
  String? error;
  DateTime? sentAt;
  AppController get app => widget.app;
  String t(String zh, String en) => tr(app, zh, en);
  @override
  void initState() {
    super.initState();
    url.text = app.cloud?.url ?? const String.fromEnvironment('SYNC_URL');
    email.text = app.cloud?.email ?? '';
  }

  @override
  void dispose() {
    for (final c in [url, email, code, recovery]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> run(Future<void> Function() work) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await work();
    } catch (e) {
      if (mounted) setState(() => error = errorText(app, e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> send() async {
    if (sentAt != null && DateTime.now().difference(sentAt!).inSeconds < 60) {
      throw const ApiException('rate_limited', 429);
    }
    await Api(
      url.text.trim(),
    ).request('POST', '/v1/auth/request', {'email': email.text.trim()});
    if (mounted) {
      setState(() {
        sent = true;
        sentAt = DateTime.now();
      });
    }
  }

  Future<void> verify() async {
    final next = await CloudLogin.verify(
      url.text.trim(),
      email.text.trim(),
      code.text.trim(),
      app.deviceId,
    );
    if (!mounted || app.locked) return;
    if (widget.fresh) {
      Navigator.pop(context, next);
      return;
    }
    setState(() => login = next);
    if (next.vault == null) {
      await create();
    } else if (app.cloud != null &&
        app.cloud!.accountId == next.accountId &&
        app.cloud!.epoch == next.vault!['epoch']) {
      await accept(
        await next.authorize(app.cloud!.keys, app.deviceName, app.platform),
      );
    }
  }

  Future<void> create() async {
    final keys = CloudKeys.generate(), recovery = VaultCrypto.newRecoveryKey();
    if (!await confirmRecoveryKey(context, app, recovery) || app.locked) return;
    await app.createCloud(login!, keys, recovery);
    if (mounted) Navigator.pop(context);
  }

  Future<void> accept(CloudAccess access) async {
    final remote = await app.previewCloud(access);
    if (!mounted || app.locked) return;
    final local = app.document!;
    final duplicates = remote.entries
        .where((e) => local.containsOtp(e.otp))
        .length;
    if (!await confirm(
          context,
          t('确认合并云端数据', 'Confirm cloud merge'),
          t(
            '本机 ${local.entries.length} 个账号，云端 ${remote.entries.length} 个账号，疑似重复 $duplicates 个。独立创建的重复账号将保留，合并前本机数据不会被删除。',
            '${local.entries.length} local accounts, ${remote.entries.length} cloud accounts, $duplicates possible duplicates. Independently created duplicates are preserved. Local data stays until the merge succeeds.',
          ),
          t('解锁并合并', 'Unlock & merge'),
        ) ||
        app.locked) {
      return;
    }
    await app.connect(access, remote);
    if (pairing != null) {
      try {
        await pairing!.consume();
      } catch (_) {
        /* The authorized session is already durably stored. */
      }
    }
    if (mounted) Navigator.pop(context);
  }

  Future<void> receive() async {
    final keys = await pairing!.receive();
    if (keys == null) {
      if (mounted) {
        setState(
          () => error = t(
            '等待已有设备确认，请稍后检查。',
            'Waiting for the existing device. Check again shortly.',
          ),
        );
      }
      return;
    }
    await accept(await login!.authorize(keys, app.deviceName, app.platform));
  }

  Future<void> reset() async {
    if (!await confirm(
          context,
          t('无法恢复原云仓库？', 'Cannot recover the old vault?'),
          t(
            '此操作永久删除无法解密的原云仓库，并撤销其他设备。本机已有数据不受影响。之后可重新开启同步。',
            'This permanently deletes the inaccessible cloud vault and revokes other devices. Local data stays. You can then enable sync again.',
          ),
          t('继续验证邮箱', 'Continue to email confirmation'),
          danger: true,
        ) ||
        !mounted) {
      return;
    }
    final confirmation = await askText(
      context,
      t('输入登录邮箱确认重建', 'Confirm reset with your email'),
      t('登录邮箱', 'Email'),
      t('删除旧云仓库', 'Delete old cloud vault'),
    );
    if (confirmation == null || app.locked) return;
    await login!.api.request('POST', '/v1/vault/reset', {
      'confirmation': confirmation.trim().toLowerCase(),
      'epoch': login!.vault!['epoch'],
      'revision': login!.vault!['revision'],
    });
    final l = login!;
    setState(() {
      pairing = null;
      login = CloudLogin(
        l.url,
        l.email,
        l.token,
        l.accountId,
        l.challenge,
        l.deviceId,
        null,
      );
    });
    // A destructive reset never silently replaces the user's local vault or auto-uploads it.
  }

  @override
  Widget build(BuildContext context) => AppDialog(
    title: Text(
      t(
        widget.fresh ? '重新验证邮箱' : '连接你的设备',
        widget.fresh ? 'Verify email again' : 'Connect your devices',
      ),
    ),
    content: SizedBox(
      width: 480,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FlowStep(
              label: login == null
                  ? t('验证邮箱', 'Verify email')
                  : t('解锁加密仓库', 'Unlock your vault'),
              current: login == null ? 1 : 2,
              total: 2,
            ),
            if (busy) const LinearProgressIndicator(),
            if (login == null) ...[
              Text(
                t(
                  '邮箱验证不代表能够解密。现有云仓库还需要授权设备或恢复密钥。请保留邮箱本身的备用登录方式。',
                  'Email verification cannot decrypt a vault. Existing vaults also require an authorized device or recovery key. Keep a backup sign-in method for your email.',
                ),
              ),
              const SizedBox(height: 18),
              TextField(
                controller: url,
                enabled: !sent && !widget.fresh,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: t('可信同步服务器地址', 'Trusted sync server URL'),
                  hintText: 'https://…',
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: email,
                enabled: !sent && !widget.fresh,
                keyboardType: TextInputType.emailAddress,
                autocorrect: false,
                decoration: InputDecoration(labelText: t('登录邮箱', 'Email')),
              ),
              const SizedBox(height: 16),
              OutlinedButton(
                onPressed: busy ? null : () => run(send),
                child: Text(
                  t(
                    sent ? '重新发送（间隔 60 秒）' : '发送验证码',
                    sent ? 'Resend (60s cooldown)' : 'Send code',
                  ),
                ),
              ),
              if (sent) ...[
                const SizedBox(height: 16),
                TextField(
                  controller: code,
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  decoration: InputDecoration(
                    labelText: t('6 位邮箱验证码', '6-digit email code'),
                  ),
                ),
                FilledButton(
                  onPressed: busy ? null : () => run(verify),
                  child: Text(t('验证邮箱', 'Verify email')),
                ),
              ],
            ] else if (login!.vault == null) ...[
              Text(
                t(
                  '云仓库尚未创建。保存恢复密钥后才会上传本机账号的加密副本。',
                  'No cloud vault exists. An encrypted copy of your local accounts is uploaded only after saving a recovery key.',
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: busy ? null : () => run(create),
                child: Text(t('创建云仓库', 'Create cloud vault')),
              ),
            ] else ...[
              Text(
                t(
                  '已找到加密仓库。选择一种解锁方式。',
                  'Encrypted vault found. Choose how to unlock it.',
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: recovery,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: t('恢复密钥', 'Recovery key'),
                ),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: busy
                    ? null
                    : () => run(
                        () async => accept(
                          await login!.recover(
                            recovery.text,
                            app.deviceName,
                            app.platform,
                          ),
                        ),
                      ),
                child: Text(t('使用恢复密钥解锁', 'Unlock with recovery key')),
              ),
              const SizedBox(height: 16),
              OutlinedButton(
                onPressed: busy
                    ? null
                    : () => run(() async {
                        final p = await PairRequest.create(
                          login!,
                          app.deviceName,
                          app.platform,
                        );
                        if (mounted) setState(() => pairing = p);
                      }),
                child: Text(t('由已有设备授权', 'Authorize from an existing device')),
              ),
              if (pairing != null) ...[
                const SizedBox(height: 16),
                Center(
                  child: ColoredBox(
                    color: Colors.white,
                    child: QrImageView(
                      data: pairing!.code,
                      size: 220,
                      backgroundColor: Colors.white,
                    ),
                  ),
                ),
                Text(
                  '${t('核对码', 'Verification code')}: ${pairing!.check}',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 10),
                SelectableText(
                  pairing!.code,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
                TextButton(
                  onPressed: () => copySensitive(pairing!.code),
                  child: Text(t('复制配对码', 'Copy pairing code')),
                ),
                Text(
                  t(
                    '在已授权设备的“授权新设备”中输入配对码，并核对两端显示。5 分钟内有效。',
                    'Enter this code under “Authorize a device” on your existing device. Compare both codes. Valid for 5 minutes.',
                  ),
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: busy ? null : () => run(receive),
                  child: Text(t('检查授权结果', 'Check approval')),
                ),
              ],
              TextButton(
                onPressed: busy ? null : () => run(reset),
                child: Text(t('已失去全部恢复方式？', 'Lost every recovery method?')),
              ),
            ],
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: StatusNotice(
                  text: error!,
                  tone: NoticeTone.error,
                  icon: Icons.error_outline,
                ),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: busy ? null : () => Navigator.pop(context),
        child: Text(t('关闭', 'Close')),
      ),
    ],
  );
}
