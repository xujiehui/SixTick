import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../core/crypto.dart';
import '../core/document.dart';
import '../core/totp.dart';
import 'api.dart';
import 'cloud.dart';
import 'local_store.dart';

class AppController extends ChangeNotifier {
  final LocalStore store;
  VaultDocument? document;
  CloudAccess? cloud;
  Map<String, dynamic> settings = {
    'theme': 'system',
    'language': 'zh',
    'lockSeconds': 60,
    'clearClipboard': true,
  };
  String deviceId = uuid.v4(), syncStatus = 'disabled';
  DateTime? lastSync;
  bool exists = false, privacyHidden = false;
  int _generation = 0;
  Future<void> _queue = Future.value();
  Timer? _syncTimer, _poll;
  bool _syncing = false;
  AppController(this.store);
  bool get locked => document == null;
  String get platform => Platform.operatingSystem;
  String get deviceName => 'Six Tick · $platform';
  Future<void> initialize() async {
    exists = await store.exists;
    notifyListeners();
  }

  Map<String, dynamic> _data(
    VaultDocument doc,
    CloudAccess? access,
    Map<String, dynamic> prefs,
  ) => {
    'version': 1,
    'document': doc.toJson(),
    'cloud': access?.toJson(),
    'settings': prefs,
    'deviceId': deviceId,
    'lastSync': lastSync?.toUtc().toIso8601String(),
  };

  Future<T> serial<T>(Future<T> Function() work) {
    final completer = Completer<T>();
    final generation = _generation;
    _queue = _queue.then((_) async {
      if (generation != _generation || locked) {
        completer.completeError(const FormatException('locked'));
        return;
      }
      try {
        completer.complete(await work());
      } catch (e, s) {
        completer.completeError(e, s);
      }
    });
    return completer.future;
  }

  Future<void> _commit(
    VaultDocument doc,
    CloudAccess? access, {
    Map<String, dynamic>? prefs,
  }) async {
    final generation = _generation;
    await store.save(_data(doc, access, prefs ?? settings));
    if (generation != _generation) return;
    document = doc;
    cloud = access;
    settings = prefs ?? settings;
    notifyListeners();
  }

  Future<void> create({String? password}) async {
    final doc = VaultDocument();
    await store.create(_data(doc, null, settings), password: password);
    document = doc;
    exists = true;
    _generation++;
    notifyListeners();
    _startPolling();
  }

  Future<void> unlock({String? password}) async {
    final generation = _generation;
    await _queue;
    final plain = await store.unlock(password: password);
    if (generation != _generation) {
      store.lock();
      return;
    }
    try {
      if (plain['version'] != 1) {
        throw const FormatException('unsupported_version');
      }
      final doc = VaultDocument.fromJson(
        plain['document'] as Map<String, dynamic>,
      );
      final access = plain['cloud'] == null
          ? null
          : CloudAccess.fromJson(plain['cloud'] as Map<String, dynamic>);
      document = doc;
      cloud = access;
      settings = {...settings, ...plain['settings'] as Map<String, dynamic>};
      deviceId = plain['deviceId'] as String;
      lastSync = plain['lastSync'] == null
          ? null
          : DateTime.parse(plain['lastSync'] as String);
      syncStatus = access?.enabled == true ? 'pending' : 'disabled';
      privacyHidden = false;
      notifyListeners();
      _startPolling();
      scheduleSync();
    } catch (_) {
      lock();
      rethrow;
    }
  }

  void lock() {
    _generation++;
    document = null;
    cloud = null;
    store.lock();
    _syncTimer?.cancel();
    _poll?.cancel();
    privacyHidden = false;
    notifyListeners();
  }

