// From client/: dart run tool/generate_icons.dart
// Minimal renderer for the circular SVG master. Uses existing image dependency.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:image/image.dart' as img;

List<int> rgb(String hex) => [
  for (var i = 0; i < 6; i += 2) int.parse(hex.substring(i, i + 2), radix: 16),
];
void write(String path, List<int> bytes) {
  File(path).parent.createSync(recursive: true);
  File(path).writeAsBytesSync(bytes);
}

void text(String path, String value) => write(path, utf8.encode(value));
img.Image resize(img.Image source, int size) => img.copyResize(
  source,
  width: size,
  height: size,
  interpolation: img.Interpolation.average,
);
void main() {
  final svg = File('assets/brand/six-tick.svg').readAsStringSync();
  final background = rgb(
    RegExp(r'fill="#([A-Fa-f0-9]{6})"').firstMatch(svg)!.group(1)!,
  );
  final stroke = double.parse(
    RegExp(r'stroke-width="([\d.]+)"').firstMatch(svg)!.group(1)!,
  );
  final matches = RegExp(
    r'<path d="M ([\d.]+) ([\d.]+) A ([\d.]+) [\d.]+ 0 0 1 ([\d.]+) ([\d.]+)" stroke="#([A-Fa-f0-9]{6})"',
  ).allMatches(svg).toList();
  if (matches.length != 6) throw StateError('Expected six circular SVG paths');
  final arcs = matches.map((m) {
    final x1 = double.parse(m.group(1)!), y1 = double.parse(m.group(2)!);
    final x2 = double.parse(m.group(4)!), y2 = double.parse(m.group(5)!);
    final start = math.atan2(y1 - 512, x1 - 512);
    return (
      x1: x1,
      y1: y1,
      x2: x2,
      y2: y2,
      radius: double.parse(m.group(3)!),
      start: start,
      sweep: (math.atan2(y2 - 512, x2 - 512) - start) % (2 * math.pi),
      color: rgb(m.group(6)!),
    );
  }).toList();
  final square = img.Image(width: 2048, height: 2048, numChannels: 3);
  img.fill(
    square,
    color: img.ColorRgb8(background[0], background[1], background[2]),
  );
  for (var y = 400; y < 1648; y++) {
    for (var x = 400; x < 1648; x++) {
      final px = (x + .5) / 2, py = (y + .5) / 2;
      final radius = math.sqrt(math.pow(px - 512, 2) + math.pow(py - 512, 2));
      if ((radius - 260).abs() > stroke / 2 + 1) continue;
      final angle = math.atan2(py - 512, px - 512);
      for (final arc in arcs) {
        final distance = (angle - arc.start) % (2 * math.pi) <= arc.sweep
            ? (radius - arc.radius).abs()
            : math.min(
                math.sqrt(math.pow(px - arc.x1, 2) + math.pow(py - arc.y1, 2)),
                math.sqrt(math.pow(px - arc.x2, 2) + math.pow(py - arc.y2, 2)),
              );
        if (distance <= stroke / 2) {
          square.setPixelRgb(x, y, arc.color[0], arc.color[1], arc.color[2]);
          break;
        }
      }
    }
  }
  final transparent = square.convert(numChannels: 4);
  for (final pixel in transparent) {
    if (pixel.r == background[0] &&
        pixel.g == background[1] &&
        pixel.b == background[2]) {
      pixel.a = 0;
    }
  }
  final mark = img.copyCrop(
    transparent,
    x: 296,
    y: 296,
    width: 1456,
    height: 1456,
  );
  final rounded = square.convert(numChannels: 4);
  for (final pixel in rounded) {
    final dx = math.max(480 - pixel.x, math.max(pixel.x - 1567, 0));
    final dy = math.max(480 - pixel.y, math.max(pixel.y - 1567, 0));
    if (dx * dx + dy * dy > 480 * 480) pixel.a = 0;
  }
  write('assets/brand/six-tick-mark.png', img.encodePng(resize(mark, 1024)));
  write('assets/brand/six-tick.png', img.encodePng(resize(square, 1024)));
  write(
    'assets/brand/six-tick-rounded.png',
    img.encodePng(resize(rounded, 1024)),
  );
  for (final platform in ['ios', 'macos']) {
    final folder = '$platform/Runner/Assets.xcassets/AppIcon.appiconset';
    final contents =
        jsonDecode(File('$folder/Contents.json').readAsStringSync()) as Map;
    for (final item in contents['images'] as List) {
      final size =
          (double.parse((item['size'] as String).split('x').first) *
                  double.parse((item['scale'] as String).replaceAll('x', '')))
              .round();
      var source = square;
      if (platform == 'macos') {
        source = img.Image(width: 1024, height: 1024, numChannels: 4);
        img.compositeImage(source, resize(rounded, 824), dstX: 100, dstY: 100);
      }
      write('$folder/${item['filename']}', img.encodePng(resize(source, size)));
    }
  }
  const res = 'android/app/src/main/res';
  for (final density in {
    'mdpi': 48,
    'hdpi': 72,
    'xhdpi': 96,
    'xxhdpi': 144,
    'xxxhdpi': 192,
  }.entries) {
    write(
      '$res/mipmap-${density.key}/ic_launcher.png',
      img.encodePng(resize(rounded, density.value)),
    );
  }
  final paths = matches
      .map(
        (m) =>
            '  <path android:fillColor="@android:color/transparent" android:strokeColor="#${m.group(6)}" android:strokeWidth="$stroke" android:strokeLineCap="round" android:pathData="M ${m.group(1)},${m.group(2)} A ${m.group(3)},${m.group(3)} 0,0 1,${m.group(4)},${m.group(5)}"/>',
      )
      .join('\n');
  final fg =
      '<vector xmlns:android="http://schemas.android.com/apk/res/android" android:width="108dp" android:height="108dp" android:viewportWidth="1024" android:viewportHeight="1024">\n$paths\n</vector>\n';
  text('$res/drawable/ic_launcher_foreground.xml', fg);
  text(
    '$res/drawable/ic_launcher_monochrome.xml',
    fg.replaceAll(
      RegExp(r'android:strokeColor="#[A-Fa-f0-9]+"'),
      'android:strokeColor="#FFFFFF"',
    ),
  );
  text(
    '$res/values/brand_colors.xml',
    '<resources>\n  <color name="brand_background">#F7FBFF</color>\n  <color name="launch_background">#FCFDFF</color>\n</resources>\n',
  );
  text(
    '$res/values-night/brand_colors.xml',
    '<resources>\n  <color name="launch_background">#0C1424</color>\n</resources>\n',
  );
  for (final version in [26, 33]) {
    text(
      '$res/mipmap-anydpi-v$version/ic_launcher.xml',
      '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n  <background android:drawable="@color/brand_background"/>\n  <foreground android:drawable="@drawable/ic_launcher_foreground"/>\n${version == 33 ? '  <monochrome android:drawable="@drawable/ic_launcher_monochrome"/>\n' : ''}</adaptive-icon>\n',
    );
  }
  write(
    '$res/drawable-nodpi/launch_mark.png',
    img.encodePng(resize(mark, 192)),
  );
  for (final folder in ['drawable', 'drawable-v21']) {
    text(
      '$res/$folder/launch_background.xml',
      '<layer-list xmlns:android="http://schemas.android.com/apk/res/android">\n  <item android:drawable="@color/launch_background"/>\n  <item android:width="88dp" android:height="88dp" android:gravity="center" android:drawable="@drawable/launch_mark"/>\n</layer-list>\n',
    );
  }
  for (final night in ['', '-night']) {
    text(
      '$res/values$night-v31/styles.xml',
      '<resources>\n  <style name="LaunchTheme" parent="Theme.AppCompat.DayNight.NoActionBar">\n    <item name="android:windowSplashScreenBackground">@color/launch_background</item>\n    <item name="android:windowSplashScreenAnimatedIcon">@mipmap/ic_launcher</item>\n    <item name="android:windowBackground">@drawable/launch_background</item>\n  </style>\n</resources>\n',
    );
  }
  for (var scale = 1; scale <= 3; scale++) {
    final suffix = scale == 1 ? '' : '@${scale}x';
    write(
      'ios/Runner/Assets.xcassets/LaunchImage.imageset/LaunchImage$suffix.png',
      img.encodePng(resize(mark, 88 * scale)),
    );
  }
  text(
    'ios/Runner/Assets.xcassets/LaunchBackground.colorset/Contents.json',
    const JsonEncoder.withIndent('  ').convert({
      'colors': [
        for (final dark in [false, true])
          {
            'idiom': 'universal',
            if (dark)
              'appearances': [
                {'appearance': 'luminosity', 'value': 'dark'},
              ],
            'color': {
              'color-space': 'srgb',
              'components': {
                for (final channel in ['red', 'green', 'blue'].indexed)
                  channel.$2:
                      ((dark ? [12, 20, 36] : [252, 253, 255])[channel.$1] /
                              255)
                          .toStringAsFixed(6),
                'alpha': '1.000',
              },
            },
          },
      ],
      'info': {'author': 'xcode', 'version': 1},
    }),
  );
  write(
    'windows/runner/resources/app_icon.ico',
    img.IcoEncoder().encodeImages([
      for (final size in [16, 24, 32, 48, 64, 128, 256]) resize(rounded, size),
    ]),
  );
  final preview = img.Image(width: 272, height: 96, numChannels: 3);
  img.fill(preview, color: img.ColorRgb8(247, 251, 255));
  var offset = 24;
  for (final size in [16, 32, 48, 64]) {
    img.compositeImage(
      preview,
      resize(rounded, size),
      dstX: offset,
      dstY: (96 - size) ~/ 2,
    );
    offset += size + 16;
  }
  write('../docs/design/icon-sizes.png', img.encodePng(preview));
  stdout.writeln('Generated all platform icons from assets/brand/six-tick.svg');
}
