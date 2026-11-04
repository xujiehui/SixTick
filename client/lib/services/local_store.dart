import 'dart:convert';
import 'dart:io';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';
import 'package:path_provider/path_provider.dart';
import '../core/crypto.dart';
import 'biometric_key_store.dart';

/// Only authenticated ciphertext and a password-wrapped random key reach disk.
class LocalStore {
  final FlutterSecureStorage secureStorage;
  final LocalAuthentication authentication;
  final BiometricKeyStore biometricKeys;
  final Directory directory;
  int _generation = 0;
  int _authenticationCount = 0;
  bool get authenticating => _authenticationCount > 0;
  SecretKey? _key;
  Map<String, dynamic>? _header;
  LocalStore(
    this.directory, {
    FlutterSecureStorage? secureStorage,
    LocalAuthentication? authentication,
    BiometricKeyStore? biometricKeys,
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
       authentication = authentication ?? LocalAuthentication(),
       biometricKeys = biometricKeys ?? BiometricKeyStore();
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
    _authenticationCount++;
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
    } finally {
      _authenticationCount--;
    }
  }

  Future<T> _biometricOperation<T>(Future<T> Function() work) async {
    _authenticationCount++;
    try {
      return await work();
    } finally {
      _authenticationCount--;
    }
  }

  Future<bool> biometricAvailable() => biometricKeys.available();
  bool get biometricEnabled => _header?['biometricKeyId'] is String;
  Future<bool> hasBiometricUnlock() async =>
      (await _read())['biometricKeyId'] is String;

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

  Future<Map<String, dynamic>> unlock({
    String? password,
    bool biometric = false,
  }) async {
    final generation = _generation;
    final data = await _read();
    SecretKey key;
    if (biometric) {
      final id = data['biometricKeyId'];
      if (id is! String) {
        throw const FormatException('biometric_key_unavailable');
      }
      key = SecretKey(await _biometricOperation(() => biometricKeys.read(id)));
    } else if (data['method'] == 'system') {
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
    if (generation != _generation) throw const FormatException('locked');
    _key = key;
    _header = Map.of(data)..remove('box');
    return plain;
  }

  Future<bool> reauthenticate({String? password}) async {
    if (_key == null || _header == null) return false;
    final generation = _generation, key = _key!, header = _header!;
    if (header['method'] == 'system') {
      return await systemAuthenticate() && generation == _generation;
    }
    try {
      final List<int> actual;
      if (password == null && header['biometricKeyId'] is String) {
        actual = await _biometricOperation(
          () => biometricKeys.read(header['biometricKeyId'] as String),
        );
      } else {
        final unwrapped = await VaultCrypto.passwordOpen(
          header['wrappedKey'] as Map<String, dynamic>,
          password ?? '',
          'local-key',
        );
        actual = base64Decode(unwrapped['key'] as String);
      }
      final expected = await key.extractBytes();
      if (generation != _generation) return false;
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

  /// Adds a separate keychain route; the original password wrapper is retained.
  Future<void> setBiometricUnlock(
    bool enabled, {
    required String password,
  }) async {
    final generation = _generation, key = _key, header = _header;
    if (key == null || header == null) throw const FormatException('locked');
    if (header['method'] != 'password' ||
        !await reauthenticate(password: password)) {
      throw const FormatException('decryption_failed');
    }
    if (generation != _generation) throw const FormatException('locked');
    final previousId = header['biometricKeyId'] as String?;
    final next = Map<String, dynamic>.of(header);
    String? newId;
    if (enabled) {
      if (!await biometricAvailable()) {
        throw const FormatException('biometric_unavailable');
      }
      if (generation != _generation) throw const FormatException('locked');
      newId = base64UrlEncode(VaultCrypto.randomBytes(24));
      await _biometricOperation(() async {
        await biometricKeys.write(newId!, await key.extractBytes());
      });
      next['biometricKeyId'] = newId;
    } else {
      next.remove('biometricKeyId');
    }
    try {
      if (generation != _generation) throw const FormatException('locked');
      final data = await _read();
      if (generation != _generation) throw const FormatException('locked');
      await _write({...next, 'box': data['box']});
      if (generation == _generation) _header = next;
    } catch (_) {
      if (newId != null) await biometricKeys.delete(newId);
      rethrow;
    }
    if (previousId != null) await biometricKeys.delete(previousId);
  }

  bool get usesSystem => _header?['method'] == 'system';
  Future<void> save(Map<String, dynamic> data) async {
    final key = _key, header = _header;
    if (key == null || header == null) throw const FormatException('locked');
    await _write({
      ...header,
      'box': await VaultCrypto.seal(data, key, 'local-vault'),
    });
  }

  Future<void> _write(Map<String, dynamic> data) async {
    final encoded = jsonEncode(data);
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
    _generation++;
    _key = null;
    _header = null;
  }

  Future<void> remove() async {
    final id = await exists
        ? (await _read())['biometricKeyId'] as String?
        : null;
    if (id != null) await biometricKeys.delete(id);
    lock();
    if (await file.exists()) await file.delete();
    final pending = File('${file.path}.pending');
    if (await pending.exists()) await pending.delete();
    await secureStorage.delete(key: 'six_tick_local_key');
  }
}
