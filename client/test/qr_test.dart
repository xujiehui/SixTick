import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:qr/qr.dart';
import 'package:six_tick/services/qr.dart';

img.Image qr(String text) {
  final matrix = QrImage(
    QrCode.fromData(data: text, errorCorrectLevel: QrErrorCorrectLevel.M),
  );
  final image = img.Image(
    width: (matrix.moduleCount + 8) * 6,
    height: (matrix.moduleCount + 8) * 6,
  );
  img.fill(image, color: img.ColorRgb8(255, 255, 255));
  for (var y = 0; y < matrix.moduleCount; y++) {
    for (var x = 0; x < matrix.moduleCount; x++) {
      if (matrix.isDark(y, x)) {
        img.fillRect(
          image,
          x1: (x + 4) * 6,
          y1: (y + 4) * 6,
          x2: (x + 5) * 6 - 1,
          y2: (y + 5) * 6 - 1,
          color: img.ColorRgb8(0, 0, 0),
        );
      }
    }
  }
  return image;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('decode a provisioning QR without sending the image anywhere', () async {
    const text =
        'otpauth://totp/Example:alice?secret=JBSWY3DPEHPK3PXP&issuer=Example';
    expect(await readQrImage(Uint8List.fromList(img.encodePng(qr(text)))), [
      text,
    ]);
  });
  test('multiple QR codes in one image are all offered', () async {
    const one = 'otpauth://totp/One?secret=JBSWY3DPEHPK3PXP';
    const two = 'otpauth://totp/Two?secret=JBSWY3DPEHPK3PXP';
    final a = qr(one), b = qr(two);
    final image = img.Image(
      width: a.width + b.width + 60,
      height: a.height + 40,
    );
    img.fill(image, color: img.ColorRgb8(255, 255, 255));
    img.compositeImage(image, a, dstX: 10, dstY: 10);
    img.compositeImage(image, b, dstX: a.width + 40, dstY: 10);
    expect(
      await readQrImage(Uint8List.fromList(img.encodePng(image))),
      unorderedEquals([one, two]),
    );
  });
}
