import 'dart:convert';
import 'dart:io';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';
import 'package:path_provider/path_provider.dart';
import '../core/crypto.dart';

/// Only authenticated ciphertext and a password-wrapped random key reach disk.
class LocalStore {
  final FlutterSecureStorage secureStorage;
  final LocalAuthentication authentication;
  final Directory directory;
  SecretKey? _key;
  Map<String, dynamic>? _header;
  LocalStore(
    this.directory, {
    FlutterSecureStorage? secureStorage,
    LocalAuthentication? authentication,
  }) : secureStorage =
           secureStorage ??
           const FlutterSecureStorage(
             aOptions: AndroidOptions(encryptedSharedPreferences: true),
             iOptions: IOSOptions(
               accessibility: KeychainAccessibility.first_unlock_this_device,
             ),
             mOptions: MacOsOptions(
               accessibility: KeychainAccessibility.first_unlock_this_device,
             ),
           ),
       authentication = authentication ?? LocalAuthentication();
  static Future<LocalStore> initialize() async =>
      LocalStore(await getApplicationSupportDirectory());
  File get file => File('${directory.path}/vault.sixtick');
  Future<bool> get exists => file.exists();
  Future<bool> systemAvailable() async {
    try {
      return await authentication.isDeviceSupported();
    } catch (_) {
      return false;
    }
  }

  Future<bool> systemAuthenticate() async {
    try {
      return await authentication.authenticate(
        localizedReason: '解锁 Six Tick / Unlock Six Tick',
        options: const AuthenticationOptions(
          biometricOnly: false,
          stickyAuth: true,
          sensitiveTransaction: true,
        ),
      );
    } catch (_) {
      return false;
    }
  }

  Future<String> unlockMethod() async {
    final data = await _read();
    return data['method'] as String;
  }

  Future<Map<String, dynamic>> _read() async {
    if (await file.length() > 32 * 1024 * 1024) {
      throw const FormatException('file_too_large');
    }
    final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    if (data['format'] != 'six-tick-local' ||
        data['version'] != 1 ||
        !['system', 'password'].contains(data['method'])) {
      throw const FormatException('unsupported_version');
    }
    return data;
  }

  Future<void> create(Map<String, dynamic> data, {String? password}) async {
    if (await exists) throw const FormatException('vault_exists');
    final raw = VaultCrypto.randomBytes(32);
    if (password == null) {
      if (!await systemAuthenticate()) {
        throw const FormatException('authentication_cancelled');
      }
      await secureStorage.write(
        key: 'six_tick_local_key',
        value: base64Encode(raw),
      );
    } else {
      VaultCrypto.validatePassword(password);
    }
    _key = SecretKey(raw);
    _header = {
      'format': 'six-tick-local',
      'version': 1,
      'method': password == null ? 'system' : 'password',
      if (password != null)
        'wrappedKey': await VaultCrypto.passwordSeal(
          {'key': base64Encode(raw)},
          password,
          'local-key',
        ),
    };
    try {
      await save(data);
    } catch (_) {
      lock();
      rethrow;
    }
  }

  Future<Map<String, dynamic>> unlock({String? password}) async {
    final data = await _read();
    SecretKey key;
    if (data['method'] == 'system') {
      if (!await systemAuthenticate()) {
        throw const FormatException('authentication_cancelled');
      }
      final raw = await secureStorage.read(key: 'six_tick_local_key');
      if (raw == null) throw const FormatException('local_key_missing');
      key = SecretKey(base64Decode(raw));
    } else {
      final plain = await VaultCrypto.passwordOpen(
        data['wrappedKey'] as Map<String, dynamic>,
        password ?? '',
        'local-key',
      );
      key = SecretKey(base64Decode(plain['key'] as String));
    }
    final plain = await VaultCrypto.open(
      data['box'] as Map<String, dynamic>,
      key,
      'local-vault',
    );
    _key = key;
    _header = Map.of(data)..remove('box');
    return plain;
  }

  Future<bool> reauthenticate({String? password}) async {
    if (_key == null || _header == null) return false;
    if (_header!['method'] == 'system') return systemAuthenticate();
    try {
      final unwrapped = await VaultCrypto.passwordOpen(
        _header!['wrappedKey'] as Map<String, dynamic>,
        password ?? '',
        'local-key',
      );
      final expected = await _key!.extractBytes(),
          actual = base64Decode(unwrapped['key'] as String);
      if (expected.length != actual.length) return false;
      var difference = 0;
      for (var i = 0; i < expected.length; i++) {
        difference |= expected[i] ^ actual[i];
      }
      return difference == 0;
    } catch (_) {
      return false;
    }
  }

  bool get usesSystem => _header?['method'] == 'system';
  Future<void> save(Map<String, dynamic> data) async {
    final key = _key, header = _header;
    if (key == null || header == null) throw const FormatException('locked');
    final encoded = jsonEncode({
      ...header,
      'box': await VaultCrypto.seal(data, key, 'local-vault'),
    });
    await directory.create(recursive: true);
    final temporary = File('${file.path}.pending');
    try {
      await temporary.writeAsString(encoded, flush: true);
      // Same-directory replacement; the last complete vault survives interrupted writes.
      await temporary.rename(file.path);
    } catch (_) {
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    }
  }

  void lock() {
    _key = null;
    _header = null;
  }

  Future<void> remove() async {
    lock();
    if (await file.exists()) await file.delete();
    final pending = File('${file.path}.pending');
    if (await pending.exists()) await pending.delete();
    await secureStorage.delete(key: 'six_tick_local_key');
  }
}
