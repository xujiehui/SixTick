import '../core/document.dart';

/// Local presentation preferences; no ordering fields enter the synced vault.
List<RecordView> orderAccounts(
  List<RecordView> entries,
  String mode,
  List<String> savedOrder,
) {
  final rank = <String, int>{};
  for (final id in savedOrder) {
    rank.putIfAbsent(id, () => rank.length);
  }
  for (final entry in entries) {
    rank.putIfAbsent(entry.id, () => rank.length);
  }
  final ordered = [...entries];
  ordered.sort((a, b) {
    if (mode == 'name') {
      final name = a.otp.issuer.toLowerCase().compareTo(
        b.otp.issuer.toLowerCase(),
      );
      if (name != 0) return name;
      final account = a.otp.account.toLowerCase().compareTo(
        b.otp.account.toLowerCase(),
      );
      if (account != 0) return account;
    } else if (mode == 'favorites') {
      final favorite =
          (b.fields['favorite'] == true ? 1 : 0) -
          (a.fields['favorite'] == true ? 1 : 0);
      if (favorite != 0) return favorite;
    }
    return rank[a.id]!.compareTo(rank[b.id]!);
  });
  return ordered;
}
