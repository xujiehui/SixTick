import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:six_tick/core/document.dart';
import 'package:six_tick/core/totp.dart';
import 'package:six_tick/main.dart';
import 'package:six_tick/services/controller.dart';
import 'package:six_tick/services/local_store.dart';
import 'package:six_tick/ui/account_card.dart';
import 'package:six_tick/ui/add_account.dart';
import 'package:six_tick/ui/cloud_page.dart';
import 'package:six_tick/ui/design.dart';
import 'package:six_tick/ui/gate.dart';
import 'package:six_tick/ui/home.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppController app;
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('six-tick-design-');
    app = AppController(LocalStore(directory));
    app.settings['clearClipboard'] = false;
    app.document = VaultDocument().add(
      OtpAccount(
        issuer: 'Example service with a long name',
        account: 'very.long.account.name@example.com',
        secret: 'JBSWY3DPEHPK3PXP',
        digits: 8,
        period: 60,
      ),
    );
  });
  tearDown(() async {
    app.dispose();
    await directory.delete(recursive: true);
  });
  Widget host(
    Widget child, {
    Brightness brightness = Brightness.light,
    double scale = 1,
  }) => MaterialApp(
    theme: sixTickTheme(brightness),
    locale: Locale(app.settings['language'] as String),
    supportedLocales: const [Locale('zh'), Locale('en')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: child,
  );
  void size(WidgetTester tester, Size value) {
    tester.view.physicalSize = value;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  for (final width in [360.0, 390.0, 440.0, 1280.0]) {
    for (final dark in [false, true]) {
      testWidgets(
        'all pages fit $width ${dark ? 'dark English 200%' : 'light Chinese'}',
        (tester) async {
          size(tester, Size(width, width == 440 ? 600 : 844));
          app.settings['language'] = dark ? 'en' : 'zh';
          for (var page = 0; page < 4; page++) {
            await tester.pumpWidget(
              host(
                HomeScreen(key: ValueKey(page), app: app, initialPage: page),
                brightness: dark ? Brightness.dark : Brightness.light,
                scale: dark ? 2 : 1,
              ),
            );
            await tester.pump(const Duration(milliseconds: 250));
            expect(tester.takeException(), isNull, reason: 'page $page');
            final scrollables = find.byType(Scrollable);
            if (page > 0) {
              await tester.drag(scrollables.last, const Offset(0, -500));
              await tester.pump();
              expect(
                tester.takeException(),
                isNull,
                reason: 'scrolled page $page',
              );
            }
          }
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
  testWidgets('copy area copies the current code and never opens edit', (
    tester,
  ) async {
    size(tester, const Size(390, 844));
    String? clipboard;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard = (call.arguments as Map)['text'] as String;
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
    await tester.pumpWidget(host(HomeScreen(app: app)));
    await tester.tap(
      find.byKey(ValueKey('copy-code-${app.document!.entries.first.id}')),
    );
    await tester.pump();
    expect(clipboard, matches(RegExp(r'^\d{8}$')));
    expect(find.byType(AppDialog), findsNothing);
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    expect(find.byIcon(Icons.check_rounded), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'keyboard search from settings returns to codes and Enter copies',
    (tester) async {
      size(tester, const Size(1280, 900));
      String? clipboard;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard = (call.arguments as Map)['text'] as String;
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
      await tester.pumpWidget(host(HomeScreen(app: app, initialPage: 3)));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'Example');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(clipboard, matches(RegExp(r'^\d{8}$')));
      expect(find.byType(AppDialog), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('group manager scrolls through many groups on a narrow screen', (
    tester,
  ) async {
    size(tester, const Size(360, 780));
    for (var i = 0; i < 20; i++) {
      app.document = app.document!.patch(
        'group-id-${i.toString().padLeft(12, '0')}',
        'group',
        {'name': 'Group $i'},
      );
    }
    await tester.pumpWidget(host(HomeScreen(app: app)));
    await tester.ensureVisible(find.byTooltip('管理分组'));
    await tester.tap(find.byTooltip('管理分组'));
    await tester.pumpAndSettle();
    final last = find.descendant(
      of: find.byType(BottomSheet),
      matching: find.text('Group 19'),
    );
    await tester.ensureVisible(last);
    await tester.pump();
    expect(last.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('empty favorites and search provide distinct recovery actions', (
    tester,
  ) async {
    size(tester, const Size(390, 844));
    await tester.pumpWidget(host(HomeScreen(app: app)));
    await tester.tap(find.widgetWithText(ChoiceChip, '收藏'));
    await tester.pump();
    expect(find.text('还没有收藏的账号'), findsOneWidget);
    await tester.tap(find.text('查看全部账号'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'absent');
    await tester.pump();
    expect(find.text('没有找到匹配的账号'), findsOneWidget);
    await tester.tap(find.text('清除搜索'));
    await tester.pump();
    expect(find.byType(AccountCard), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('narrow form with keyboard and 200% text remains scrollable', (
    tester,
  ) async {
    size(tester, const Size(360, 780));
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetViewInsets);
    app.settings['language'] = 'en';
    await tester.pumpWidget(
      host(Scaffold(body: AddAccountDialog(app: app)), scale: 2),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('Save account'));
    await tester.pump();
    expect(find.text('Save account').hitTestable(), findsOneWidget);
    expect(app.document!.entries.length, 1);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('welcome and setup fit 200% text', (tester) async {
    size(tester, const Size(360, 780));
    app.document = null;
    app.settings['language'] = 'en';
    await tester.pumpWidget(
      host(GateScreen(app: app, onRestore: (_) {}), scale: 2),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('Create local vault'));
    await tester.tap(find.text('Create local vault'));
    await tester.pump();
    expect(find.text('Secure this device first'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('cloud wizard fits narrow windows with large text', (
    tester,
  ) async {
    size(tester, const Size(360, 780));
    app.settings['language'] = 'en';
    await tester.pumpWidget(
      host(Scaffold(body: CloudWizard(app: app)), scale: 2),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('Close'));
    expect(find.text('Close').hitTestable(), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('sync errors and offline states remain understandable', (
    tester,
  ) async {
    size(tester, const Size(390, 844));
    for (final status in ['offline', 'error', 'reauth', 'syncing', 'synced']) {
      app.syncStatus = status;
      await tester.pumpWidget(
        host(HomeScreen(key: ValueKey(status), app: app, initialPage: 1)),
      );
      expect(find.byType(StatusNotice), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'privacy cover removes account semantics and lock dismisses dialogs',
    (tester) async {
      size(tester, const Size(390, 844));
      final semantics = tester.ensureSemantics();
      bool hasAccountSemantics() {
        bool found = false;
        void visit(SemanticsNode node) {
          if (node.label.contains('Example service with a long name')) {
            found = true;
          }
          node.visitChildren((child) {
            visit(child);
            return true;
          });
        }

        tester.binding.rootPipelineOwner.visitChildren((owner) {
          final root = owner.semanticsOwner?.rootSemanticsNode;
          if (root != null) visit(root);
        });
        return found;
      }

      await tester.pumpWidget(SixTickApp(controller: app));
      expect(hasAccountSemantics(), isTrue);
      app.hide(true);
      await tester.pump();
      expect(hasAccountSemantics(), isFalse);
      app.hide(false);
      await tester.pump();
      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('账号详情 / 编辑'));
      await tester.pumpAndSettle();
      expect(find.byType(AppDialog), findsOneWidget);
      app.lock();
      await tester.pumpAndSettle();
      expect(find.byType(AppDialog), findsNothing);
      expect(find.byType(AccountCard), findsNothing);
      expect(find.byType(GateScreen), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      semantics.dispose();
    },
  );
}
