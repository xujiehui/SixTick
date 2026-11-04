import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:six_tick/ui/design.dart';

void main() {
  test('every Apple icon matches its catalog and iOS is fully opaque', () {
    for (final platform in ['ios', 'macos']) {
      final folder = '$platform/Runner/Assets.xcassets/AppIcon.appiconset';
      final catalog =
          jsonDecode(File('$folder/Contents.json').readAsStringSync()) as Map;
      for (final entry in catalog['images'] as List) {
        final expected =
            (double.parse((entry['size'] as String).split('x').first) *
                    double.parse(
                      (entry['scale'] as String).replaceAll('x', ''),
                    ))
                .round();
        final image = img.decodePng(
          File('$folder/${entry['filename']}').readAsBytesSync(),
        )!;
        expect(image.width, expected);
        expect(image.height, expected);
        if (platform == 'ios') expect(image.numChannels, 3);
      }
    }
  });
  test('Windows contains all seven icon sizes and Android densities match', () {
    final ico = img.decodeIco(
      File('windows/runner/resources/app_icon.ico').readAsBytesSync(),
    )!;
    expect(ico.frames.map((frame) => frame.width), [
      16,
      24,
      32,
      48,
      64,
      128,
      256,
    ]);
    for (final density in {
      'mdpi': 48,
      'hdpi': 72,
      'xhdpi': 96,
      'xxhdpi': 144,
      'xxxhdpi': 192,
    }.entries) {
      final image = img.decodePng(
        File(
          'android/app/src/main/res/mipmap-${density.key}/ic_launcher.png',
        ).readAsBytesSync(),
      )!;
      expect(image.width, density.value);
      expect(image.height, density.value);
    }
  });
  test('Android adaptive foreground remains inside the 66dp safe circle', () {
    final vector = File(
      'android/app/src/main/res/drawable/ic_launcher_foreground.xml',
    ).readAsStringSync();
    final stroke = double.parse(
      RegExp(r'android:strokeWidth="([\d.]+)"').firstMatch(vector)!.group(1)!,
    );
    final radii = RegExp(r' A ([\d.]+),').allMatches(vector);
    expect(radii.length, 6);
    for (final radius in radii) {
      expect(
        (double.parse(radius.group(1)!) + stroke / 2) * 108 / 1024,
        lessThanOrEqualTo(33),
      );
    }
    final v33 = File(
      'android/app/src/main/res/mipmap-anydpi-v33/ic_launcher.xml',
    ).readAsStringSync();
    expect(v33, contains('@drawable/ic_launcher_monochrome'));
  });
  test('primary and secondary text meets AA in both themes', () {
    double ratio(Color a, Color b) {
      final la = a.computeLuminance(), lb = b.computeLuminance();
      return la > lb ? (la + .05) / (lb + .05) : (lb + .05) / (la + .05);
    }

    for (final brightness in Brightness.values) {
      final theme = sixTickTheme(brightness), cs = theme.colorScheme;
      for (final background in [cs.surface, theme.scaffoldBackgroundColor]) {
        for (final text in [cs.primary, cs.onSurface, cs.onSurfaceVariant]) {
          expect(ratio(text, background), greaterThanOrEqualTo(4.5));
        }
      }
      expect(ratio(cs.primary, cs.onPrimary), greaterThanOrEqualTo(4.5));
      final warning = theme.extension<SixTickTokens>()!.warning;
      expect(
        ratio(
          warning,
          Color.alphaBlend(warning.withValues(alpha: .08), cs.surface),
        ),
        greaterThanOrEqualTo(4.5),
      );
    }
  });
}
