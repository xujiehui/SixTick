import 'dart:typed_data';
import 'package:crypto/crypto.dart';

const _alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

String normalizeSecret(String value) {
  final normalized = value.replaceAll(RegExp(r'\s'), '').toUpperCase();
  decodeBase32(normalized);
  return normalized.replaceAll('=', '');
}

Uint8List decodeBase32(String value) {
  final normalized = value.replaceAll(RegExp(r'\s'), '').toUpperCase();
  if (!RegExp(r'^[A-Z2-7]+={0,6}$').hasMatch(normalized)) {
    throw const FormatException('invalid_secret');
  }
  final raw = normalized.replaceAll('=', '');
  if (![0, 2, 4, 5, 7].contains(raw.length % 8)) {
    throw const FormatException('invalid_secret');
  }
  final padding = normalized.length - raw.length;
  if (padding > 0 &&
      (normalized.length % 8 != 0 || padding != (8 - raw.length % 8) % 8)) {
    throw const FormatException('invalid_secret');
  }
  var buffer = 0, bits = 0;
  final result = <int>[];
  for (final char in raw.split('')) {
    buffer = (buffer << 5) | _alphabet.indexOf(char);
    bits += 5;
    if (bits >= 8) {
      bits -= 8;
      result.add((buffer >> bits) & 255);
      buffer &= (1 << bits) - 1;
    }
  }
  if (result.isEmpty || buffer != 0) {
    throw const FormatException('invalid_secret');
  }
  return Uint8List.fromList(result);
}

String encodeBase32(List<int> bytes) {
  var buffer = 0, bits = 0;
  final result = StringBuffer();
  for (final byte in bytes) {
    buffer = (buffer << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      bits -= 5;
      result.write(_alphabet[(buffer >> bits) & 31]);
      buffer &= (1 << bits) - 1;
    }
  }
  if (bits > 0) result.write(_alphabet[(buffer << (5 - bits)) & 31]);
  return result.toString();
}

class OtpAccount {
  final String issuer, account, secret, algorithm;
  final int digits, period;
  OtpAccount({
    required String issuer,
    this.account = '',
    required String secret,
    this.algorithm = 'SHA1',
    this.digits = 6,
    this.period = 30,
  }) : issuer = issuer.trim(),
       secret = normalizeSecret(secret) {
    if (this.issuer.isEmpty ||
        this.issuer.length > 200 ||
        account.length > 300) {
      throw const FormatException('invalid_name');
    }
    if (!['SHA1', 'SHA256', 'SHA512'].contains(algorithm) ||
        ![6, 8].contains(digits) ||
        period < 1 ||
        period > 300) {
      throw const FormatException('unsupported_parameters');
    }
  }

  factory OtpAccount.fromJson(Map<String, dynamic> json) => OtpAccount(
    issuer: json['issuer'] as String,
    account: json['account'] as String? ?? '',
    secret: json['secret'] as String,
    algorithm: json['algorithm'] as String? ?? 'SHA1',
    digits: json['digits'] as int? ?? 6,
    period: json['period'] as int? ?? 30,
  );

  factory OtpAccount.fromUri(String text) {
    final uri = Uri.parse(text.trim());
    if (uri.scheme != 'otpauth' ||
        uri.host != 'totp' ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort ||
        uri.fragment.isNotEmpty) {
      throw const FormatException('unsupported_uri');
    }
    final all = uri.queryParametersAll;
    if (all.values.any((values) => values.length != 1) ||
        all.keys.any(
          (key) => ![
            'secret',
            'issuer',
            'algorithm',
            'digits',
            'period',
          ].contains(key),
        )) {
      throw const FormatException('unsupported_parameters');
    }
    final p = uri.queryParameters;
    if (uri.pathSegments.length != 1 || !p.containsKey('secret')) {
      throw const FormatException('invalid_uri');
    }
    final label = uri.pathSegments.single;
    final colon = label.indexOf(':');
    final labelIssuer = colon < 0 ? '' : label.substring(0, colon).trim();
    final issuer = (p['issuer'] ?? labelIssuer).trim();
    if (labelIssuer.isNotEmpty && issuer != labelIssuer) {
      throw const FormatException('issuer_conflict');
    }
    return OtpAccount(
      issuer: issuer.isEmpty ? label : issuer,
      account: colon < 0 ? label : label.substring(colon + 1).trim(),
      secret: p['secret']!,
      algorithm: p['algorithm']?.toUpperCase() ?? 'SHA1',
      digits: p.containsKey('digits') ? int.parse(p['digits']!) : 6,
      period: p.containsKey('period') ? int.parse(p['period']!) : 30,
    );
  }

  Map<String, dynamic> toJson() => {
    'issuer': issuer,
    'account': account,
    'secret': secret,
    'algorithm': algorithm,
    'digits': digits,
    'period': period,
  };
  String get fingerprint => '$secret:$algorithm:$digits:$period';
  String toUri() => Uri(
    scheme: 'otpauth',
    host: 'totp',
    pathSegments: ['$issuer:$account'],
    queryParameters: {
      'secret': secret,
      'issuer': issuer,
      'algorithm': algorithm,
      'digits': '$digits',
      'period': '$period',
    },
  ).toString();
  String codeAt(int unixSeconds) {
    if (unixSeconds < 0) throw const FormatException('invalid_time');
    final bytes = ByteData(8)..setUint64(0, unixSeconds ~/ period, Endian.big);
    final hash = switch (algorithm) {
      'SHA256' => sha256,
      'SHA512' => sha512,
      _ => sha1,
    };
    final mac = Hmac(
      hash,
      decodeBase32(secret),
    ).convert(bytes.buffer.asUint8List()).bytes;
    final offset = mac.last & 15;
    final number =
        ((mac[offset] & 127) << 24) |
        (mac[offset + 1] << 16) |
        (mac[offset + 2] << 8) |
        mac[offset + 3];
    return (number % (digits == 6 ? 1000000 : 100000000)).toString().padLeft(
      digits,
      '0',
    );
  }

  int remaining(int unixSeconds) => period - unixSeconds % period;
}
