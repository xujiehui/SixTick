import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:six_tick/core/document.dart';
import 'package:six_tick/core/totp.dart';
import 'package:six_tick/services/controller.dart';
import 'package:six_tick/services/local_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  setUp(
    () async => dir = await Directory.systemTemp.createTemp('six-tick-local-'),
  );
  tearDown(() async => dir.delete(recursive: true));
  const password = 'local test password 123';
  final otp = OtpAccount(
    issuer: 'Private service',
    account: 'private@example.com',
    secret: 'JBSWY3DPEHPK3PXP',
  );
  test(
    'offline vault persists encrypted and requires authentication after restart',
    () async {
      final store = LocalStore(dir);
      final app = AppController(store);
      await app.initialize();
      expect(app.exists, false);
      await app.create(password: password);
      await app.add(otp, null);
      final disk = await store.file.readAsString();
      for (final secret in [otp.secret, otp.issuer, otp.account, password]) {
        expect(disk, isNot(contains(secret)));
      }
      app.lock();
      expect(app.document, isNull);
      expect(app.cloud, isNull);
      await expectLater(
        app.unlock(password: 'incorrect password'),
        throwsFormatException,
      );
      expect(app.locked, true);
      await app.unlock(password: password);
      expect(app.document!.entries.single.otp.toJson(), otp.toJson());
      expect(await store.reauthenticate(password: password), true);
      expect(await store.reauthenticate(password: 'wrong'), false);
      app.dispose();
      store.lock();
      final restarted = AppController(LocalStore(dir));
      await restarted.initialize();
      expect(restarted.exists, true);
      expect(restarted.locked, true);
      await restarted.unlock(password: password);
      expect(restarted.document!.entries.single.otp.codeAt(59), otp.codeAt(59));
      restarted.dispose();
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
  test(
    'failed save never replaces in-memory state or shows a successful write',
    () async {
      final store = _FailingStore(dir);
      final app = AppController(store);
      await app.create(password: password);
      store.fail = true;
      await expectLater(
        app.add(otp, null),
        throwsA(isA<FileSystemException>()),
      );
      expect(app.document!.entries, isEmpty);
      store.fail = false;
      app.lock();
      await app.unlock(password: password);
      expect(app.document!.entries, isEmpty);
      app.dispose();
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
  test(
    'tampered vault cannot be unlocked and plaintext never reaches disk',
    () async {
      final store = LocalStore(dir);
      await store.create({
        'document': VaultDocument().add(otp).toJson(),
      }, password: password);
      store.lock();
      final encrypted =
          jsonDecode(await store.file.readAsString()) as Map<String, dynamic>;
      final box = encrypted['box'] as Map<String, dynamic>;
      final bytes = base64Decode(box['ciphertext'] as String);
      bytes[0] ^= 1;
      box['ciphertext'] = base64Encode(bytes);
      await store.file.writeAsString(jsonEncode(encrypted));
      await expectLater(
        store.unlock(password: password),
        throwsFormatException,
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}

class _FailingStore extends LocalStore {
  bool fail = false;
  _FailingStore(super.directory);
  @override
  Future<void> save(Map<String, dynamic> data) async {
    if (fail) throw const FileSystemException('Simulated full disk');
    await super.save(data);
  }
}
