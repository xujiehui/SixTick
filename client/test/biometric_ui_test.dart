import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:six_tick/core/document.dart';
import 'package:six_tick/main.dart';
import 'package:six_tick/services/controller.dart';
import 'package:six_tick/services/local_store.dart';
import 'package:six_tick/ui/design.dart';
import 'package:six_tick/ui/gate.dart';
import 'package:six_tick/ui/security_page.dart';

class _UiStore extends LocalStore {
  _UiStore() : super(Directory.systemTemp);
  bool enabled = true, supported = true, authPending = false;
  String? verifiedPassword;
  @override
  Future<bool> systemAvailable() async => false;
  @override
  Future<String> unlockMethod() async => 'password';
  @override
  Future<bool> biometricAvailable() async => supported;
  @override
  Future<bool> hasBiometricUnlock() async => enabled;
  @override
  bool get biometricEnabled => enabled;
  @override
  bool get usesSystem => false;
  @override
  bool get authenticating => authPending;
  @override
  Future<void> setBiometricUnlock(
    bool value, {
    required String password,
  }) async {
    verifiedPassword = password;
    enabled = value;
  }
}

class _UiApp extends AppController {
  _UiApp(super.store) {
    exists = true;
  }
  bool cancel = false;
  bool? requestedBiometric;
  String? requestedPassword;
  @override
  Future<void> unlock({String? password, bool biometric = false}) async {
    requestedBiometric = biometric;
    requestedPassword = password;
    if (cancel) throw const FormatException('authentication_cancelled');
    document = VaultDocument();
    notifyListeners();
  }
}

void main() {
  late _UiStore store;
  late _UiApp app;
  setUp(() {
    store = _UiStore();
    app = _UiApp(store);
  });
  tearDown(() => app.dispose());
  Future<void> gate(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: sixTickTheme(Brightness.light),
        home: GateScreen(app: app, onRestore: (_) {}),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'Touch ID is the default and password remains an explicit fallback',
    (tester) async {
      await gate(tester);
      expect(find.text('使用 Touch ID 解锁'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.text('使用本机密码'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'existing password');
      await tester.tap(find.text('解锁'));
      await tester.pumpAndSettle();
      expect(app.requestedBiometric, false);
      expect(app.requestedPassword, 'existing password');
    },
  );

  testWidgets(
    'cancelled Touch ID shows password and allows a biometric retry',
    (tester) async {
      app.cancel = true;
      await gate(tester);
      await tester.tap(find.text('使用 Touch ID 解锁'));
      await tester.pumpAndSettle();
      expect(app.requestedBiometric, true);
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('认证已取消或不可用。'), findsOneWidget);
      await tester.tap(find.text('使用 Touch ID'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      expect(find.text('认证已取消或不可用。'), findsNothing);
    },
  );

  testWidgets('unavailable Touch ID keeps password usable', (tester) async {
    store.supported = false;
    await gate(tester);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('使用 Touch ID 解锁'), findsNothing);
    expect(find.text('Touch ID 不可用时，可使用原本机密码。'), findsOneWidget);
  });

  testWidgets('existing password vault explains where to enable Touch ID', (
    tester,
  ) async {
    store.enabled = false;
    await gate(tester);
    expect(find.text('解锁后可在“安全与备份”启用 Touch ID。'), findsOneWidget);
  });

  testWidgets('security switch verifies password before enabling Touch ID', (
    tester,
  ) async {
    store.enabled = false;
    app.document = VaultDocument();
    await tester.pumpWidget(
      MaterialApp(
        theme: sixTickTheme(Brightness.light),
        home: Scaffold(body: SecurityPage(app: app)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('使用 Touch ID 解锁'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(store.enabled, false);
    expect(find.text('启用 Touch ID'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'existing password');
    await tester.tap(find.text('继续'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    // The controller's serial queue was created outside the widget clock.
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(store.verifiedPassword, 'existing password');
    expect(store.enabled, true);
  });

  testWidgets(
    'authentication sheet does not auto-lock, system lock still does',
    (tester) async {
      app.document = VaultDocument();
      app.settings['lockSeconds'] = 0;
      store.authPending = true;
      await tester.pumpWidget(SixTickApp(controller: app));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump(const Duration(seconds: 2));
      expect(app.locked, false);
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'six_tick/privacy',
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('systemLocked'),
        ),
        (_) {},
      );
      await tester.pump();
      expect(app.locked, true);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('actually hiding the app still locks during authentication', (
    tester,
  ) async {
    app.document = VaultDocument();
    app.settings['lockSeconds'] = 0;
    store.authPending = true;
    await tester.pumpWidget(SixTickApp(controller: app));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    expect(app.locked, true);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(const SizedBox());
  });
}
