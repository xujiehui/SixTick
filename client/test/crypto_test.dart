import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:six_tick/core/crypto.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'authenticated encryption detects tampering, wrong key and wrong context',
    () async {
      final key = SecretKey(VaultCrypto.randomBytes(32));
      final box = await VaultCrypto.seal(
        {'secret': 'JBSWY3DPEHPK3PXP'},
        key,
        'test',
      );
      expect(jsonEncode(box), isNot(contains('JBSWY3DPEHPK3PXP')));
      expect(await VaultCrypto.open(box, key, 'test'), {
        'secret': 'JBSWY3DPEHPK3PXP',
      });
      await expectLater(
        VaultCrypto.open(box, key, 'other'),
        throwsFormatException,
      );
      await expectLater(
        VaultCrypto.open(box, SecretKey(VaultCrypto.randomBytes(32)), 'test'),
        throwsFormatException,
      );
      final bytes = base64Decode(box['ciphertext'] as String);
      bytes[0] ^= 1;
      await expectLater(
        VaultCrypto.open(
          {...box, 'ciphertext': base64Encode(bytes)},
          key,
          'test',
        ),
        throwsFormatException,
      );
    },
  );
  test(
    'independent backup password and bounded work factor',
    () async {
      final backup = await VaultCrypto.passwordSeal(
        {'entries': [], 'version': 1},
        'a strong backup password',
        'backup',
      );
      expect(
        await VaultCrypto.passwordOpen(
          backup,
          'a strong backup password',
          'backup',
        ),
        {'entries': [], 'version': 1},
      );
      await expectLater(
        VaultCrypto.passwordOpen(backup, 'the wrong password', 'backup'),
        throwsFormatException,
      );
      await expectLater(
        VaultCrypto.passwordOpen(
          {...backup, 'iterations': 999999999},
          'unused',
          'backup',
        ),
        throwsFormatException,
      );
      expect(
        () => VaultCrypto.validatePassword('short'),
        throwsFormatException,
      );
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
  test('recovery material has 256 bits of entropy and checksum', () async {
    final a = VaultCrypto.newRecoveryKey(), b = VaultCrypto.newRecoveryKey();
    expect(a, isNot(b));
    expect((await VaultCrypto.recoveryKey(a).extractBytes()).length, 32);
    expect(
      await VaultCrypto.recoveryKey(a.toLowerCase()).extractBytes(),
      await VaultCrypto.recoveryKey(a).extractBytes(),
    );
    expect(
      () => VaultCrypto.recoveryKey(
        '${a[0] == 'A' ? 'B' : 'A'}${a.substring(1)}',
      ),
      throwsFormatException,
    );
  });
}
