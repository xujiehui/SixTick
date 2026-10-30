import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../core/totp.dart';
import '../services/controller.dart';
import '../services/qr.dart';
import 'common.dart';

Future<void> importQr(
  BuildContext context,
  AppController app, {
  XFile? file,
}) async {
  try {
    file ??= await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(
          label: 'QR image',
          extensions: ['png', 'jpg', 'jpeg', 'webp'],
          uniformTypeIdentifiers: ['public.image'],
          mimeTypes: ['image/png', 'image/jpeg', 'image/webp'],
        ),
      ],
    );
    if (file == null) return;
    if (await file.length() > 12 * 1024 * 1024) {
      throw const FormatException('file_too_large');
    }
    final values = await readQrImage(await file.readAsBytes());
    if (context.mounted && !app.locked) await chooseQr(context, app, values);
  } catch (e) {
    if (context.mounted) showError(context, app, e);
  }
}

Future<void> chooseQr(
  BuildContext context,
  AppController app,
  List<String> values,
) async {
  final candidates = <OtpAccount>[];
  for (final value in values) {
    try {
      candidates.add(OtpAccount.fromUri(value));
    } catch (_) {
      /* Invalid QR links are never opened. */
    }
  }
  if (candidates.isEmpty) throw const FormatException('unsupported_uri');
  OtpAccount? selected;
  if (candidates.length == 1) {
    selected = candidates.first;
  } else {
    selected = await showDialog<OtpAccount>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(tr(app, '选择要添加的账号', 'Choose an account')),
        children: candidates
            .map(
              (otp) => SimpleDialogOption(
                onPressed: () => Navigator.pop(context, otp),
                child: ListTile(
                  title: Text(otp.issuer),
                  subtitle: Text(otp.account),
                ),
              ),
            )
            .toList(),
      ),
    );
  }
  if (selected != null && context.mounted && !app.locked) {
    await showDialog<void>(
      context: context,
      builder: (_) => AddAccountDialog(app: app, initial: selected),
    );
  }
}

class AddAccountDialog extends StatefulWidget {
  final AppController app;
  final OtpAccount? initial;
  const AddAccountDialog({super.key, required this.app, this.initial});
  @override
  State<AddAccountDialog> createState() => _AddAccountDialogState();
}

class _AddAccountDialogState extends State<AddAccountDialog> {
  final issuer = TextEditingController(),
      account = TextEditingController(),
      secret = TextEditingController(),
      uri = TextEditingController();
  final period = TextEditingController(text: '30');
  String algorithm = 'SHA1';
  int digits = 6;
  String? group, error;
  bool busy = false, reveal = false, advanced = false;
  AppController get app => widget.app;
  @override
  void initState() {
    super.initState();
    if (widget.initial != null) fill(widget.initial!);
  }

  void fill(OtpAccount otp) {
    issuer.text = otp.issuer;
    account.text = otp.account;
    secret.text = otp.secret;
    period.text = '${otp.period}';
    algorithm = otp.algorithm;
    digits = otp.digits;
    advanced = otp.algorithm != 'SHA1' || otp.digits != 6 || otp.period != 30;
  }

