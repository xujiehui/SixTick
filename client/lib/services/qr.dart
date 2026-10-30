import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:zxing2/qrcode.dart';

Future<List<String>> readQrImage(Uint8List bytes) => compute(_decode, bytes);

List<String> _decode(Uint8List bytes) {
  if (bytes.length > 12 * 1024 * 1024) {
    throw const FormatException('file_too_large');
  }
  final decoder = img.findDecoderForData(bytes);
  final info = decoder?.startDecode(bytes);
  if (info == null || info.width * info.height > 24000000) {
    throw const FormatException('invalid_image');
  }
  final decoded = decoder!.decodeFrame(0);
  if (decoded == null) throw const FormatException('invalid_image');
  final source = decoded.width > 3000 || decoded.height > 3000
      ? img.copyResize(
          decoded,
          width: decoded.width >= decoded.height ? 3000 : null,
          height: decoded.height > decoded.width ? 3000 : null,
        )
      : decoded;
  final found = <String>{}, visited = <String>{};
  var attempts = 0;
  void scan(int x, int y, int width, int height, int depth) {
    if (width < 40 ||
        height < 40 ||
        depth > 8 ||
        attempts++ > 100 ||
        !visited.add('$x:$y:$width:$height')) {
      return;
    }
    final crop = img.copyCrop(source, x: x, y: y, width: width, height: height);
    final pixels = Int32List(width * height);
    var offset = 0;
    for (final p in crop) {
      pixels[offset++] = (p.r.toInt() << 16) | (p.g.toInt() << 8) | p.b.toInt();
    }
    try {
      final result = QRCodeReader().decode(
        BinaryBitmap(
          HybridBinarizer(RGBLuminanceSource(width, height, pixels)),
        ),
      );
      found.add(result.text);
      final points = result.resultPoints;
      if (points.isEmpty) return;
      final xs = points.map((p) => p.x).toList()..sort();
      final ys = points.map((p) => p.y).toList()..sort();
      final left = xs.first.floor().clamp(0, width),
          top = ys.first.floor().clamp(0, height);
      final right = xs.last.ceil().clamp(0, width),
          bottom = ys.last.ceil().clamp(0, height);
      scan(x, y, left, height, depth + 1);
      scan(x + right, y, width - right, height, depth + 1);
      scan(x, y, width, top, depth + 1);
      scan(x, y + bottom, width, height - bottom, depth + 1);
    } on ReaderException {
      if (depth < 2) {
        scan(x, y, width ~/ 2 + width ~/ 8, height, depth + 1);
        scan(x + width * 3 ~/ 8, y, width - width * 3 ~/ 8, height, depth + 1);
        scan(x, y, width, height ~/ 2 + height ~/ 8, depth + 1);
        scan(
          x,
          y + height * 3 ~/ 8,
          width,
          height - height * 3 ~/ 8,
          depth + 1,
        );
      }
    }
  }

  scan(0, 0, source.width, source.height, 0);
  if (found.isEmpty) throw const FormatException('qr_not_found');
  return found.toList();
}
