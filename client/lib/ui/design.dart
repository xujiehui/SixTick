import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Shared visual tokens. All dimensions are logical pixels.
@immutable
class SixTickTokens extends ThemeExtension<SixTickTokens> {
  final Color warning, soft;
  const SixTickTokens({required this.warning, required this.soft});
  @override
  SixTickTokens copyWith({Color? warning, Color? soft}) =>
      SixTickTokens(warning: warning ?? this.warning, soft: soft ?? this.soft);
  @override
  SixTickTokens lerp(SixTickTokens? other, double t) => other == null
      ? this
      : SixTickTokens(
          warning: Color.lerp(warning, other.warning, t)!,
          soft: Color.lerp(soft, other.soft, t)!,
        );
}

ThemeData sixTickTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final background = Color(dark ? 0xff0c1424 : 0xfffcfdff);
  final surface = Color(dark ? 0xff131f33 : 0xffffffff);
  final ink = Color(dark ? 0xffedf4ff : 0xff0b1630);
  final primary = Color(dark ? 0xff78b5ff : 0xff0062ff);
  final soft = Color(dark ? 0xff1d3454 : 0xffe8f3ff);
  final border = Color(dark ? 0xff304762 : 0xffdbe9fa);
  final cs = ColorScheme.fromSeed(seedColor: primary, brightness: brightness)
      .copyWith(
        primary: primary,
        onPrimary: dark ? const Color(0xff071c3b) : Colors.white,
        primaryContainer: soft,
        onPrimaryContainer: primary,
        surface: surface,
        onSurface: ink,
        onSurfaceVariant: Color(dark ? 0xffa9bddb : 0xff536b91),
        surfaceContainerLowest: background,
        surfaceContainerLow: background,
        surfaceContainer: soft,
        surfaceContainerHigh: soft,
        surfaceContainerHighest: border,
        outlineVariant: border,
        outline: Color(dark ? 0xff7d96b8 : 0xff7084a4),
        error: Color(dark ? 0xffffb4ab : 0xffb33c34),
      );
  final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(12));
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: cs,
    brightness: brightness,
  );
  return base.copyWith(
    scaffoldBackgroundColor: background,
    extensions: [
      SixTickTokens(warning: Color(dark ? 0xffedc178 : 0xff895916), soft: soft),
    ],
    visualDensity: VisualDensity.standard,
    materialTapTargetSize: MaterialTapTargetSize.padded,
    textTheme: base.textTheme.copyWith(
      headlineLarge: TextStyle(
        fontSize: 32,
        height: 1.2,
        fontWeight: FontWeight.w700,
        color: ink,
        letterSpacing: -.5,
      ),
      headlineSmall: TextStyle(
        fontSize: 28,
        height: 1.3,
        fontWeight: FontWeight.w600,
        color: ink,
      ),
      titleLarge: TextStyle(
        fontSize: 20,
        height: 1.35,
        fontWeight: FontWeight.w600,
        color: ink,
      ),
      titleMedium: TextStyle(
        fontSize: 18,
        height: 1.4,
        fontWeight: FontWeight.w600,
        color: ink,
      ),
      bodyLarge: TextStyle(fontSize: 16, height: 1.5, color: ink),
      bodyMedium: TextStyle(fontSize: 14, height: 1.5, color: ink),
      bodySmall: TextStyle(
        fontSize: 12,
        height: 1.5,
        color: cs.onSurfaceVariant,
      ),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: background,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
      elevation: 0,
      titleTextStyle: TextStyle(
        color: ink,
        fontSize: 20,
        fontWeight: FontWeight.w700,
      ),
    ),
    cardTheme: CardThemeData(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: border),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: background,
      contentPadding: const EdgeInsets.all(16),
      helperMaxLines: 4,
      errorMaxLines: 4,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: primary, width: 2),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 48),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        shape: shape,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(48, 48),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        shape: shape,
        side: BorderSide(color: border),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(48, 48),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        shape: shape,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
    ),
    chipTheme: base.chipTheme.copyWith(
      side: BorderSide(color: border),
      backgroundColor: surface,
      selectedColor: soft,
      shape: const StadiumBorder(),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: surface,
      indicatorColor: soft,
      indicatorShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          color: states.contains(WidgetState.selected)
              ? primary
              : cs.onSurfaceVariant,
          size: 24,
        ),
      ),
      elevation: 0,
      height: 72,
      labelTextStyle: WidgetStatePropertyAll(
        TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: ink),
      ),
    ),
    dividerTheme: DividerThemeData(color: border, thickness: 1, space: 32),
    dialogTheme: DialogThemeData(
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: surface,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: ink,
      contentTextStyle: TextStyle(color: surface),
      shape: shape,
    ),
    expansionTileTheme: const ExpansionTileThemeData(
      shape: Border(),
      collapsedShape: Border(),
      tilePadding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    ),
  );
}

/// Unboxed six-segment Sky Blue time ring. Geometry matches the SVG master,
/// with tighter framing for in-app display.
class BrandMark extends StatelessWidget {
  final double size;
  const BrandMark({super.key, this.size = 36});
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Align(
      alignment: Alignment.centerLeft,
      widthFactor: 1,
      heightFactor: 1,
      child: SizedBox.square(
        dimension: size,
        child: CustomPaint(painter: _BrandPainter()),
      ),
    ),
  );
}

