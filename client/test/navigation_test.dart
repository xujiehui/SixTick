import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:six_tick/core/document.dart';
import 'package:six_tick/core/totp.dart';
import 'package:six_tick/services/controller.dart';
import 'package:six_tick/services/local_store.dart';
import 'package:six_tick/ui/account_card.dart';
import 'package:six_tick/ui/add_account.dart';
import 'package:six_tick/ui/home.dart';
import 'package:six_tick/ui/design.dart';
import 'package:six_tick/ui/security_page.dart';

// UI persistence fixture. Actual encryption/restart behavior is covered in
// account_order_test; this store lets actions complete without platform auth.
class _MemoryStore extends LocalStore {
  Map<String, dynamic>? saved;
  bool fail = false;
  _MemoryStore(super.directory);
  @override
  Future<void> save(Map<String, dynamic> data) async {
    if (fail) throw const FileSystemException('test save failure');
    saved = data;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late _MemoryStore store;
  late AppController app;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('six-tick-ui-');
    store = _MemoryStore(directory);
    app = AppController(store);
    app.settings['clearClipboard'] = false;
    app.document = VaultDocument()
        .patch('group-test-work-0001', 'group', {'name': '工作'})
        .add(
          OtpAccount(issuer: 'Zulu', secret: 'JBSWY3DPEHPK3PXP'),
          group: 'group-test-work-0001',
        )
        .add(
          OtpAccount(issuer: 'Alpha', secret: 'GEZDGNBVGY3TQOJQ'),
          favorite: true,
        );
  });
  tearDown(() async {
    app.dispose();
    await directory.delete(recursive: true);
  });
  Future<void> mount(
    WidgetTester tester, {
    double width = 1200,
    int Function()? epochSeconds,
  }) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: sixTickTheme(Brightness.light),
        home: ListenableBuilder(
          listenable: app,
          builder: (_, _) => HomeScreen(app: app, epochSeconds: epochSeconds),
        ),
      ),
    );
  }

  List<String> names(WidgetTester tester) => tester
      .widgetList<AccountCard>(find.byType(AccountCard))
      .map((e) => e.entry.otp.issuer)
      .toList();
  testWidgets('recognized QR is saved only after explicit confirmation', (
    tester,
  ) async {
    await mount(tester, width: 390);
    final before = app.document!.entries.length;
    final candidate = OtpAccount(
      issuer: 'Scanned service',
      account: 'test@example.com',
      secret: 'MFRGGZDFMZTWQ2LK',
    );
    Future<void> open() => chooseQr(
      tester.element(find.byType(HomeScreen)),
      app,
      [candidate.toUri()],
    );
    final cancelled = open();
    await tester.pumpAndSettle();
    expect(find.text('确认账号'), findsOneWidget);
    expect(app.document!.entries.length, before);
    await tester.ensureVisible(find.text('取消'));
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await cancelled;
    expect(app.document!.entries.length, before);
    final confirmed = open();
    await tester.pumpAndSettle();
    expect(app.document!.entries.length, before);
    await tester.ensureVisible(find.text('保存账号'));
    await tester.tap(find.text('保存账号'));
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();
    await confirmed;
    expect(app.document!.entries.length, before + 1);
    expect(app.document!.entries.last.otp.issuer, candidate.issuer);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'mobile has three destinations and security is reachable through settings',
    (tester) async {
      await mount(tester, width: 390);
      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).destinations,
        hasLength(3),
      );
      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('安全与备份'));
      await tester.pumpAndSettle();
      expect(find.byType(SecurityPage), findsOneWidget);
      expect(find.text('导出加密备份'), findsOneWidget);
      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        2,
      );
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsPage), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'sidebar favorite and group filters remain effective with search',
    (tester) async {
      await mount(tester);
      await tester.tap(find.widgetWithText(ListTile, '收藏'));
      await tester.pump();
      expect(names(tester), ['Alpha']);
      await tester.tap(find.widgetWithText(ListTile, '工作'));
      await tester.pump();
      expect(names(tester), ['Zulu']);
      await tester.enterText(find.byType(TextField), 'missing');
      await tester.pump();
      expect(find.text('没有找到匹配的账号'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'custom sort saves from arrow controls and name sort remains available',
    (tester) async {
      await mount(tester);
      expect(names(tester), ['Zulu', 'Alpha']);
      await tester.tap(find.byTooltip('账号排序'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(CheckedPopupMenuItem<String>, '自定义排序'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('下移').first);
      await tester.pump();
      await tester.tap(find.text('保存排序'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pumpAndSettle();
      expect(names(tester), ['Alpha', 'Zulu']);
      expect(store.saved!['settings']['accountSort'], 'custom');
      expect(
        app.settings['accountOrder'],
        app.document!.entries.reversed.map((e) => e.id).toList(),
      );
      await tester.tap(find.byTooltip('账号排序'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(CheckedPopupMenuItem<String>, '名称排序'),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pumpAndSettle();
      expect(app.settings['accountSort'], 'name');
      expect(names(tester), ['Alpha', 'Zulu']);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('cancelled sort does not change saved order', (tester) async {
    await mount(tester);
    await tester.tap(find.byTooltip('账号排序'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithText(CheckedPopupMenuItem<String>, '自定义排序'),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('下移').first);
    await tester.pump();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(names(tester), ['Zulu', 'Alpha']);
    expect(store.saved, isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'clipboard success highlights only the copied row and then clears',
    (tester) async {
      await mount(tester, width: 390);
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final entry = app.document!.entries.first;
      await tester.tap(find.byKey(ValueKey('copy-button-${entry.id}')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(copied, matches(RegExp(r'^\d{6}$')));
      expect(find.text('已复制'), findsOneWidget);
      expect(
        tester.widget<AccountCard>(find.byType(AccountCard).first).copied,
        isTrue,
      );
      expect(
        tester.widget<AccountCard>(find.byType(AccountCard).last).copied,
        isFalse,
      );
      final surface = tester.widget<AnimatedContainer>(
        find.byKey(ValueKey('account-surface-${entry.id}')),
      );
      expect(
        (surface.decoration! as BoxDecoration).color,
        isNot(sixTickTheme(Brightness.light).colorScheme.surface),
      );
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('已复制'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('clipboard always uses the current period at rollover', (
    tester,
  ) async {
    var seconds = 29;
    await mount(tester, width: 390, epochSeconds: () => seconds);
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final entry = app.document!.entries.first;
    await tester.tap(find.byKey(ValueKey('copy-button-${entry.id}')));
    await tester.pump();
    expect(copied, entry.otp.codeAt(29));
    seconds = 30;
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byKey(ValueKey('copy-button-${entry.id}')));
    await tester.pump();
    expect(copied, entry.otp.codeAt(30));
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('failed sort save leaves the previous order intact', (
    tester,
  ) async {
    await mount(tester);
    store.fail = true;
    await tester.tap(find.byTooltip('账号排序'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(CheckedPopupMenuItem<String>, '名称排序'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();
    expect(app.settings['accountSort'], 'custom');
    expect(names(tester), ['Zulu', 'Alpha']);
    expect(find.byType(SnackBar), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
