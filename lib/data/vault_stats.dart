import '../models/purchase.dart';

/// Pure helpers behind the Insights tab, the Timeline tab and the Vault sort menu.
/// Nothing here touches the database, files or the UI, so it is covered by unit tests.

class CategoryStat {
  final String name;
  final int count;
  final double value;
  const CategoryStat(this.name, this.count, this.value);
}

class VaultStats {
  final int total;
  final int active;
  final int expiringSoon;
  final int expired;

  /// Sum of every price.
  final double totalValue;

  /// Sum of the prices of items whose warranty is still running.
  final double protectedValue;

  /// One entry per category that has at least one item, biggest value first.
  final List<CategoryStat> categories;

  const VaultStats({
    required this.total,
    required this.active,
    required this.expiringSoon,
    required this.expired,
    required this.totalValue,
    required this.protectedValue,
    required this.categories,
  });

  static const VaultStats empty = VaultStats(
    total: 0,
    active: 0,
    expiringSoon: 0,
    expired: 0,
    totalValue: 0,
    protectedValue: 0,
    categories: <CategoryStat>[],
  );

  factory VaultStats.from(List<Purchase> items) {
    var active = 0;
    var soon = 0;
    var expired = 0;
    var totalValue = 0.0;
    var protectedValue = 0.0;
    final counts = <String, int>{};
    final values = <String, double>{};
    for (final item in items) {
      final status = warrantyStatus(item.expiryDate);
      if (status == 'Active') {
        active++;
        protectedValue += item.price;
      } else if (status == 'Expiring Soon') {
        soon++;
        protectedValue += item.price;
      } else {
        expired++;
      }
      totalValue += item.price;
      counts[item.categoryName] = (counts[item.categoryName] ?? 0) + 1;
      values[item.categoryName] = (values[item.categoryName] ?? 0) + item.price;
    }
    final categories = counts.keys
        .map((name) => CategoryStat(name, counts[name] ?? 0, values[name] ?? 0))
        .toList();
    categories.sort((a, b) {
      final byValue = b.value.compareTo(a.value);
      if (byValue != 0) return byValue;
      final byCount = b.count.compareTo(a.count);
      if (byCount != 0) return byCount;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return VaultStats(
      total: items.length,
      active: active,
      expiringSoon: soon,
      expired: expired,
      totalValue: totalValue,
      protectedValue: protectedValue,
      categories: categories,
    );
  }
}

// ------------------------------------------------------------------ timeline

const String bucketThisWeek = 'This week';
const String bucketNext30 = 'Next 30 days';
const String bucketNext90 = 'Next 3 months';
const String bucketLater = 'Later';
const String bucketRecentlyExpired = 'Recently expired';
const String bucketLongExpired = 'Expired earlier';

/// Display order of the Timeline tab.
const List<String> timelineBucketOrder = <String>[
  bucketThisWeek,
  bucketNext30,
  bucketNext90,
  bucketLater,
  bucketRecentlyExpired,
  bucketLongExpired,
];

/// [days] is the number of days from today until expiry (negative = already expired).
String timelineBucket(int days) {
  if (days < -30) return bucketLongExpired;
  if (days < 0) return bucketRecentlyExpired;
  if (days <= 7) return bucketThisWeek;
  if (days <= 30) return bucketNext30;
  if (days <= 90) return bucketNext90;
  return bucketLater;
}

/// Groups purchases for the Timeline tab. Only non-empty groups are returned, in
/// [timelineBucketOrder]. Running warranties are listed soonest first; expired ones
/// are listed with the most recently expired first.
List<MapEntry<String, List<Purchase>>> groupByTimeline(List<Purchase> items) {
  final grouped = <String, List<Purchase>>{};
  for (final item in items) {
    final bucket = timelineBucket(daysUntilExpiry(item.expiryDate));
    grouped.putIfAbsent(bucket, () => <Purchase>[]).add(item);
  }
  final result = <MapEntry<String, List<Purchase>>>[];
  for (final label in timelineBucketOrder) {
    final list = grouped[label];
    if (list == null || list.isEmpty) continue;
    final expiredGroup = label == bucketRecentlyExpired || label == bucketLongExpired;
    list.sort((a, b) {
      final da = daysUntilExpiry(a.expiryDate);
      final db = daysUntilExpiry(b.expiryDate);
      return expiredGroup ? db.compareTo(da) : da.compareTo(db);
    });
    result.add(MapEntry<String, List<Purchase>>(label, list));
  }
  return result;
}

// ---------------------------------------------------------------------- sort

enum VaultSort { newest, soonest, name, price }

String vaultSortLabel(VaultSort sort) {
  switch (sort) {
    case VaultSort.newest:
      return 'Newest added';
    case VaultSort.soonest:
      return 'Soonest expiry';
    case VaultSort.name:
      return 'Name A-Z';
    case VaultSort.price:
      return 'Highest price';
  }
}

/// Returns a new sorted list; the input list is never modified.
List<Purchase> sortPurchases(List<Purchase> items, VaultSort sort) {
  final list = List<Purchase>.of(items);
  switch (sort) {
    case VaultSort.newest:
      list.sort((a, b) => (b.id ?? 0).compareTo(a.id ?? 0));
      break;
    case VaultSort.soonest:
      list.sort((a, b) => daysUntilExpiry(a.expiryDate).compareTo(daysUntilExpiry(b.expiryDate)));
      break;
    case VaultSort.name:
      list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      break;
    case VaultSort.price:
      list.sort((a, b) => b.price.compareTo(a.price));
      break;
  }
  return list;
}

/// "Rs. 12,500" - whole rupees, thousands separated, no intl dependency.
String formatMoney(double value) {
  final negative = value.round() < 0;
  final digits = value.abs().round().toString();
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
    buffer.write(digits[i]);
  }
  return '${negative ? '-' : ''}Rs. ${buffer.toString()}';
}
