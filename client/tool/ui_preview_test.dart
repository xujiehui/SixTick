// Explicit artifact generator, excluded from the default test/ suite.
// flutter test tool/ui_preview_test.dart --dart-define=PREVIEW_FONT_DIR=/path/to/fonts
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:six_tick/core/document.dart';
import 'package:six_tick/core/totp.dart';
import 'package:six_tick/services/controller.dart';
import 'package:six_tick/services/local_store.dart';
import 'package:six_tick/ui/add_account.dart';
import 'package:six_tick/ui/design.dart';
import 'package:six_tick/ui/gate.dart';
import 'package:six_tick/ui/home.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    const dir = String.fromEnvironment('PREVIEW_FONT_DIR');
    if (dir.isEmpty) {
      throw StateError(
        'Set PREVIEW_FONT_DIR with NotoSansSC.ttf and RobotoMono.ttf. These are preview-only fonts.',
      );
    }
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
    for (final entry in {
      'Preview Sans': 'NotoSansSC.ttf',
      'monospace': 'RobotoMono.ttf',
    }.entries) {
      final loader = FontLoader(entry.key);
      loader.addFont(
        Future.value(
          ByteData.sublistView(await File('$dir/${entry.value}').readAsBytes()),
        ),
      );
      await loader.load();
    }
  });
  testWidgets('export real Flutter screens using a temporary fixture vault', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync('six-tick-preview-');
    final app = AppController(LocalStore(directory));
    app.settings['clearClipboard'] = false;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    app.document = VaultDocument()
        .patch('preview-work-00000001', 'group', {'name': '工作'})
        .patch('preview-personal-0001', 'group', {'name': '个人'});
    const accounts = {
      'GitHub': 'alex.dev',
      'Figma': 'alex@studio.design',
      'Google': 'alex@gmail.com',
      'Microsoft': 'alex@work.com',
    };
    for (final item in accounts.entries) {
      app.document = app.document!.add(
        OtpAccount(
          issuer: item.key,
          account: item.value,
          secret: encodeBase32(
            List.generate(
              20,
              (i) =>
                  (i * 7 + item.key.runes.fold<int>(0, (a, b) => a + b)) % 256,
            ),
          ),
        ),
        favorite: item.key == 'GitHub',
        group: item.key == 'Google'
            ? 'preview-personal-0001'
            : 'preview-work-00000001',
      );
    }
    final boundary = GlobalKey();
    Future<void> capture(
      String name,
      Size size,
      Brightness brightness,
      Widget child, {
      bool copied = false,
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      final theme = sixTickTheme(brightness);
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: theme.copyWith(
              textTheme: theme.textTheme.apply(fontFamily: 'Preview Sans'),
              appBarTheme: theme.appBarTheme.copyWith(
                titleTextStyle: theme.appBarTheme.titleTextStyle?.copyWith(
                  fontFamily: 'Preview Sans',
                ),
              ),
            ),
            locale: const Locale('zh'),
            supportedLocales: const [Locale('zh'), Locale('en')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            home: child,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      if (copied) {
        await tester.tap(
          find.byKey(ValueKey('copy-button-${app.document!.entries.first.id}')),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byIcon(Icons.check_rounded), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final render =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await render.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('../docs/design/$name.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      await tester.pumpWidget(const SizedBox());
    }

    for (final brightness in Brightness.values) {
      final mode = brightness.name;
      await capture(
        'phone-codes-$mode',
        const Size(390, 888),
        brightness,
        HomeScreen(app: app, epochSeconds: () => 1700000022),
      );
      await capture(
        'desktop-codes-$mode',
        const Size(1280, 900),
        brightness,
        HomeScreen(app: app, epochSeconds: () => 1700000022),
      );
    }
    await capture(
      'phone-copied-light',
      const Size(390, 888),
      Brightness.light,
      HomeScreen(app: app, epochSeconds: () => 1700000022),
      copied: true,
    );
    await capture(
      'desktop-copied-light',
      const Size(1060, 800),
      Brightness.light,
      HomeScreen(app: app, epochSeconds: () => 1700000022),
      copied: true,
    );
    for (final page in {1: 'sync', 2: 'security', 3: 'settings'}.entries) {
      await capture(
        'phone-${page.value}',
        const Size(390, 888),
        Brightness.light,
        HomeScreen(
          app: app,
          initialPage: page.key,
          epochSeconds: () => 1700000022,
        ),
      );
    }
    await capture(
      'phone-add',
      const Size(390, 888),
      Brightness.light,
      Scaffold(body: AddAccountDialog(app: app)),
    );
    app.document = null;
    await capture(
      'phone-welcome',
      const Size(390, 888),
      Brightness.light,
      GateScreen(app: app, onRestore: (_) {}),
    );
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    app.dispose();
    directory.deleteSync(recursive: true);
  });
}