  void hide(bool value) {
    privacyHidden = value;
    notifyListeners();
  }

  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 4), (_) {
      if (!privacyHidden) sync();
    });
  }

  Future<void> mutate(VaultDocument Function(VaultDocument) change) =>
      serial(() async {
        await _commit(change(document!), cloud);
        scheduleSync();
      });
  Future<void> add(OtpAccount otp, String? group) =>
      mutate((d) => d.add(otp, group: group));
  Future<void> edit(RecordView record, Map<String, dynamic> fields) =>
      mutate((d) => d.patch(record.id, record.kind, fields));
  Future<void> delete(RecordView record) =>
      mutate((d) => d.patch(record.id, record.kind, {}, deleted: true));
  Future<void> addGroup(String name) =>
      mutate((d) => d.patch(uuid.v4(), 'group', {'name': name.trim()}));
  Future<void> importBackup(Map<String, dynamic> data, bool keepDuplicates) =>
      mutate((d) => d.importBackup(data, keepDuplicates: keepDuplicates));
  Future<void> preferences(Map<String, dynamic> values) =>
      serial(() => _commit(document!, cloud, prefs: {...settings, ...values}));
  void scheduleSync() {
    if (cloud?.enabled != true || locked) return;
    syncStatus = 'pending';
    notifyListeners();
    _syncTimer?.cancel();
    _syncTimer = Timer(const Duration(milliseconds: 300), sync);
  }

  Future<void> sync() async {
    if (_syncing || locked || cloud?.enabled != true || privacyHidden) return;
    _syncing = true;
    final generation = _generation;
    syncStatus = 'syncing';
    notifyListeners();
    bool active(CloudAccess access) =>
        generation == _generation &&
        !locked &&
        cloud?.enabled == true &&
        cloud?.accountId == access.accountId &&
        cloud?.epoch == access.epoch;
    try {
      for (var attempt = 0; attempt < 4; attempt++) {
        if (generation != _generation || cloud?.enabled != true) return;
        final access = cloud!;
        // Network waits never hold the local mutation queue: offline edits save immediately.
        final remote = await access.api.request('POST', '/v1/vault/pull', {
          'epoch': access.epoch,
          'revision': access.revision,
        });
        if (!active(access)) return;
        if (remote['epoch'] != access.epoch) {
          throw const ApiException('device_revoked', 403);
        }
        if ((remote['revision'] as int) < access.revision) {
          throw const FormatException('cloud_rollback');
        }
        final confirmedBase = VaultDocument(
          Map.fromEntries(
            document!.changes.entries.where(
              (e) => access.confirmed.contains(e.key),
            ),
          ),
        );
        final remoteDoc = await access.decryptResponse(
          remote,
          base: confirmedBase,
        );
        if (!active(access)) return;
        final snapshot = await serial<(VaultDocument, CloudAccess)>(() async {
          if (!active(access)) throw const FormatException('locked');
          final merged = document!.merge(remoteDoc);
          final next = cloud!.copy(
            revision: remote['revision'] as int,
            confirmed: remoteDoc.changes.keys.toSet(),
          );
          if (canonical(document!.toJson()) != canonical(merged.toJson()) ||
              cloud!.revision != next.revision) {
            await _commit(merged, next);
          }
          return (merged, next);
        });
        if (!active(access)) return;
        final merged = snapshot.$1, next = snapshot.$2;
        if (merged.changes.length == remoteDoc.changes.length) {
          lastSync = DateTime.now();
          syncStatus = document!.changes.length == merged.changes.length
              ? 'synced'
              : 'pending';
          return;
        }
        final delta = VaultDocument(
          Map.fromEntries(
            merged.changes.entries.where(
              (e) => !next.confirmed.contains(e.key),
            ),
          ),
        );
        final payload = await next.encrypt(delta);
        if (!active(access)) return;
        try {
          final response = await next.api.request('PUT', '/v1/vault', {
            'requestId': uuid.v4(),
            'epoch': next.epoch,
            'revision': next.revision,
            'payload': payload,
          });
          if (!active(access)) return;
          await serial(() async {
            if (!active(access)) return;
            lastSync = DateTime.now();
            // Edits made while the upload was in flight remain in the persisted document.
            await _commit(
              document!,
              cloud!.copy(
                revision: response['revision'] as int,
                confirmed: merged.changes.keys.toSet(),
              ),
            );
            if (active(access)) {
              syncStatus = document!.changes.length == merged.changes.length
                  ? 'synced'
                  : 'pending';
            }
          });
          return;
        } on ApiException catch (e) {
          if (e.code != 'sync_conflict') rethrow;
        }
      }
      syncStatus = 'conflict';
    } on ApiException catch (e) {
      if (generation == _generation) {
        syncStatus = ['unauthorized', 'device_revoked'].contains(e.code)
            ? 'reauth'
            : 'error';
      }
    } on SocketException {
      if (generation == _generation) syncStatus = 'offline';
    } catch (_) {
      if (generation == _generation) syncStatus = 'error';
    } finally {
      _syncing = false;
      if (generation == _generation) {
        notifyListeners();
        if (syncStatus == 'pending') scheduleSync();
      }
    }
  }

  Future<void> createCloud(CloudLogin login, CloudKeys keys, String recovery) =>
      serial(() async {
        final access = login.access(keys);
        final response = await access.api.request('POST', '/v1/vault/create', {
          ...await access.proof(deviceName, platform),
          'verifyKey': await keys.publicKey,
          'recovery': await VaultCrypto.seal(
            keys.toJson(),
            VaultCrypto.recoveryKey(recovery),
            'recovery:${access.accountId}:1',
          ),
          'payload': await access.encrypt(document!),
        });
        await _commit(
          document!,
          access.copy(
            revision: response['revision'] as int,
            confirmed: document!.changes.keys.toSet(),
          ),
        );
        scheduleSync();
      });
  Future<VaultDocument> previewCloud(CloudAccess access) async {
    final data = await access.api.request('GET', '/v1/vault');
    if (data['epoch'] != access.epoch) {
      throw const FormatException('device_revoked');
    }
    return access.decryptResponse(data);
  }

  Future<void> connect(
    CloudAccess access,
    VaultDocument remote,
  ) => serial(() async {
    // Different warehouses have independent record IDs; same-ID edits merge causally.
    await _commit(
      document!.merge(remote),
      access.copy(revision: 0, confirmed: {}),
    );
    scheduleSync();
  });
  Future<void> enableSync(bool enabled) => serial(() async {
    if (cloud == null) return;
    await _commit(document!, cloud!.copy(enabled: enabled));
    syncStatus = enabled ? 'pending' : 'disabled';
    if (enabled) scheduleSync();
  });
  Future<void> renewLogin(CloudLogin login) => serial(() async {
    final old = cloud!;
    if (old.accountId != login.accountId) {
      throw const FormatException('wrong_account');
    }
    final access = await login.authorize(old.keys, deviceName, platform);
    await _commit(
      document!,
      access.copy(
        enabled: old.enabled,
        revision: old.revision,
        confirmed: old.confirmed,
      ),
    );
  });
  Future<void> rotateRecovery(String recovery) => serial(() async {
    final old = cloud!;
    final latest = await old.api.request('GET', '/v1/vault');
    final doc = document!.merge(await old.decryptResponse(latest));
    final keys = CloudKeys.generate();
    final next = old.copy(epoch: old.epoch + 1, keys: keys);
    final response = await old.api.request('POST', '/v1/vault/rotate', {
      'epoch': old.epoch,
      'revision': latest['revision'],
      'verifyKey': await keys.publicKey,
      'recovery': await VaultCrypto.seal(
        keys.toJson(),
        VaultCrypto.recoveryKey(recovery),
        'recovery:${old.accountId}:${next.epoch}',
      ),
      'payload': await next.encrypt(doc),
    });
    await _commit(
      doc,
      next.copy(
        revision: response['revision'] as int,
        confirmed: doc.changes.keys.toSet(),
      ),
    );
    scheduleSync();
  });
  Future<void> detach({required bool keepLocal}) => serial(() async {
    if (keepLocal) {
      // Fresh identities prevent reconnecting an independent copy from resurrecting old changes.
      final local = VaultDocument().importBackup(
        document!.backup(),
        keepDuplicates: true,
      );
      await _commit(local, null);
      syncStatus = 'disabled';
    } else {
      await store.remove();
      exists = false;
      lock();
    }
  });
  @override
  void dispose() {
    _syncTimer?.cancel();
    _poll?.cancel();
    super.dispose();
  }
}
