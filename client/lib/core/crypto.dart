import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:crypto/crypto.dart' as hashes;
import 'totp.dart';

class VaultCrypto {
  static const iterations = 600000;
  static final cipher = AesGcm.with256bits();
  static Uint8List randomBytes(int count) {
    final random = Random.secure();
    return Uint8List.fromList(List.generate(count, (_) => random.nextInt(256)));
  }

  static void validatePassword(String password) {
    if (password.runes.length < 12 || password.length > 1024) {
      throw const FormatException('password_length');
    }
  }

  static Future<SecretKey> passwordKey(String password, List<int> salt) =>
      Pbkdf2(
        macAlgorithm: Hmac.sha256(),
        iterations: iterations,
        bits: 256,
      ).deriveKey(secretKey: SecretKey(utf8.encode(password)), nonce: salt);

  static Future<Map<String, dynamic>> seal(
    Object data,
    SecretKey key,
    String purpose,
  ) async {
    final box = await cipher.encrypt(
      utf8.encode(jsonEncode(data)),
      secretKey: key,
      nonce: randomBytes(12),
      aad: utf8.encode('six-tick:v1:$purpose'),
    );
    return {
      'v': 1,
      'purpose': purpose,
      'nonce': base64Encode(box.nonce),
      'ciphertext': base64Encode(box.cipherText),
      'tag': base64Encode(box.mac.bytes),
    };
  }

  static Future<Map<String, dynamic>> open(
    Map<String, dynamic> data,
    SecretKey key,
    String purpose,
  ) async {
    if (data['v'] != 1 || data['purpose'] != purpose) {
      throw const FormatException('unsupported_version');
    }
    try {
      final nonce = base64Decode(data['nonce'] as String);
      final tag = base64Decode(data['tag'] as String);
      if (nonce.length != 12 || tag.length != 16) {
        throw const FormatException('corrupt_data');
      }
      final plain = await cipher.decrypt(
        SecretBox(
          base64Decode(data['ciphertext'] as String),
          nonce: nonce,
          mac: Mac(tag),
        ),
        secretKey: key,
        aad: utf8.encode('six-tick:v1:$purpose'),
      );
      try {
        return jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
      } finally {
        if (plain is Uint8List) plain.fillRange(0, plain.length, 0);
      }
    } on SecretBoxAuthenticationError {
      throw const FormatException('decryption_failed');
    }
  }

  static Future<Map<String, dynamic>> passwordSeal(
    Object data,
    String password,
    String purpose,
  ) async {
    validatePassword(password);
    final salt = randomBytes(16);
    final key = await passwordKey(password, salt);
    return {
      'format': 'six-tick',
      'version': 1,
      'kdf': 'PBKDF2-SHA256',
      'iterations': iterations,
      'salt': base64Encode(salt),
      'box': await seal(data, key, purpose),
    };
  }

  static Future<Map<String, dynamic>> passwordOpen(
    Map<String, dynamic> data,
    String password,
    String purpose,
  ) async {
    // A fixed v1 work factor avoids attacker-controlled KDF denial of service.
    if (data['format'] != 'six-tick' ||
        data['version'] != 1 ||
        data['kdf'] != 'PBKDF2-SHA256' ||
        data['iterations'] != iterations) {
      throw const FormatException('unsupported_version');
    }
    final salt = base64Decode(data['salt'] as String);
    if (salt.length != 16) throw const FormatException('corrupt_data');
    return open(
      data['box'] as Map<String, dynamic>,
      await passwordKey(password, salt),
      purpose,
    );
  }

  static String newRecoveryKey() {
    final bytes = randomBytes(32);
    final encoded = encodeBase32([
      ...bytes,
      ...hashes.sha256.convert(bytes).bytes.take(4),
    ]);
    return [
      for (var i = 0; i < encoded.length; i += 4)
        encoded.substring(i, min(i + 4, encoded.length)),
    ].join('-');
  }

  static SecretKey recoveryKey(String text) {
    final bytes = decodeBase32(text.replaceAll('-', ''));
    if (bytes.length != 36) throw const FormatException('invalid_recovery_key');
    final key = bytes.sublist(0, 32);
    final checksum = hashes.sha256.convert(key).bytes.take(4).toList();
    var mismatch = 0;
    for (var i = 0; i < 4; i++) {
      mismatch |= checksum[i] ^ bytes[32 + i];
    }
    if (mismatch != 0) throw const FormatException('invalid_recovery_key');
    return SecretKey(key);
  }
}
