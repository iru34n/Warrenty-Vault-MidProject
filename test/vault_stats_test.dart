import 'package:flutter_test/flutter_test.dart';
import '../lib/data/vault_stats.dart';
import '../lib/models/purchase.dart';
import '_fixtures.dart';

void main() {
  tearDown(() => expiringSoonWindowDays = 30);

  group('VaultStats', () {
    test('empty list gives zeros', () {
      final s = VaultStats.from(const <Purchase>[]);
      expect(s.total, 0);
      expect(s.totalValue, 0);
      expect(s.categories, isEmpty);
    });

    test('counts statuses and sums values', () {
      final items = <Purchase>[
        makePurchase(id: 1, expiryDate: daysFromToday(200), price: 1000),
        makePurchase(id: 2, expiryDate: daysFromToday(10), price: 500),
        makePurchase(id: 3, expiryDate: daysFromToday(-5), price: 250),
      ];
      final s = VaultStats.from(items);
      expect(s.total, 3);
      expect(s.active, 1);
      expect(s.expiringSoon, 1);
      expect(s.expired, 1);
      expect(s.totalValue, 1750);
      expect(s.protectedValue, 1500);
    });

    test('groups by category, biggest value first', () {
      final items = <Purchase>[
        makePurchase(id: 1, category: 'Appliances', price: 300),
        makePurchase(id: 2, category: 'Electronics', price: 900),
        makePurchase(id: 3, category: 'Electronics', price: 100),
      ];
      final s = VaultStats.from(items);
      expect(s.categories.length, 2);
      expect(s.categories.first.name, 'Electronics');
      expect(s.categories.first.count, 2);
      expect(s.categories.first.value, 1000);
      expect(s.categories.last.name, 'Appliances');
    });

    test('respects the expiring-soon window', () {
      expiringSoonWindowDays = 7;
      final s = VaultStats.from(<Purchase>[makePurchase(expiryDate: daysFromToday(10))]);
      expect(s.active, 1);
      expect(s.expiringSoon, 0);
    });
  });

  group('timeline', () {
    test('bucket boundaries', () {
      expect(timelineBucket(-31), bucketLongExpired);
      expect(timelineBucket(-30), bucketRecentlyExpired);
      expect(timelineBucket(-1), bucketRecentlyExpired);
      expect(timelineBucket(0), bucketThisWeek);
      expect(timelineBucket(7), bucketThisWeek);
      expect(timelineBucket(8), bucketNext30);
      expect(timelineBucket(30), bucketNext30);
      expect(timelineBucket(31), bucketNext90);
      expect(timelineBucket(90), bucketNext90);
      expect(timelineBucket(91), bucketLater);
    });

    test('groups are ordered and empty groups are dropped', () {
      final groups = groupByTimeline(<Purchase>[
        makePurchase(id: 1, name: 'Old', expiryDate: daysFromToday(-100)),
        makePurchase(id: 2, name: 'Far', expiryDate: daysFromToday(400)),
        makePurchase(id: 3, name: 'Soon', expiryDate: daysFromToday(3)),
        makePurchase(id: 4, name: 'Sooner', expiryDate: daysFromToday(1)),
      ]);
      expect(groups.map((g) => g.key).toList(), [bucketThisWeek, bucketLater, bucketLongExpired]);
      expect(groups.first.value.map((p) => p.name).toList(), ['Sooner', 'Soon']);
    });

    test('expired group lists the most recently expired first', () {
      final groups = groupByTimeline(<Purchase>[
        makePurchase(id: 1, name: 'A', expiryDate: daysFromToday(-20)),
        makePurchase(id: 2, name: 'B', expiryDate: daysFromToday(-2)),
      ]);
      expect(groups.length, 1);
      expect(groups.first.key, bucketRecentlyExpired);
      expect(groups.first.value.map((p) => p.name).toList(), ['B', 'A']);
    });
  });

  group('sortPurchases', () {
    final items = <Purchase>[
      makePurchase(id: 1, name: 'banana', expiryDate: daysFromToday(50), price: 10),
      makePurchase(id: 2, name: 'Apple', expiryDate: daysFromToday(5), price: 300),
      makePurchase(id: 3, name: 'cherry', expiryDate: daysFromToday(20), price: 100),
    ];
    List<String> names(VaultSort s) => sortPurchases(items, s).map((p) => p.name).toList();

    test('newest first', () => expect(names(VaultSort.newest), ['cherry', 'Apple', 'banana']));
    test('soonest expiry', () => expect(names(VaultSort.soonest), ['Apple', 'cherry', 'banana']));
    test('name ignores case', () => expect(names(VaultSort.name), ['Apple', 'banana', 'cherry']));
    test('highest price', () => expect(names(VaultSort.price), ['Apple', 'cherry', 'banana']));
    test('does not modify the input', () {
      sortPurchases(items, VaultSort.name);
      expect(items.first.name, 'banana');
    });
  });

  group('formatMoney', () {
    test('thousands separators', () {
      expect(formatMoney(0), 'Rs. 0');
      expect(formatMoney(999), 'Rs. 999');
      expect(formatMoney(1000), 'Rs. 1,000');
      expect(formatMoney(1234567.4), 'Rs. 1,234,567');
    });
  });
}