class _BrandPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 1024);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 146
      ..strokeCap = StrokeCap.round;
    const colors = [
      0xff60caff,
      0xff0062ff,
      0xff268fff,
      0xff0875ff,
      0xff0062ff,
      0xff0054e5,
    ];
    for (var i = 0; i < 6; i++) {
      paint.color = Color(colors[i]);
      canvas.drawArc(
        const Rect.fromLTWH(146, 146, 732, 732),
        (-77 + i * 60) * math.pi / 180,
        34 * math.pi / 180,
        false,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_BrandPainter oldDelegate) => false;
}

/// Offline initials with a stable palette. Service names are labels, not
/// verified identities; no favicon fetch or remote brand lookup is performed.
class ServiceAvatar extends StatelessWidget {
  final String issuer;
  final double size;
  const ServiceAvatar({super.key, required this.issuer, this.size = 56});
  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final name = issuer.trim().toLowerCase();
    final index = switch (name) {
      'github' => 0,
      'figma' => 1,
      'google' => 2,
      'microsoft' => 3,
      _ =>
        name.runes.fold<int>(0, (value, rune) => (value * 31 + rune) & 0xffff) %
            4,
    };
    const lightFill = [0xffe4f2ff, 0xffffebdd, 0xfffff4c4, 0xfff1e2ff];
    const lightInk = [0xff0055cd, 0xff8c3e08, 0xff775100, 0xff7629bc];
    const darkFill = [0xff17395b, 0xff492e23, 0xff413a20, 0xff38234e];
    const darkInk = [0xff91caff, 0xffffbb8b, 0xfff4d679, 0xffd5adff];
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Color(dark ? darkFill[index] : lightFill[index]),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          issuer.isEmpty ? '#' : issuer.characters.first.toUpperCase(),
          style: TextStyle(
            fontSize: size * .52,
            fontWeight: FontWeight.w600,
            color: Color(dark ? darkInk[index] : lightInk[index]),
          ),
        ),
      ),
    );
  }
}

class PageHeading extends StatelessWidget {
  final String title, subtitle;
  final Widget? action;
  const PageHeading({
    super.key,
    required this.title,
    required this.subtitle,
    this.action,
  });
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 24),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.headlineLarge),
              const SizedBox(height: 8),
              Text(
                subtitle,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        if (action != null) ...[const SizedBox(width: 12), action!],
      ],
    ),
  );
}

class PageList extends StatelessWidget {
  final List<Widget> children;
  const PageList({super.key, required this.children});
  @override
  Widget build(BuildContext context) => ListView(
    padding: EdgeInsets.all(MediaQuery.sizeOf(context).width < 600 ? 16 : 32),
    children: children,
  );
}

enum NoticeTone { neutral, success, warning, error }

class StatusNotice extends StatelessWidget {
  final String text;
  final IconData icon;
  final NoticeTone tone;
  const StatusNotice({
    super.key,
    required this.text,
    this.icon = Icons.info_outline,
    this.tone = NoticeTone.neutral,
  });
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context), cs = theme.colorScheme;
    final color = switch (tone) {
      NoticeTone.error => cs.error,
      NoticeTone.warning =>
        theme.extension<SixTickTokens>()?.warning ?? cs.error,
      NoticeTone.success => cs.primary,
      NoticeTone.neutral => cs.onSurfaceVariant,
    };
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(text, style: TextStyle(color: color)),
          ),
        ],
      ),
    );
  }
}

/// A bottom-aligned form on small windows, centered on desktop. The body and
/// action area share a scroll view so the keyboard and large text never trap it.
class AppDialog extends StatelessWidget {
  final Widget? title, content;
  final List<Widget>? actions;
  const AppDialog({super.key, this.title, this.content, this.actions});
  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 840;
    return Dialog(
      alignment: compact ? Alignment.bottomCenter : Alignment.center,
      insetPadding: EdgeInsets.all(compact ? 12 : 40),
      insetAnimationDuration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 180),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: SingleChildScrollView(
          padding: EdgeInsets.all(compact ? 16 : 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (compact)
                Center(
                  child: Container(
                    width: 32,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 24),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.outlineVariant,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              if (title != null) ...[
                Semantics(
                  namesRoute: true,
                  header: true,
                  child: DefaultTextStyle(
                    style: Theme.of(context).textTheme.titleLarge!,
                    child: title!,
                  ),
                ),
                const SizedBox(height: 24),
              ],
              if (content != null) content!,
              if (actions?.isNotEmpty == true) ...[
                const SizedBox(height: 24),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  runSpacing: 8,
                  children: actions!,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class FlowStep extends StatelessWidget {
  final String label;
  final int current, total;
  const FlowStep({
    super.key,
    required this.label,
    required this.current,
    required this.total,
  });
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$current / $total  ·  $label',
          style: TextStyle(
            color: Theme.of(context).colorScheme.primary,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 12),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(value: current / total, minHeight: 4),
        ),
      ],
    ),
  );
}
