import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:crypto/crypto.dart' as hashes;
import '../core/crypto.dart';
import '../core/document.dart';
import 'api.dart';

class CloudKeys {
  final List<int> master, signing;
  CloudKeys(this.master, this.signing) {
    if (master.length != 32 || signing.length != 32) {
      throw const FormatException('corrupt_data');
    }
  }
  factory CloudKeys.generate() =>
      CloudKeys(VaultCrypto.randomBytes(32), VaultCrypto.randomBytes(32));
  factory CloudKeys.fromJson(Map<String, dynamic> data) {
    if (data['version'] != 1) {
      throw const FormatException('unsupported_version');
    }
    return CloudKeys(
      base64Decode(data['master'] as String),
      base64Decode(data['signing'] as String),
    );
  }
  Map<String, dynamic> toJson() => {
    'version': 1,
    'master': base64Encode(master),
    'signing': base64Encode(signing),
  };
  Future<SimpleKeyPair> get keyPair => Ed25519().newKeyPairFromSeed(signing);
  Future<String> get publicKey async =>
      base64Encode((await (await keyPair).extractPublicKey()).bytes);
  SecretKey get encryptionKey => SecretKey(master);
}

class CloudAccess {
  final String url, email, token, accountId, challenge, deviceId;
  final CloudKeys keys;
  final int epoch, revision;
  final bool enabled;
  final Set<String> confirmed;
  CloudAccess({
    required this.url,
    required this.email,
    required this.token,
    required this.accountId,
    required this.challenge,
    required this.deviceId,
    required this.keys,
    required this.epoch,
    required this.revision,
    this.enabled = true,
    this.confirmed = const {},
  });
  factory CloudAccess.fromJson(Map<String, dynamic> d) => CloudAccess(
    url: d['url'] as String,
    email: d['email'] as String,
    token: d['token'] as String,
    accountId: d['accountId'] as String,
    challenge: d['challenge'] as String,
    deviceId: d['deviceId'] as String,
    keys: CloudKeys.fromJson(d['keys'] as Map<String, dynamic>),
    epoch: d['epoch'] as int,
    revision: d['revision'] as int,
    enabled: d['enabled'] as bool,
    confirmed: (d['confirmed'] as List? ?? []).cast<String>().toSet(),
  );
  Map<String, dynamic> toJson() => {
    'url': url,
    'email': email,
    'token': token,
    'accountId': accountId,
    'challenge': challenge,
    'deviceId': deviceId,
    'keys': keys.toJson(),
    'epoch': epoch,
    'revision': revision,
    'enabled': enabled,
    'confirmed': confirmed.toList(),
  };
  CloudAccess copy({
    int? revision,
    int? epoch,
    CloudKeys? keys,
    bool? enabled,
    Set<String>? confirmed,
  }) => CloudAccess(
    url: url,
    email: email,
    token: token,
    accountId: accountId,
    challenge: challenge,
    deviceId: deviceId,
    keys: keys ?? this.keys,
    epoch: epoch ?? this.epoch,
    revision: revision ?? this.revision,
    enabled: enabled ?? this.enabled,
    confirmed: confirmed ?? this.confirmed,
  );
  Api get api => Api(url, token: token);
  Future<Map<String, dynamic>> proof(String name, String platform) async {
    final message =
        'six-tick:authorize:v1:$accountId:$challenge:$deviceId:$epoch';
    final signature = await Ed25519().sign(
      utf8.encode(message),
      keyPair: await keys.keyPair,
    );
    return {
      'deviceId': deviceId,
      'name': name,
      'platform': platform,
      'signature': base64Encode(signature.bytes),
    };
  }

  Future<Map<String, dynamic>> encrypt(VaultDocument doc) => VaultCrypto.seal(
    doc.toJson(),
    keys.encryptionKey,
    'vault:$accountId:$epoch',
  );
  Future<VaultDocument> decrypt(Map<String, dynamic> payload) async =>
      VaultDocument.fromJson(
        await VaultCrypto.open(
          payload,
          keys.encryptionKey,
          'vault:$accountId:$epoch',
        ),
      );
  Future<VaultDocument> decryptResponse(
    Map<String, dynamic> data, {
    VaultDocument? base,
  }) async {
    if (data['epoch'] != epoch) throw const FormatException('device_revoked');
    var doc = data['payload'] != null
        ? await decrypt(data['payload'] as Map<String, dynamic>)
        : (base ?? VaultDocument());
    var cursor = data['payload'] != null
        ? data['baseRevision'] as int
        : revision;
    for (final patch in data['patches'] as List) {
      if (patch['revision'] != cursor + 1) {
        throw const FormatException('corrupt_data');
      }
      final raw = await VaultCrypto.open(
        patch['payload'] as Map<String, dynamic>,
        keys.encryptionKey,
        'vault:$accountId:$epoch',
      );
      if (raw['version'] != 1 ||
          raw['changes'] is! List ||
          (raw['changes'] as List).length > 50000) {
        throw const FormatException('unsupported_version');
      }
      final changes = <String, Change>{};
      for (final value in raw['changes'] as List) {
        final change = Change.fromJson(Map<String, dynamic>.from(value as Map));
        if (changes.containsKey(change.id)) {
          throw const FormatException('corrupt_data');
        }
        changes[change.id] = change;
      }
      doc = doc.merge(VaultDocument(changes));
      cursor++;
    }
    if (cursor != data['revision']) throw const FormatException('corrupt_data');
    return doc;
  }
}

