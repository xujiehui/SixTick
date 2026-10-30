import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:six_tick/core/crypto.dart';
import 'package:six_tick/core/document.dart';
import 'package:six_tick/core/totp.dart';
import 'package:six_tick/services/api.dart';
import 'package:six_tick/services/cloud.dart';

void main() {
  const enabled = bool.fromEnvironment('ALLOW_INSECURE_LOCALHOST');
  late Process server;
  late Directory temp;
  late String url;
  late String mailPath;
  Future<CloudLogin> login([String? device]) async {
    await Api(
      url,
    ).request('POST', '/v1/auth/request', {'email': 'test@example.com'});
    final mail =
        jsonDecode(await File(mailPath).readAsString()) as Map<String, dynamic>;
    return CloudLogin.verify(
      url,
      'test@example.com',
      mail['code'] as String,
      device ?? uuid.v4(),
    );
  }

  setUpAll(() async {
    if (!enabled) return;
    temp = await Directory.systemTemp.createTemp('six-tick-cloud-test-');
    mailPath = '${temp.path}/mail.json';
    // Isolated local fixture: captured mail and a virtual clock, never a live mailbox.
    const fixture = '''
import json,sys,time
from pathlib import Path
from http.server import ThreadingHTTPServer
from server.app import Service,make_handler
clock=[1000.0]
def mail(email,code):
    Path(sys.argv[1]).write_text(json.dumps({'code':code}))
    clock[0]+=61
service=Service(sys.argv[2],b'test-only-pepper-material-32-bytes',mail,lambda:clock[0])
server=ThreadingHTTPServer(('127.0.0.1',0),make_handler(service))
print(server.server_port,flush=True)
server.serve_forever()
''';
    server = await Process.start('python3', [
      '-u',
      '-c',
      fixture,
      mailPath,
      '${temp.path}/server.sqlite',
    ], workingDirectory: '..');
    final output = server.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    final port = await output.first.timeout(const Duration(seconds: 15));
    url = 'http://127.0.0.1:$port';
    server.stderr.drain<void>();
  });
  tearDownAll(() async {
    if (!enabled) return;
    server.kill();
    await server.exitCode;
    await temp.delete(recursive: true);
  });
  test(
    'Dart crypto interoperates with Python authorization, recovery, pairing and CAS',
    () async {
      final owner = await login();
      expect(owner.vault, isNull);
      final keys = CloudKeys.generate(),
          recovery = VaultCrypto.newRecoveryKey();
      var access = owner.access(keys);
      final doc = VaultDocument().add(
        OtpAccount(issuer: 'Integration', secret: 'JBSWY3DPEHPK3PXP'),
      );
      final created = await access.api.request('POST', '/v1/vault/create', {
        ...await access.proof('Owner', 'test'),
        'verifyKey': await keys.publicKey,
        'recovery': await VaultCrypto.seal(
          keys.toJson(),
          VaultCrypto.recoveryKey(recovery),
          'recovery:${owner.accountId}:1',
        ),
        'payload': await access.encrypt(doc),
      });
      access = access.copy(revision: created['revision'] as int);
      final newcomer = await login();
      await expectLater(
        newcomer.api.request('GET', '/v1/vault'),
        throwsA(isA<ApiException>()),
      );
      final recovered = await newcomer.recover(recovery, 'Recovered', 'test');
      final download = await recovered.api.request('GET', '/v1/vault');
      expect(
        (await recovered.decrypt(
          download['payload'] as Map<String, dynamic>,
        )).entries.single.otp.secret,
        'JBSWY3DPEHPK3PXP',
      );
      final third = await login();
      final pairing = await PairRequest.create(third, 'Paired', 'test');
      final info = await PairRequest.inspect(access, pairing.code);
      expect(info['check'], pairing.check);
      expect(await pairing.receive(), isNull);
      await PairRequest.approve(access, pairing.code);
      final pairedKeys = await pairing.receive();
      expect(pairedKeys!.master, keys.master);
      final paired = await third.authorize(pairedKeys, 'Paired', 'test');
      await pairing.consume();
      await expectLater(pairing.receive(), throwsA(isA<ApiException>()));
      final changed = doc.patch(doc.entries.single.id, 'entry', {
        'issuer': 'Updated',
      });
      final request = {
        'requestId': uuid.v4(),
        'epoch': 1,
        'revision': 1,
        'payload': await access.encrypt(
          VaultDocument(
            Map.fromEntries(
              changed.changes.entries.where(
                (e) => !doc.changes.containsKey(e.key),
              ),
            ),
          ),
        ),
      };
      expect(
        (await access.api.request('PUT', '/v1/vault', request))['revision'],
        2,
      );
      expect(
        (await access.api.request('PUT', '/v1/vault', request))['revision'],
        2,
      );
      await expectLater(
        paired.api.request('PUT', '/v1/vault', {
          ...request,
          'requestId': uuid.v4(),
        }),
        throwsA(isA<ApiException>()),
      );
      final incremental = await recovered.api.request(
        'POST',
        '/v1/vault/pull',
        {'epoch': 1, 'revision': 1},
      );
      expect(incremental['payload'], isNull);
      expect(
        (await recovered
                .copy(revision: 1)
                .decryptResponse(incremental, base: doc))
            .entries
            .single
            .otp
            .issuer,
        'Updated',
      );
      final full = await recovered.api.request('GET', '/v1/vault');
      expect(
        (await recovered.decryptResponse(full)).entries.single.otp.issuer,
        'Updated',
      );
      await access.api.request('POST', '/v1/devices/revoke', {
        'deviceId': paired.deviceId,
      });
      await expectLater(
        paired.api.request('GET', '/v1/vault'),
        throwsA(isA<ApiException>()),
      );
      // Server SQLite pages must never contain a TOTP secret or label.
      final raw = await File('${temp.path}/server.sqlite').readAsBytes();
      final disk = latin1.decode(raw);
      expect(disk, isNot(contains('JBSWY3DPEHPK3PXP')));
      expect(disk, isNot(contains('Integration')));
    },
    skip: !enabled
        ? 'Run with --dart-define=ALLOW_INSECURE_LOCALHOST=true to exercise the local Python service.'
        : false,
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
