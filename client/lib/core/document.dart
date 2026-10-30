import 'dart:convert';
import 'package:uuid/uuid.dart';
import 'totp.dart';

const uuid = Uuid();

String canonical(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return '{${keys.map((k) => '${jsonEncode(k)}:${canonical(value[k])}').join(',')}}';
  }
  if (value is List) return '[${value.map(canonical).join(',')}]';
  return jsonEncode(value);
}

class Change {
  final String id, record, kind;
  final List<String> parents;
  final Map<String, dynamic> fields;
  final bool deleted;
  Change({
    required this.id,
    required this.record,
    required this.kind,
    required this.parents,
    required this.fields,
    this.deleted = false,
  });
  factory Change.fromJson(Map<String, dynamic> json) => Change(
    id: json['id'] as String,
    record: json['record'] as String,
    kind: json['kind'] as String,
    parents: (json['parents'] as List).cast<String>(),
    fields: Map<String, dynamic>.from(json['fields'] as Map),
    deleted: json['deleted'] as bool,
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'record': record,
    'kind': kind,
    'parents': parents,
    'fields': fields,
    'deleted': deleted,
  };
}

class RecordView {
  final String id, kind;
  final Map<String, dynamic> fields;
  final Map<String, List<dynamic>> conflicts;
  RecordView(this.id, this.kind, this.fields, this.conflicts);
  OtpAccount get otp => OtpAccount.fromJson(fields);
}

/// An immutable operation DAG. Parents refer to previous heads of the SAME record.
/// Field-wise multi-value registers preserve concurrent edits; deletion wins forever.
class VaultDocument {
  final Map<String, Change> changes;
  VaultDocument([Map<String, Change>? changes])
    : changes = Map.unmodifiable(changes ?? {});
  factory VaultDocument.fromJson(Map<String, dynamic> data) {
    if (data['version'] != 1 ||
        data['changes'] is! List ||
        (data['changes'] as List).length > 50000) {
      throw const FormatException('unsupported_version');
    }
    final changes = <String, Change>{};
    for (final json in data['changes'] as List) {
      final change = Change.fromJson(Map<String, dynamic>.from(json as Map));
      if (changes.containsKey(change.id)) {
        throw const FormatException('corrupt_data');
      }
      changes[change.id] = change;
    }
    final doc = VaultDocument(changes);
    doc.validate();
    return doc;
  }
  Map<String, dynamic> toJson() => {
    'version': 1,
    'changes': changes.values.map((c) => c.toJson()).toList(),
  };

  Map<String, List<Change>> get _records {
    final records = <String, List<Change>>{};
    for (final c in changes.values) {
      records.putIfAbsent(c.record, () => []).add(c);
    }
    return records;
  }

  void validate() {
    final ids = RegExp(r'^[a-zA-Z0-9_-]{16,100}$');
    for (final c in changes.values) {
      if (!ids.hasMatch(c.id) ||
          !ids.hasMatch(c.record) ||
          !['entry', 'group'].contains(c.kind) ||
          c.parents.toSet().length != c.parents.length) {
        throw const FormatException('corrupt_data');
      }
      final allowed = c.kind == 'entry'
          ? {
              'issuer',
              'account',
              'secret',
              'algorithm',
              'digits',
              'period',
              'group',
              'favorite',
            }
          : {'name'};
      if (c.fields.keys.any((key) => !allowed.contains(key))) {
        throw const FormatException('corrupt_data');
      }
      for (final parent in c.parents) {
        if (!changes.containsKey(parent) ||
            changes[parent]!.record != c.record ||
            changes[parent]!.kind != c.kind) {
          throw const FormatException('corrupt_data');
        }
      }
      if (c.kind == 'entry' &&
          c.parents.isNotEmpty &&
          c.fields.keys.any(
            {'secret', 'algorithm', 'digits', 'period'}.contains,
          )) {
        throw const FormatException('immutable_parameters');
      }
      // Validate every supplied value, including losing conflict values and tombstones.
      for (final entry in c.fields.entries) {
        final key = entry.key, v = entry.value;
        if ([
                  'issuer',
                  'account',
                  'name',
                  'secret',
                  'algorithm',
                ].contains(key) &&
                v is! String ||
            ['digits', 'period'].contains(key) && v is! int ||
            key == 'favorite' && v is! bool ||
            key == 'group' && v != null && (v is! String || !ids.hasMatch(v))) {
          throw const FormatException('corrupt_data');
        }
        if (v is String && v.length > 2000) {
          throw const FormatException('corrupt_data');
        }
      }
      if (c.parents.isEmpty && !c.deleted) {
        if (c.kind == 'entry') {
          OtpAccount.fromJson(c.fields);
        } else if ((c.fields['name'] as String? ?? '').trim().isEmpty) {
          throw const FormatException('invalid_name');
        }
      }
    }
    // Topological traversal without recursive call-stack growth.
    final pending = {for (final c in changes.values) c.id: c.parents.length};
    final children = <String, List<String>>{};
    for (final c in changes.values) {
      for (final p in c.parents) {
        children.putIfAbsent(p, () => []).add(c.id);
      }
    }
    final ready = pending.keys.where((id) => pending[id] == 0).toList();
    var processed = 0;
    while (ready.isNotEmpty) {
      final id = ready.removeLast();
      processed++;
      for (final child in children[id] ?? <String>[]) {
        pending[child] = pending[child]! - 1;
        if (pending[child] == 0) ready.add(child);
      }
    }
    if (processed != changes.length) {
      throw const FormatException('corrupt_data');
    }
    for (final record in _records.values) {
      if (record.map((c) => c.kind).toSet().length != 1 ||
          record.where((c) => c.parents.isEmpty).length != 1) {
        throw const FormatException('corrupt_data');
      }
    }
    for (final view in records) {
      if (view.kind == 'entry') {
        view.otp;
      } else if ((view.fields['name'] as String? ?? '').trim().isEmpty) {
        throw const FormatException('invalid_name');
      }
    }
  }

