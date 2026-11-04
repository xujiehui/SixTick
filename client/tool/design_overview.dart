// From client/: dart run tool/design_overview.dart (after UI preview export).
import 'dart:io';
import 'package:image/image.dart' as img;

void main() {
  final canvas = img.Image(width: 1672, height: 960, numChannels: 3);
  img.fill(canvas, color: img.ColorRgb8(240, 248, 255));
  final ink = img.ColorRgb8(11, 22, 48), muted = img.ColorRgb8(83, 107, 145);
  final mark = img.decodePng(
    File('assets/brand/six-tick-mark.png').readAsBytesSync(),
  )!;
  img.compositeImage(
    canvas,
    img.copyResize(mark, width: 80, interpolation: img.Interpolation.average),
    dstX: 32,
    dstY: 36,
  );
  img.drawString(
    canvas,
    'Six Tick 2.0',
    font: img.arial48,
    x: 136,
    y: 40,
    color: ink,
  );
  img.drawString(
    canvas,
    'SKY BLUE',
    font: img.arial24,
    x: 472,
    y: 58,
    color: img.ColorRgb8(0, 98, 255),
  );
  img.drawString(
    canvas,
    'Offline first. Always yours.',
    font: img.arial24,
    x: 140,
    y: 108,
    color: muted,
  );
  void place(String name, String label, int x, int width) {
    final source = img.decodePng(
      File('../docs/design/$name.png').readAsBytesSync(),
    )!;
    img.drawString(
      canvas,
      label,
      font: img.arial14,
      x: x,
      y: 164,
      color: muted,
    );
    img.compositeImage(
      canvas,
      img.copyResize(
        source,
        width: width,
        interpolation: img.Interpolation.average,
      ),
      dstX: x,
      dstY: 190,
    );
  }

  place('desktop-copied-light', 'Desktop / Sky Blue', 32, 936);
  place('phone-codes-light', 'Mobile / Default', 988, 310);
  place('phone-copied-light', 'Mobile / Copied', 1318, 310);
  img.drawString(
    canvas,
    'ACTUAL FLUTTER UI / TEST ACCOUNTS ONLY',
    font: img.arial14,
    x: 1270,
    y: 932,
    color: muted,
  );
  File('../docs/design/overview.png').writeAsBytesSync(img.encodePng(canvas));
}
