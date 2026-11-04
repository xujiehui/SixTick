import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:six_tick/core/totp.dart';
import 'package:six_tick/services/biometric_key_store.dart';
import 'package:six_tick/services/controller.dart';
import 'package:six_tick/services/local_store.dart';

class FakeBiometricKeys extends BiometricKeyStore {
  final keys = <String, List<int>>{};
  bool supported = true, cancelled = false;
  Completer<void>? readStarted, resumeRead;
  Completer<void>? writeStarted, resumeWrite;
  @override
  Future<bool> available() async => supported;
  @override
  Future<void> write(String id, List<int> key) async {
    writeStarted?.complete();
    if (resumeWrite != null) await resumeWrite!.future;
    if (cancelled) throw const FormatException('authentication_cancelled');
    keys[id] = List.of(key);
  }

  @override
  Future<List<int>> read(String id) async {
    readStarted?.complete();
    if (resumeRead != null) await resumeRead!.future;
    if (cancelled) throw const FormatException('authentication_cancelled');
    final key = keys[id];
    if (key == null) throw const FormatException('biometric_key_unavailable');
    return List.of(key);
  }

  @override
  Future<void> delete(String id) async => keys.remove(id);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const password = 'local test password 123';
  final otp = OtpAccount(issuer: 'Private service', secret: 'JBSWY3DPEHPK3PXP');
  late Directory directory;
  late FakeBiometricKeys keys;
  late LocalStore store;
  late AppController app;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('six-tick-biometric-');
    keys = FakeBiometricKeys();
    store = LocalStore(directory, biometricKeys: keys);
    app = AppController(store);
    await app.create(password: password);
    await app.add(otp, null);
  });
  tearDown(() async {
    app.dispose();
    await directory.delete(recursive: true);
  });

  test(
    'existing password vault gains Touch ID without losing password or data',
    () async {
      final before = jsonDecode(await store.file.readAsString()) as Map;
      await app.setBiometricUnlock(true, password);
      final after = jsonDecode(await store.file.readAsString()) as Map;
      expect(after['wrappedKey'], before['wrappedKey']);
      expect(after['box'], before['box']);
      expect(after['method'], 'password');
      expect(store.biometricEnabled, true);
      final disk = await store.file.readAsString();
      for (final secret in [
        password,
        otp.secret,
        base64Encode(keys.keys.values.single),
      ]) {
        expect(disk, isNot(contains(secret)));
      }
      app.lock();
      await app.unlock(biometric: true);
      expect(app.document!.entries.single.otp.toJson(), otp.toJson());
      expect(await store.reauthenticate(), true);
      await app.preferences({'theme': 'dark'});
      app.lock();
      final restarted = AppController(
        LocalStore(directory, biometricKeys: keys),
      );
      addTearDown(restarted.dispose);
      await restarted.initialize();
      await restarted.unlock(biometric: true);
      expect(restarted.settings['theme'], 'dark');
      expect(restarted.document!.entries.single.otp.toJson(), otp.toJson());
      restarted.lock();
      await restarted.unlock(password: password);
      expect(restarted.document!.entries.single.otp.toJson(), otp.toJson());
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test(
    'wrong password and cancelled enrollment preserve original vault',
    () async {
      final original = await store.file.readAsString();
      await expectLater(
        app.setBiometricUnlock(true, 'wrong'),
        throwsFormatException,
      );
      expect(keys.keys, isEmpty);
      keys.cancelled = true;
      await expectLater(
        app.setBiometricUnlock(true, password),
        throwsFormatException,
      );
      expect(await store.file.readAsString(), original);
      expect(store.biometricEnabled, false);
      expect(keys.keys, isEmpty);
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test(
    'cancelled authentication or invalidated key leaves password fallback',
    () async {
      await app.setBiometricUnlock(true, password);
      app.lock();
      keys.cancelled = true;
      await expectLater(app.unlock(biometric: true), throwsFormatException);
      expect(app.locked, true);
      await app.unlock(password: password);
      expect(await store.reauthenticate(), false);
      expect(await store.reauthenticate(password: password), true);
      app.lock();
      keys.cancelled = false;
      keys.keys
          .clear(); // Models biometryCurrentSet invalidation after fingerprint changes.
      await expectLater(app.unlock(biometric: true), throwsFormatException);
      expect(app.locked, true);
      await app.unlock(password: password);
      expect(app.document!.entries.single.otp.toJson(), otp.toJson());
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test(
    'disabling removes keychain route and retains password unlock',
    () async {
      await app.setBiometricUnlock(true, password);
      await expectLater(
        app.setBiometricUnlock(false, 'wrong'),
        throwsFormatException,
      );
      expect(store.biometricEnabled, true);
      await app.setBiometricUnlock(false, password);
      expect(store.biometricEnabled, false);
      expect(await store.hasBiometricUnlock(), false);
      expect(keys.keys, isEmpty);
      app.lock();
      await expectLater(app.unlock(biometric: true), throwsFormatException);
      await app.unlock(password: password);
      expect(app.document!.entries.single.otp.toJson(), otp.toJson());
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test(
    'failed enrollment persistence cleans up newly created key',
    () async {
      final original = await store.file.readAsString();
      await Directory('${store.file.path}.pending').create();
      await expectLater(
        app.setBiometricUnlock(true, password),
        throwsA(isA<FileSystemException>()),
      );
      expect(keys.keys, isEmpty);
      expect(store.biometricEnabled, false);
      expect(await store.file.readAsString(), original);
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test(
    'system lock during a pending Touch ID read cannot unlock the app',
    () async {
      await app.setBiometricUnlock(true, password);
      app.lock();
      keys.readStarted = Completer<void>();
      keys.resumeRead = Completer<void>();
      final unlocking = app.unlock(biometric: true);
      final rejected = expectLater(unlocking, throwsFormatException);
      await keys.readStarted!.future;
      expect(store.authenticating, true);
      app.lock();
      keys.resumeRead!.complete();
      await rejected;
      expect(store.authenticating, false);
      expect(app.locked, true);
      await expectLater(store.save({}), throwsFormatException);
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test(
    'system lock during enrollment removes newly created key',
    () async {
      final original = await store.file.readAsString();
      keys.writeStarted = Completer<void>();
      keys.resumeWrite = Completer<void>();
      final enrolling = app.setBiometricUnlock(true, password);
      final rejected = expectLater(enrolling, throwsFormatException);
      await keys.writeStarted!.future;
      expect(store.authenticating, true);
      app.lock();
      keys.resumeWrite!.complete();
      await rejected;
      expect(app.locked, true);
      expect(keys.keys, isEmpty);
      expect(await store.file.readAsString(), original);
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test(
    'Touch ID key cannot decrypt tampered vault ciphertext',
    () async {
      await app.setBiometricUnlock(true, password);
      app.lock();
      final encrypted =
          jsonDecode(await store.file.readAsString()) as Map<String, dynamic>;
      final box = encrypted['box'] as Map<String, dynamic>;
      final bytes = base64Decode(box['ciphertext'] as String);
      bytes[0] ^= 1;
      box['ciphertext'] = base64Encode(bytes);
      await store.file.writeAsString(jsonEncode(encrypted));
      await expectLater(app.unlock(biometric: true), throwsFormatException);
      expect(app.locked, true);
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test(
    'unavailable Touch ID cannot enroll; removing the vault deletes its key',
    () async {
      keys.supported = false;
      final original = await store.file.readAsString();
      await expectLater(
        app.setBiometricUnlock(true, password),
        throwsFormatException,
      );
      expect(await store.file.readAsString(), original);
      expect(keys.keys, isEmpty);
      keys.supported = true;
      await app.setBiometricUnlock(true, password);
      FlutterSecureStorage.setMockInitialValues({});
      await store.remove();
      expect(await store.exists, false);
      expect(keys.keys, isEmpty);
      await expectLater(store.save({}), throwsFormatException);
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );
}
