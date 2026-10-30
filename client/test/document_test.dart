import 'package:flutter_test/flutter_test.dart';
import 'package:six_tick/core/document.dart';
import 'package:six_tick/core/totp.dart';

void main() {
  final otp = OtpAccount(
    issuer: 'Example',
    account: 'alice',
    secret: 'JBSWY3DPEHPK3PXP',
  );
  test('offline edits to separate fields merge independent of order', () {
    final base = VaultDocument().add(otp), id = base.entries.single.id;
    final a = base.patch(id, 'entry', {'issuer': 'Work'});
    final b = base.patch(id, 'entry', {'favorite': true});
    final merged = a.merge(b);
    expect(merged.entries.single.fields['issuer'], 'Work');
    expect(merged.entries.single.fields['favorite'], true);
    expect(merged.conflictCount, 0);
    expect(canonical(a.merge(b).backup()), canonical(b.merge(a).backup()));
  });
  test(
    'same-field concurrency retains all values and supports explicit resolution',
    () {
      final base = VaultDocument().add(otp), id = base.entries.single.id;
      final a = base.patch(id, 'entry', {'issuer': 'A'}),
          b = base.patch(id, 'entry', {'issuer': 'B'});
      final conflict = a.merge(b);
      expect(
        conflict.entries.single.conflicts['issuer'],
        unorderedEquals(['A', 'B']),
      );
      final resolved = conflict.patch(id, 'entry', {'issuer': 'Chosen'});
      expect(resolved.entries.single.otp.issuer, 'Chosen');
      expect(resolved.merge(a).conflictCount, 0);
    },
  );
  test('delete wins over a concurrent edit and old offline replicas', () {
    final base = VaultDocument().add(otp), id = base.entries.single.id;
    final removed = base.patch(id, 'entry', {}, deleted: true);
    final offline = base.patch(id, 'entry', {'issuer': 'Stale'});
    expect(removed.merge(offline).entries, isEmpty);
    expect(removed.merge(base).entries, isEmpty);
    expect(
      () => removed.patch(id, 'entry', {'issuer': 'Resurrected'}),
      throwsFormatException,
    );
    expect(removed.changes, isNotEmpty);
  });
  test('idempotent merge and tampered operation identities', () {
    final base = VaultDocument().add(otp);
    expect(base.merge(base).changes.length, base.changes.length);
    final c = base.changes.values.single;
    final forged = VaultDocument({
      c.id: Change(
        id: c.id,
        record: c.record,
        kind: c.kind,
        parents: c.parents,
        fields: {...c.fields, 'issuer': 'Forged'},
      ),
    });
    expect(() => base.merge(forged), throwsFormatException);
  });
  test('immutable TOTP parameters cannot be edited', () {
    final base = VaultDocument().add(otp);
    expect(
      () => base.patch(base.entries.single.id, 'entry', {'period': 60}),
      throwsFormatException,
    );
  });
  test('group deletion keeps accounts; restore creates new IDs', () {
    final group = uuid.v4();
    final base = VaultDocument()
        .patch(group, 'group', {'name': 'Work'})
        .add(otp, group: group, favorite: true);
    final removed = base.patch(group, 'group', {}, deleted: true);
    expect(removed.entries.length, 1);
    expect(removed.groups, isEmpty);
    final restored = VaultDocument().importBackup(
      base.backup(),
      keepDuplicates: true,
    );
    expect(restored.entries.single.id, isNot(base.entries.single.id));
    expect(restored.entries.single.fields['group'], restored.groups.single.id);
    expect(restored.entries.single.fields['favorite'], true);
  });
  test(
    'backup validates whole input and duplicate policy before committing',
    () {
      final base = VaultDocument().add(otp);
      expect(
        base.importBackup(base.backup(), keepDuplicates: false).entries.length,
        1,
      );
      expect(
        base.importBackup(base.backup(), keepDuplicates: true).entries.length,
        2,
      );
      final invalid = base.backup();
      (invalid['entries'] as List).add({'issuer': 'Broken'});
      expect(
        () => base.importBackup(invalid, keepDuplicates: true),
        throwsA(anything),
      );
      expect(base.entries.length, 1);
    },
  );
  test('cyclic and missing parents are rejected', () {
    final record = uuid.v4(), op = uuid.v4();
    expect(
      () => VaultDocument.fromJson({
        'version': 1,
        'changes': [
          Change(
            id: op,
            record: record,
            kind: 'entry',
            parents: [op],
            fields: otp.toJson(),
          ).toJson(),
        ],
      }),
      throwsFormatException,
    );
    expect(
      () => VaultDocument.fromJson({
        'version': 1,
        'changes': [
          Change(
            id: op,
            record: record,
            kind: 'entry',
            parents: [uuid.v4()],
            fields: {'issuer': 'broken'},
          ).toJson(),
        ],
      }),
      throwsFormatException,
    );
  });
  test('duplicate independent records are preserved', () {
    expect(
      VaultDocument().add(otp).merge(VaultDocument().add(otp)).entries.length,
      2,
    );
  });
}