  Future<void> save() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final otp = OtpAccount(
        issuer: issuer.text,
        account: account.text.trim(),
        secret: secret.text,
        algorithm: algorithm,
        digits: digits,
        period: int.parse(period.text),
      );
      if (app.document!.containsOtp(otp)) {
        if (!await confirm(
          context,
          tr(app, '发现相同密钥', 'Duplicate secret'),
          tr(
            app,
            '已有使用相同密钥和参数的账号。仍要新增一条吗？',
            'An account already uses this secret and parameters. Add another copy?',
          ),
          tr(app, '仍然新增', 'Add another'),
        )) {
          return;
        }
      }
      await app.add(otp, group);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => error = errorText(app, e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    for (final c in [issuer, account, secret, uri, period]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      tr(
        app,
        widget.initial == null ? '添加账号' : '确认账号',
        widget.initial == null ? 'Add account' : 'Confirm account',
      ),
    ),
    content: SizedBox(
      width: 480,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.initial == null) ...[
              TextField(
                controller: uri,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: tr(
                    app,
                    '粘贴 otpauth:// 链接（可选）',
                    'Paste otpauth:// link (optional)',
                  ),
                  suffixIcon: IconButton(
                    tooltip: tr(app, '解析链接', 'Parse link'),
                    icon: const Icon(Icons.arrow_forward),
                    onPressed: () {
                      try {
                        final otp = OtpAccount.fromUri(uri.text);
                        setState(() {
                          fill(otp);
                          error = null;
                        });
                      } catch (e) {
                        setState(() => error = errorText(app, e));
                      }
                    },
                  ),
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Divider(),
              ),
            ],
            TextField(
              controller: issuer,
              decoration: InputDecoration(
                labelText: tr(app, '服务名称', 'Service name'),
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: account,
              decoration: InputDecoration(
                labelText: tr(app, '账号标识（可选）', 'Account label (optional)'),
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: secret,
              obscureText: !reveal,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: tr(app, '密钥（Base32）', 'Secret (Base32)'),
                suffixIcon: IconButton(
                  tooltip: tr(app, '显示 / 隐藏密钥', 'Show / hide secret'),
                  onPressed: () => setState(() => reveal = !reveal),
                  icon: Icon(reveal ? Icons.visibility_off : Icons.visibility),
                ),
              ),
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField<String>(
              initialValue: group,
              decoration: InputDecoration(labelText: tr(app, '分组', 'Group')),
              items: [
                DropdownMenuItem(
                  value: null,
                  child: Text(tr(app, '未分组', 'Ungrouped')),
                ),
                ...app.document!.groups.map(
                  (g) => DropdownMenuItem(
                    value: g.id,
                    child: Text(g.fields['name'] as String),
                  ),
                ),
              ],
              onChanged: (v) => setState(() => group = v),
            ),
            const SizedBox(height: 12),
            Text(
              '$algorithm · $digits ${tr(app, '位', 'digits')} · ${period.text}s',
            ),
            if (algorithm != 'SHA1' || digits != 6 || period.text != '30')
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  tr(
                    app,
                    '此账号使用自定义参数，请与网站提供的信息核对。',
                    'This account uses custom parameters. Check them against the website.',
                  ),
                ),
              ),
            ExpansionTile(
              title: Text(tr(app, '高级参数', 'Advanced parameters')),
              initiallyExpanded: advanced,
              tilePadding: EdgeInsets.zero,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: algorithm,
                        items: ['SHA1', 'SHA256', 'SHA512']
                            .map(
                              (a) => DropdownMenuItem(value: a, child: Text(a)),
                            )
                            .toList(),
                        onChanged: (v) => setState(() => algorithm = v!),
                        decoration: const InputDecoration(labelText: 'HMAC'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: DropdownButtonFormField<int>(
                        initialValue: digits,
                        items: [6, 8]
                            .map(
                              (d) =>
                                  DropdownMenuItem(value: d, child: Text('$d')),
                            )
                            .toList(),
                        onChanged: (v) => setState(() => digits = v!),
                        decoration: InputDecoration(
                          labelText: tr(app, '位数', 'Digits'),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: period,
                  keyboardType: TextInputType.number,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    labelText: tr(app, '周期（1–300 秒）', 'Period (1–300 seconds)'),
                  ),
                ),
              ],
            ),
            if (error != null)
              Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: busy ? null : () => Navigator.pop(context),
        child: Text(tr(app, '取消', 'Cancel')),
      ),
      FilledButton(
        onPressed: busy ? null : save,
        child: Text(tr(app, '保存账号', 'Save account')),
      ),
    ],
  );
}

Future<void> scanQr(BuildContext context, AppController app) async {
  if (!Platform.isAndroid && !Platform.isIOS) return;
  final codes = await Navigator.of(
    context,
  ).push<List<String>>(MaterialPageRoute(builder: (_) => _ScanScreen(app)));
  if (codes == null || !context.mounted || app.locked) return;
  try {
    await chooseQr(context, app, codes);
  } catch (e) {
    if (context.mounted) showError(context, app, e);
  }
}

Future<String?> scanPairing(BuildContext context, AppController app) async {
  final values = await Navigator.of(context).push<List<String>>(
    MaterialPageRoute(builder: (_) => _ScanScreen(app, pairing: true)),
  );
  if (values == null || values.isEmpty || app.locked) return null;
  return values.first;
}

class _ScanScreen extends StatefulWidget {
  final AppController app;
  final bool pairing;
  const _ScanScreen(this.app, {this.pairing = false});
  @override
  State<_ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<_ScanScreen> {
  final controller = MobileScannerController(formats: [BarcodeFormat.qrCode]);
  bool handled = false;
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        widget.pairing
            ? tr(widget.app, '扫描新设备配对二维码', 'Scan device pairing QR')
            : tr(widget.app, '扫描 TOTP 二维码', 'Scan a TOTP QR code'),
      ),
    ),
    body: MobileScanner(
      controller: controller,
      onDetect: (capture) {
        final codes = capture.barcodes
            .map((b) => b.rawValue)
            .whereType<String>()
            .toSet()
            .toList();
        if (!handled && codes.isNotEmpty) {
          handled = true;
          Navigator.pop(context, codes);
        }
      },
      errorBuilder: (context, error) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                tr(
                  widget.app,
                  '相机不可用或权限被拒绝。可返回后选择图片导入或手动输入。',
                  'Camera unavailable or permission denied. Go back to import an image or enter a secret.',
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => Navigator.pop(context),
                child: Text(tr(widget.app, '返回', 'Go back')),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
