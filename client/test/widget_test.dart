import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:six_tick/core/document.dart';
import 'package:six_tick/core/totp.dart';
import 'package:six_tick/services/controller.dart';
import 'package:six_tick/services/local_store.dart';
import 'package:six_tick/ui/home.dart';
import 'package:six_tick/ui/add_account.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppController app;
  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('six-tick-widget-');
    app = AppController(LocalStore(dir));
    app.document = VaultDocument().add(
      OtpAccount(
        issuer: 'Example',
        account: 'alice@example.com',
        secret: 'JBSWY3DPEHPK3PXP',
      ),
    );
  });
  tearDown(() async {
    app.dispose();
    await dir.delete(recursive: true);
  });
  testWidgets('desktop navigation and account search are usable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(home: HomeScreen(app: app)));
    expect(find.text('Example'), findsOneWidget);
    expect(find.text('Six Tick'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'no-such-account');
    await tester.pump();
    expect(find.text('Example'), findsNothing);
    expect(find.text('没有找到匹配的账号'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('phone account list fits and provides bottom navigation', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(home: HomeScreen(app: app)));
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('Example'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('provisioning confirmation never saves automatically', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AddAccountDialog(
            app: app,
            initial: OtpAccount(issuer: 'Imported', secret: 'JBSWY3DPEHPK3PXP'),
          ),
        ),
      ),
    );
    expect(find.text('确认账号'), findsOneWidget);
    expect(find.text('保存账号'), findsOneWidget);
    expect(app.document!.entries.length, 1);
    expect(tester.takeException(), isNull);
  });
}
