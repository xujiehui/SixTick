import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:six_tick/core/document.dart';
import 'package:six_tick/core/totp.dart';
import 'package:six_tick/services/controller.dart';
import 'package:six_tick/services/local_store.dart';
import 'package:six_tick/ui/account_order.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  VaultDocument fixture() => VaultDocument()
      .add(OtpAccount(issuer: 'Zulu', secret: 'JBSWY3DPEHPK3PXP'))
      .add(
        OtpAccount(issuer: 'Alpha', secret: 'GEZDGNBVGY3TQOJQ'),
        favorite: true,
      )
      .add(OtpAccount(issuer: 'Beta', secret: 'MZXW6YTBOI======'));
  test('manual order survives removed IDs, duplicates and new arrivals', () {
    final entries = fixture().entries;
    final order = [entries[2].id, 'deleted-id', entries[0].id, entries[2].id];
    expect(orderAccounts(entries, 'custom', order).map((e) => e.otp.issuer), [
      'Beta',
      'Zulu',
      'Alpha',
    ]);
    expect(orderAccounts(entries, 'name', order).map((e) => e.otp.issuer), [
      'Alpha',
      'Beta',
      'Zulu',
    ]);
    expect(
      orderAccounts(entries, 'favorites', order).map((e) => e.otp.issuer),
      ['Alpha', 'Beta', 'Zulu'],
    );
    expect(orderAccounts(entries, 'custom', order).map((e) => e.otp.issuer), [
      'Beta',
      'Zulu',
      'Alpha',
    ]);
  });
  test(
    'sort preferences persist in the encrypted device store without changing the vault',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'six-tick-order-',
      );
      final app = AppController(LocalStore(directory));
      const password = 'local sorting test password';
      try {
        await app.create(password: password);
        for (final entry in fixture().entries) {
          await app.add(entry.otp, null);
        }
        final before = app.document!.toJson();
        final ids = app.document!.entries.reversed.map((e) => e.id).toList();
        await app.preferences({'accountSort': 'custom', 'accountOrder': ids});
        expect(app.document!.toJson(), before);
        final disk = await app.store.file.readAsString();
        expect(disk, isNot(contains(ids.first)));
        app.lock();
        await app.unlock(password: password);
        expect(app.settings['accountOrder'], ids);
        expect(
          orderAccounts(
            app.document!.entries,
            app.settings['accountSort'] as String,
            (app.settings['accountOrder'] as List).cast<String>(),
          ).map((e) => e.id),
          ids,
        );
      } finally {
        app.dispose();
        await directory.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
