import 'package:flutter_test/flutter_test.dart';
import '../lib/models/purchase.dart';
import '_fixtures.dart';

void main() {
  tearDown(() => expiringSoonWindowDays = 30);

  group('addMonthsClamped', () {
    test('clamps to the last day of a shorter month', () {
      expect(addMonthsClamped(DateTime(2024, 1, 31), 1), DateTime(2024, 2, 29));
      expect(addMonthsClamped(DateTime(2023, 1, 31), 1), DateTime(2023, 2, 28));
    });
    test('rolls over years', () {
      expect(addMonthsClamped(DateTime(2024, 11, 30), 3), DateTime(2025, 2, 28));
      expect(addMonthsClamped(DateTime(2024, 1, 31), 12), DateTime(2025, 1, 31));
    });
  });

  group('warrantyStatus', () {
    test('expired / expiring soon / active', () {
      expect(warrantyStatus(daysFromToday(-1)), 'Expired');
      expect(warrantyStatus(daysFromToday(0)), 'Expiring Soon');
      expect(warrantyStatus(daysFromToday(10)), 'Expiring Soon');
      expect(warrantyStatus(daysFromToday(100)), 'Active');
    });
    test('the expiring-soon window is customisable', () {
      expiringSoonWindowDays = 5;
      expect(warrantyStatus(daysFromToday(10)), 'Active');
      expect(warrantyStatus(daysFromToday(5)), 'Expiring Soon');
      expiringSoonWindowDays = 90;
      expect(warrantyStatus(daysFromToday(80)), 'Expiring Soon');
    });
  });

  group('warrantyTimeLeft', () {
    test('today and expired wording', () {
      expect(warrantyTimeLeft(daysFromToday(0)), 'Expires today');
      expect(warrantyTimeLeft(daysFromToday(-1)), 'Expired 1 day ago');
      expect(warrantyTimeLeft(daysFromToday(-9)), 'Expired 9 days ago');
    });
    test('singular / plural days', () {
      expect(warrantyTimeLeft(daysFromToday(1)), '1 day left');
      expect(warrantyTimeLeft(daysFromToday(3)), '3 days left');
    });
  });

  group('Purchase photos', () {
    test('allImages prefers the multi-photo list', () {
      final p = makePurchase(images: ['a.jpg', 'b.jpg'], receiptPath: 'a.jpg');
      expect(p.allImages, ['a.jpg', 'b.jpg']);
    });
    test('allImages falls back to the legacy single receipt', () {
      expect(makePurchase(receiptPath: 'old.jpg').allImages, ['old.jpg']);
      expect(makePurchase().allImages, isEmpty);
    });
    test('copyWith swaps photos without touching other fields', () {
      final p = makePurchase(name: 'TV').copyWith(imagePaths: ['x.jpg'], receiptPath: 'x.jpg');
      expect(p.name, 'TV');
      expect(p.allImages, ['x.jpg']);
      expect(p.receiptPath, 'x.jpg');
    });
  });

  group('Purchase map round trip', () {
    test('notify flag is stored as 0 / 1 and defaults to on', () {
      expect(makePurchase(notify: false).toMap()['notify_enabled'], 0);
      expect(makePurchase(notify: true).toMap()['notify_enabled'], 1);
      expect(Purchase.fromMap({'name': 'x'}).notifyEnabled, isTrue); // old rows have no column
      expect(Purchase.fromMap({'name': 'x', 'notify_enabled': 0}).notifyEnabled, isFalse);
    });
    test('toMap never leaks the photo list or category name', () {
      final map = makePurchase(images: ['a.jpg']).toMap();
      expect(map.containsKey('imagePaths'), isFalse);
      expect(map.containsKey('category_name'), isFalse);
    });
  });
}