class CloudLogin {
  final String url, email, token, accountId, challenge, deviceId;
  final Map<String, dynamic>? vault;
  CloudLogin(
    this.url,
    this.email,
    this.token,
    this.accountId,
    this.challenge,
    this.deviceId,
    this.vault,
  );
  Api get api => Api(url, token: token);
  static Future<CloudLogin> verify(
    String url,
    String email,
    String code,
    String deviceId,
  ) async {
    final login = await Api(
      url,
    ).request('POST', '/v1/auth/verify', {'email': email, 'code': code});
    final api = Api(url, token: login['token'] as String);
    final info = await api.request('GET', '/v1/vault/info');
    return CloudLogin(
      url,
      email.trim().toLowerCase(),
      login['token'] as String,
      login['accountId'] as String,
      login['challenge'] as String,
      deviceId,
      info['vault'] as Map<String, dynamic>?,
    );
  }

  CloudAccess access(CloudKeys keys) => CloudAccess(
    url: url,
    email: email,
    token: token,
    accountId: accountId,
    challenge: challenge,
    deviceId: deviceId,
    keys: keys,
    epoch: vault?['epoch'] as int? ?? 1,
    revision: vault?['revision'] as int? ?? 0,
  );
  Future<CloudAccess> recover(
    String recovery,
    String name,
    String platform,
  ) async {
    if (vault == null) throw const FormatException('vault_missing');
    final keys = CloudKeys.fromJson(
      await VaultCrypto.open(
        vault!['recovery'] as Map<String, dynamic>,
        VaultCrypto.recoveryKey(recovery),
        'recovery:$accountId:${vault!['epoch']}',
      ),
    );
    return authorize(keys, name, platform);
  }

  Future<CloudAccess> authorize(
    CloudKeys keys,
    String name,
    String platform,
  ) async {
    if (await keys.publicKey != vault?['verifyKey']) {
      throw const FormatException('decryption_failed');
    }
    final a = access(keys);
    await api.request(
      'POST',
      '/v1/devices/authorize',
      await a.proof(name, platform),
    );
    return a;
  }
}

class PairRequest {
  final CloudLogin login;
  final SimpleKeyPair keyPair;
  final String id, publicKey;
  PairRequest(this.login, this.keyPair, this.id, this.publicKey);
  String get code => '$id.$publicKey';
  String get check => hashes.sha256
      .convert(utf8.encode(code))
      .toString()
      .substring(0, 8)
      .toUpperCase();
  static Future<PairRequest> create(
    CloudLogin login,
    String name,
    String platform,
  ) async {
    final keys = await X25519().newKeyPair();
    final public = base64Encode((await keys.extractPublicKey()).bytes);
    final result = await login.api.request('POST', '/v1/pairings', {
      'publicKey': public,
      'deviceId': login.deviceId,
      'name': name,
      'platform': platform,
    });
    return PairRequest(login, keys, result['id'] as String, public);
  }

  Future<CloudKeys?> receive() async {
    final response = await login.api.request('GET', '/v1/pairings/$id');
    if (response['ready'] != true) return null;
    final payload = response['payload'] as Map<String, dynamic>;
    final shared = await X25519().sharedSecretKey(
      keyPair: keyPair,
      remotePublicKey: SimplePublicKey(
        base64Decode(payload['publicKey'] as String),
        type: KeyPairType.x25519,
      ),
    );
    final key = await _pairKey(shared, id);
    return CloudKeys.fromJson(
      await VaultCrypto.open(
        payload['box'] as Map<String, dynamic>,
        key,
        'pair:$id',
      ),
    );
  }

  Future<void> consume() => login.api.request('DELETE', '/v1/pairings/$id');
  static Future<Map<String, dynamic>> inspect(
    CloudAccess access,
    String code,
  ) async {
    final parts = code.trim().split('.');
    if (parts.length != 2) throw const FormatException('invalid_pairing');
    final result = await access.api.request('GET', '/v1/pairings/${parts[0]}');
    if (result['publicKey'] != parts[1]) {
      throw const FormatException('pairing_mismatch');
    }
    return {
      ...result,
      'check': hashes.sha256
          .convert(utf8.encode(code.trim()))
          .toString()
          .substring(0, 8)
          .toUpperCase(),
    };
  }

  static Future<void> approve(CloudAccess access, String code) async {
    final info = await inspect(access, code);
    final id = info['id'] as String;
    final ephemeral = await X25519().newKeyPair();
    final shared = await X25519().sharedSecretKey(
      keyPair: ephemeral,
      remotePublicKey: SimplePublicKey(
        base64Decode(info['publicKey'] as String),
        type: KeyPairType.x25519,
      ),
    );
    final payload = {
      'publicKey': base64Encode((await ephemeral.extractPublicKey()).bytes),
      'box': await VaultCrypto.seal(
        access.keys.toJson(),
        await _pairKey(shared, id),
        'pair:$id',
      ),
    };
    await access.api.request('PUT', '/v1/pairings/$id', {'payload': payload});
  }

  static Future<SecretKey> _pairKey(SecretKey shared, String id) =>
      Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
        secretKey: shared,
        nonce: utf8.encode('six-tick:pair:v1'),
        info: utf8.encode(id),
      );
}