  List<RecordView> get records {
    final result = <RecordView>[];
    for (final group in _records.entries) {
      final ops = group.value;
      if (ops.any((op) => op.deleted)) continue;
      final ancestors = <String, Set<String>>{};
      Set<String> before(Change c) => ancestors.putIfAbsent(c.id, () {
        final result = <String>{}, pending = [...c.parents];
        while (pending.isNotEmpty) {
          final id = pending.removeLast();
          if (result.add(id)) pending.addAll(changes[id]!.parents);
        }
        return result;
      });
      final keys = ops.expand((op) => op.fields.keys).toSet();
      final fields = <String, dynamic>{}, conflicts = <String, List<dynamic>>{};
      for (final key in keys) {
        final writing = ops.where((op) => op.fields.containsKey(key)).toList();
        final maxima =
            writing
                .where(
                  (a) => !writing.any(
                    (b) => a.id != b.id && before(b).contains(a.id),
                  ),
                )
                .toList()
              ..sort((a, b) => a.id.compareTo(b.id));
        final values = <dynamic>[];
        for (final op in maxima) {
          if (!values.any((v) => canonical(v) == canonical(op.fields[key]))) {
            values.add(op.fields[key]);
          }
        }
        fields[key] = values.first;
        if (values.length > 1) conflicts[key] = values;
      }
      result.add(RecordView(group.key, ops.first.kind, fields, conflicts));
    }
    return result;
  }

  List<RecordView> get entries =>
      records.where((r) => r.kind == 'entry').toList();
  List<RecordView> get groups =>
      records.where((r) => r.kind == 'group').toList();
  int get conflictCount => records.where((r) => r.conflicts.isNotEmpty).length;
  bool containsOtp(OtpAccount otp) =>
      entries.any((e) => e.otp.fingerprint == otp.fingerprint);

  VaultDocument patch(
    String record,
    String kind,
    Map<String, dynamic> fields, {
    bool deleted = false,
  }) {
    final ops = changes.values.where((op) => op.record == record).toList();
    if (ops.any((op) => op.deleted)) {
      throw const FormatException('record_deleted');
    }
    final parented = ops.expand((op) => op.parents).toSet();
    final change = Change(
      id: uuid.v4(),
      record: record,
      kind: kind,
      parents: ops
          .where((op) => !parented.contains(op.id))
          .map((op) => op.id)
          .toList(),
      fields: Map.of(fields),
      deleted: deleted,
    );
    final next = VaultDocument({...changes, change.id: change});
    next.validate();
    return next;
  }

  VaultDocument add(OtpAccount otp, {String? group, bool favorite = false}) =>
      patch(uuid.v4(), 'entry', {
        ...otp.toJson(),
        'group': group,
        'favorite': favorite,
      });
  VaultDocument merge(VaultDocument other) {
    final merged = {...changes};
    for (final c in other.changes.values) {
      if (merged.containsKey(c.id) &&
          canonical(merged[c.id]!.toJson()) != canonical(c.toJson())) {
        throw const FormatException('corrupt_data');
      }
      merged[c.id] = c;
    }
    final doc = VaultDocument(merged);
    doc.validate();
    return doc;
  }

  Map<String, dynamic> backup() => {
    'version': 1,
    'entries': entries.map((e) => e.fields).toList(),
    'groups': groups
        .map((g) => {'id': g.id, 'name': g.fields['name']})
        .toList(),
  };

  static void validateBackup(Map<String, dynamic> backup) {
    if (backup['version'] != 1 ||
        backup['entries'] is! List ||
        backup['groups'] is! List ||
        (backup['entries'] as List).length > 10000 ||
        (backup['groups'] as List).length > 10000) {
      throw const FormatException('unsupported_version');
    }
    final groupIds = <String>{};
    for (final g in backup['groups'] as List) {
      if (g is! Map ||
          g['id'] is! String ||
          g['name'] is! String ||
          (g['name'] as String).trim().isEmpty ||
          !groupIds.add(g['id'] as String)) {
        throw const FormatException('corrupt_data');
      }
    }
    for (final e in backup['entries'] as List) {
      OtpAccount.fromJson(Map<String, dynamic>.from(e as Map));
      if (e['favorite'] != null && e['favorite'] is! bool ||
          e['group'] != null && e['group'] is! String) {
        throw const FormatException('corrupt_data');
      }
    }
  }

  VaultDocument importBackup(
    Map<String, dynamic> backup, {
    required bool keepDuplicates,
  }) {
    validateBackup(backup);
    var next = this;
    final mapping = <String, String>{};
    for (final g in backup['groups'] as List) {
      final id = uuid.v4();
      mapping[g['id'] as String] = id;
      next = next.patch(id, 'group', {'name': g['name']});
    }
    for (final e in backup['entries'] as List) {
      final otp = OtpAccount.fromJson(Map<String, dynamic>.from(e as Map));
      if (!keepDuplicates && next.containsOtp(otp)) continue;
      next = next.add(
        otp,
        group: mapping[e['group']],
        favorite: e['favorite'] as bool? ?? false,
      );
    }
    return next;
  }
}
