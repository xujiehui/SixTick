import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:six_tick/core/totp.dart';

void main() {
  const vectors = [
    [59, '94287082', '46119246', '90693936'],
    [1111111109, '07081804', '68084774', '25091201'],
    [1111111111, '14050471', '67062674', '99943326'],
    [1234567890, '89005924', '91819424', '93441116'],
    [2000000000, '69279037', '90698825', '38618901'],
    [20000000000, '65353130', '77737706', '47863826'],
  ];
  const secrets = [
    '12345678901234567890',
    '12345678901234567890123456789012',
    '1234567890123456789012345678901234567890123456789012345678901234',
  ];
  for (var algorithm = 0; algorithm < 3; algorithm++) {
    for (final row in vectors) {
      test(
        'RFC6238 ${['SHA1', 'SHA256', 'SHA512'][algorithm]} @ ${row[0]}',
        () {
          final otp = OtpAccount(
            issuer: 'RFC',
            secret: encodeBase32(utf8.encode(secrets[algorithm])),
            algorithm: ['SHA1', 'SHA256', 'SHA512'][algorithm],
            digits: 8,
          );
          expect(otp.codeAt(row[0] as int), row[algorithm + 1]);
        },
      );
    }
  }
  test('6 digits, custom period, time boundaries and clock jumps', () {
    final otp = OtpAccount(
      issuer: 'Test',
      secret: encodeBase32(utf8.encode(secrets.first)),
    );
    expect(otp.codeAt(59), '287082');
    expect(otp.remaining(59), 1);
    expect(otp.remaining(60), 30);
    expect(otp.codeAt(59), isNot(otp.codeAt(60)));
    expect(otp.codeAt(59), '287082');
    final custom = OtpAccount(issuer: 'Test', secret: otp.secret, period: 60);
    expect(custom.codeAt(118), otp.codeAt(59));
    expect(() => custom.codeAt(-1), throwsFormatException);
  });
  test('Base32 accepts presentation whitespace and valid padding', () {
    expect(normalizeSecret('jbsw y3dp ehpk3pxp'), 'JBSWY3DPEHPK3PXP');
    expect(utf8.decode(decodeBase32('MZXW6YTBOI======')), 'foobar');
    for (final invalid in [
      '',
      'A',
      'AB',
      'MZ======',
      'MZXW6YTBOI=',
      'ABC!DEF',
      '01ABCD',
    ]) {
      expect(
        () => decodeBase32(invalid),
        throwsFormatException,
        reason: invalid,
      );
    }
  });
  test('URI roundtrip preserves Unicode labels and all parameters', () {
    final otp = OtpAccount(
      issuer: '云服务',
      account: 'a+b@example.com',
      secret: 'JBSWY3DPEHPK3PXP',
      algorithm: 'SHA512',
      digits: 8,
      period: 75,
    );
    expect(OtpAccount.fromUri(otp.toUri()).toJson(), otp.toJson());
  });
  test('unsupported/ambiguous provisioning URIs fail closed', () {
    for (final uri in [
      'otpauth://hotp/A?secret=JBSWY3DPEHPK3PXP',
      'https://example.com',
      'otpauth://totp/A:a?issuer=B&secret=JBSWY3DPEHPK3PXP',
      'otpauth://totp/A?secret=JBSWY3DPEHPK3PXP&digits=7',
      'otpauth://totp/A?secret=JBSWY3DPEHPK3PXP&period=301',
      'otpauth://totp/A?secret=JBSWY3DPEHPK3PXP&period=0',
      'otpauth://totp/A?secret=JBSWY3DPEHPK3PXP&algorithm=MD5',
      'otpauth://totp/A?secret=JBSWY3DPEHPK3PXP&secret=JBSWY3DPEHPK3PXP',
      'otpauth://totp/A?secret=JBSWY3DPEHPK3PXP&counter=1',
    ]) {
      expect(() => OtpAccount.fromUri(uri), throwsFormatException, reason: uri);
    }
  });
}
