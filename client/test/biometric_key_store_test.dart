import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:six_tick/services/biometric_key_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('six_tick/biometric_key');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final store = BiometricKeyStore();
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'native key bridge sends binary keys and preserves per-vault identifiers',
    () async {
      final bytes = Uint8List.fromList(List.generate(32, (i) => i));
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return call.method == 'read' ? bytes : null;
      });
      await store.write('vault-key-id', bytes);
      expect(await store.read('vault-key-id'), bytes);
      await store.delete('vault-key-id');
      expect(calls.map((call) => call.method), ['write', 'read', 'delete']);
      expect(calls.first.arguments['key'], isA<Uint8List>());
      for (final call in calls) {
        expect(call.arguments['id'], 'vault-key-id');
      }
    },
  );

  test(
    'native cancellation is returned as a recoverable authentication error',
    () async {
      messenger.setMockMethodCallHandler(channel, (_) async {
        throw PlatformException(code: 'authentication_cancelled');
      });
      await expectLater(
        store.read('vault-key-id'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            'authentication_cancelled',
          ),
        ),
      );
    },
  );

  test(
    'missing or truncated native keys never become decryption keys',
    () async {
      for (final value in [null, Uint8List(31)]) {
        messenger.setMockMethodCallHandler(channel, (_) async => value);
        await expectLater(store.read('vault-key-id'), throwsFormatException);
      }
    },
  );
}
