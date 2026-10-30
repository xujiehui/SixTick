import 'dart:io';
import 'package:flutter/material.dart';
import '../services/api.dart';
import '../services/controller.dart';

String tr(AppController app, String zh, String en) =>
    app.settings['language'] == 'en' ? en : zh;

String errorText(AppController app, Object error) {
  final code = error is FormatException
      ? error.message
      : error is ApiException
      ? error.code
      : '';
  const messages = {
    'invalid_secret': ['密钥不是有效的 Base32 编码。', 'The secret is not valid Base32.'],
    'unsupported_parameters': [
      '不支持的算法、位数或周期，未保存任何内容。',
      'Unsupported algorithm, digits or period. Nothing was saved.',
    ],
    'unsupported_uri': [
      '仅支持标准 TOTP 二维码和 otpauth://totp 链接。',
      'Only standard TOTP QR codes and otpauth://totp links are supported.',
    ],
    'invalid_uri': [
      '二维码缺少必要的账号或密钥信息。',
      'The QR code is missing account or secret information.',
    ],
    'issuer_conflict': [
      '链接中的服务名称存在冲突，请检查来源。',
      'The issuer values in this link conflict. Check its source.',
    ],
    'invalid_name': ['请输入有效的服务或分组名称。', 'Enter a valid service or group name.'],
    'password_length': [
      '密码需要至少 12 个字符，最多 1024 个字符。',
      'Use a password between 12 and 1,024 characters.',
    ],
    'decryption_failed': [
      '无法解密：密码或恢复密钥不正确，或文件已损坏。',
      'Cannot decrypt: incorrect credentials or damaged data.',
    ],
    'corrupt_data': [
      '数据校验失败，原有数据未被覆盖。',
      'Data validation failed. Existing data was preserved.',
    ],
    'unsupported_version': [
      '数据格式或版本不受支持，请更新应用。',
      'Unsupported data version. Update the app.',
    ],
    'invalid_recovery_key': [
      '恢复密钥校验失败，请检查字符是否完整。',
      'Recovery key checksum failed. Check the full key.',
    ],
    'authentication_cancelled': [
      '认证已取消或不可用。',
      'Authentication was cancelled or unavailable.',
    ],
    'local_key_missing': [
      '系统安全存储中的密钥不可用，请使用备份或云恢复。',
      'The local secure key is unavailable. Restore a backup or cloud vault.',
    ],
    'invalid_code': [
      '验证码错误、已过期或尝试次数过多。',
      'Incorrect, expired or exhausted sign-in code.',
    ],
    'rate_limited': ['请求过于频繁，请稍后再试。', 'Too many requests. Try again later.'],
    'mail_unavailable': [
      '邮件服务暂时不可用，不影响本地取码。',
      'Email is temporarily unavailable. Local codes still work.',
    ],
    'reauthentication_required': [
      '请重新验证登录邮箱后再操作。',
      'Verify your email again to continue.',
    ],
    'device_revoked': [
      '此设备需要重新授权，本地账号仍可取码。',
      'This device needs authorization. Local codes remain available.',
    ],
    'unauthorized': ['登录已失效，请重新登录。', 'Your session expired. Sign in again.'],
    'https_required': ['同步服务器必须使用 HTTPS。', 'The sync server must use HTTPS.'],
    'pairing_expired': [
      '配对请求已过期或已使用，请重新发起。',
      'Pairing expired or was consumed. Start again.',
    ],
    'pairing_mismatch': [
      '配对信息不一致，请取消此次授权。',
      'Pairing details do not match. Cancel authorization.',
    ],
    'invalid_pairing': [
      '请输入另一台设备显示的完整配对码。',
      'Enter the complete pairing code from the other device.',
    ],
    'qr_not_found': [
      '未识别到二维码，请换一张清晰图片。',
      'No QR code found. Try a clearer image.',
    ],
    'invalid_image': [
      '图片格式不支持，或图片尺寸过大。',
      'Unsupported image or excessive dimensions.',
    ],
    'file_too_large': ['文件过大，无法导入。', 'The file is too large to import.'],
    'sync_conflict': [
      '云数据发生了变化，请同步后重试。',
      'Cloud data changed. Sync and try again.',
    ],
    'locked': ['应用已锁定，请解锁后重试。', 'The app is locked. Unlock and try again.'],
    'wrong_account': [
      '请使用当前仓库的登录邮箱。',
      'Use the email associated with this vault.',
    ],
  };
  final message = messages[code];
  if (message != null) return tr(app, message[0], message[1]);
  if (error is SocketException) {
    return tr(
      app,
      '网络连接失败，本地数据仍然可用。',
      'Network unavailable. Your local vault is still available.',
    );
  }
  return tr(
    app,
    '操作未完成，请检查输入或稍后重试。',
    'The operation did not complete. Check your input or try again.',
  );
}

void showError(BuildContext context, AppController app, Object error) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(errorText(app, error))));
}

Future<bool> confirm(
  BuildContext context,
  String title,
  String body,
  String action, {
  bool danger = false,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Text(body),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Icon(Icons.close),
          ),
          FilledButton(
            style: danger
                ? FilledButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.error,
                  )
                : null,
            onPressed: () => Navigator.pop(context, true),
            child: Text(action),
          ),
        ],
      ),
    ) ??
    false;

Future<String?> askText(
  BuildContext context,
  String title,
  String label,
  String action, {
  String initial = '',
  bool secret = false,
  String? helper,
}) async {
  final text = TextEditingController(text: initial);
  final result = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 420,
        child: TextField(
          controller: text,
          autofocus: true,
          obscureText: secret,
          autocorrect: !secret,
          enableSuggestions: !secret,
          decoration: InputDecoration(
            labelText: label,
            helperText: helper,
            helperMaxLines: 4,
          ),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Icon(Icons.close),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, text.text),
          child: Text(action),
        ),
      ],
    ),
  );
  // Controllers remain alive through the dialog's reverse animation.
  await Future<void>.delayed(const Duration(milliseconds: 250));
  text.dispose();
  return result;
}

Future<bool> reauthenticate(BuildContext context, AppController app) async {
  String? password;
  if (!app.store.usesSystem) {
    password = await askText(
      context,
      tr(app, '验证身份', 'Verify your identity'),
      tr(app, '本机解锁密码', 'Local unlock password'),
      tr(app, '验证', 'Verify'),
      secret: true,
    );
    if (password == null) return false;
  }
  final success = await app.store.reauthenticate(password: password);
  if (!success && context.mounted) {
    showError(context, app, const FormatException('decryption_failed'));
  }
  return success && !app.locked;
}

class SectionCard extends StatelessWidget {
  final String title, subtitle;
  final IconData icon;
  final List<Widget> children;
  const SectionCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.children,
  });
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(subtitle, style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 20),
          ...children,
        ],
      ),
    ),
  );
}
