import 'dart:io';
import 'package:flutter/services.dart';

/// macOS enforces Touch ID when reading the key, not just in the Flutter UI.
class BiometricKeyStore {
  static const _channel = MethodChannel('six_tick/biometric_key');

  Future<bool> available() async {
    if (!Platform.isMacOS) return false;
    try {
      return await _channel.invokeMethod<bool>('available') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<T?> _invoke<T>(String method, Map<String, dynamic> arguments) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on PlatformException catch (e) {
      throw FormatException(e.code);
    } on MissingPluginException {
      throw const FormatException('biometric_unavailable');
    }
  }

  Future<void> write(String id, List<int> key) =>
      _invoke<void>('write', {'id': id, 'key': Uint8List.fromList(key)});

  Future<List<int>> read(String id) async {
    final key = await _invoke<Uint8List>('read', {'id': id});
    if (key == null || key.length != 32) {
      throw const FormatException('biometric_key_unavailable');
    }
    return key;
  }

  Future<void> delete(String id) => _invoke<void>('delete', {'id': id});
}
