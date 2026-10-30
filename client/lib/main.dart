import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:window_manager/window_manager.dart';
import 'services/controller.dart';
import 'services/local_store.dart';
import 'ui/gate.dart';
import 'ui/home.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows || Platform.isMacOS) {
    await windowManager.ensureInitialized();
    await windowManager.setMinimumSize(const Size(440, 600));
    await windowManager.setTitle('Six Tick');
  }
  final controller = AppController(await LocalStore.initialize());
  await controller.initialize();
  runApp(SixTickApp(controller: controller));
}

class SixTickApp extends StatefulWidget {
  final AppController controller;
  const SixTickApp({super.key, required this.controller});
  @override
  State<SixTickApp> createState() => _SixTickAppState();
}

class _SixTickAppState extends State<SixTickApp>
    with WidgetsBindingObserver, WindowListener {
  final navigator = GlobalKey<NavigatorState>();
  DateTime lastActivity = DateTime.now();
  DateTime? backgroundAt;
  Timer? idle;
  bool wasLocked = true;
  int initialPage = 0;
  AppController get app => widget.controller;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (Platform.isMacOS || Platform.isWindows) windowManager.addListener(this);
    app.addListener(changed);
    const MethodChannel('six_tick/privacy').setMethodCallHandler((call) async {
      if (call.method == 'systemLocked') app.lock();
    });
    idle = Timer.periodic(const Duration(seconds: 1), (_) {
      if (app.locked) return;
      final seconds = app.settings['lockSeconds'] as int;
      final since = backgroundAt ?? lastActivity;
      if (DateTime.now().difference(since).inMilliseconds >=
          (seconds == 0
              ? (backgroundAt == null ? 60000 : 0)
              : seconds * 1000)) {
        app.lock();
      }
    });
  }

  void changed() {
    if (app.locked && !wasLocked) {
      navigator.currentState?.popUntil((route) => route.isFirst);
    }
    if (!app.locked && wasLocked) {
      lastActivity = DateTime.now();
      backgroundAt = null;
    }
    wasLocked = app.locked;
    if (mounted) setState(() {});
  }

  void activity() {
    lastActivity = DateTime.now();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      final seconds = app.settings['lockSeconds'] as int;
      if (!app.locked &&
          backgroundAt != null &&
          DateTime.now().difference(backgroundAt!).inSeconds >= seconds) {
        app.lock();
      }
      backgroundAt = null;
      activity();
      app.hide(false);
      app.scheduleSync();
    } else {
      // Cover immediately; authentication prompts can briefly cause inactive state.
      app.hide(true);
      if (state == AppLifecycleState.paused ||
          state == AppLifecycleState.hidden) {
        backgroundAt ??= DateTime.now();
        if (app.settings['lockSeconds'] == 0) app.lock();
      }
    }
  }

  @override
  void onWindowBlur() {
    backgroundAt ??= DateTime.now();
    app.hide(true);
  }

  @override
  void onWindowFocus() {
    final seconds = app.settings['lockSeconds'] as int;
    if (!app.locked &&
        backgroundAt != null &&
        DateTime.now().difference(backgroundAt!).inSeconds >= seconds) {
      app.lock();
    }
    backgroundAt = null;
    activity();
    app.hide(false);
    app.scheduleSync();
  }

  @override
  void dispose() {
    idle?.cancel();
    app.removeListener(changed);
    WidgetsBinding.instance.removeObserver(this);
    if (Platform.isMacOS || Platform.isWindows) {
      windowManager.removeListener(this);
    }
    super.dispose();
  }

  ThemeData theme(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xff42634b),
      brightness: brightness,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      brightness: brightness,
      scaffoldBackgroundColor: brightness == Brightness.light
          ? const Color(0xfff7f8f4)
          : const Color(0xff111813),
      appBarTheme: const AppBarTheme(centerTitle: false, elevation: 0),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: .6)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerLowest,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
        ),
      ),
      textTheme: const TextTheme(
        headlineLarge: TextStyle(
          fontWeight: FontWeight.w700,
          letterSpacing: -1.5,
        ),
        headlineSmall: TextStyle(
          fontWeight: FontWeight.w600,
          letterSpacing: -.5,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Six Tick',
    debugShowCheckedModeBanner: false,
    navigatorKey: navigator,
    theme: theme(Brightness.light),
    darkTheme: theme(Brightness.dark),
    themeMode: switch (app.settings['theme']) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    },
    locale: Locale(app.settings['language'] as String),
    supportedLocales: const [Locale('zh'), Locale('en')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    builder: (context, child) => Listener(
      onPointerDown: (_) => activity(),
      onPointerSignal: (_) => activity(),
      child: Focus(
        onKeyEvent: (_, __) {
          activity();
          return KeyEventResult.ignored;
        },
        child: Stack(
          children: [
            child!,
            if (app.privacyHidden)
              Positioned.fill(
                child: ColoredBox(
                  color: Theme.of(context).colorScheme.surface,
                  child: const Center(
                    child: Icon(Icons.shield_outlined, size: 64),
                  ),
                ),
              ),
          ],
        ),
      ),
    ),
    home: app.locked
        ? GateScreen(app: app, onRestore: (page) => initialPage = page)
        : HomeScreen(app: app, initialPage: initialPage),
  );
}
