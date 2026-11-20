import 'package:flutter_test/flutter_test.dart';
import '../lib/data/app_settings.dart';
import '../lib/data/expiry_notification_service.dart';
import '_fixtures.dart';

void main() {
  final now = DateTime(2026, 11, 20, 8, 0);
  const prefs = NotificationPrefs();

  test('nothing is planned when reminders are switched off', () {
    expect(planNotifications(makePurchase(), prefs.copyWith(enabled: false), now), isEmpty);
  });

  test('nothing is planned when this item has reminders off', () {
    expect(planNotifications(makePurchase(notify: false), prefs, now), isEmpty);
  });

  test('nothing is planned for an unsaved purchase (no id)', () {
    expect(planNotifications(makePurchase(id: null), prefs, now), isEmpty);
  });

  test('several lead times plus the expiry alert, largest lead first', () {
    final plan = planNotifications(makePurchase(), prefs.copyWith(leadDays: [1, 30, 7]), now);
    expect(plan.map((n) => n.id), [501, 502, 503, 590]);
    expect(plan.map((n) => n.when), [
      DateTime(2026, 12, 1, 9),
      DateTime(2026, 12, 24, 9),
      DateTime(2026, 12, 30, 9),
      DateTime(2026, 12, 31, 9),
    ]);
    expect(plan.any((n) => n.immediate), isFalse);
  });

  test('reminder time of day is customisable', () {
    final plan = planNotifications(makePurchase(), prefs.copyWith(leadDays: [1], hour: 18, minute: 30), now);
    expect(plan.first.when, DateTime(2026, 12, 30, 18, 30));
  });

  test('duplicate lead days collapse into one reminder', () {
    final plan = planNotifications(makePurchase(), prefs.copyWith(leadDays: [7, 7, 3]), now);
    expect(plan.where((n) => !n.immediate && n.id % 100 != kExpirySlot).length, 2);
  });

  test('missed reminder gives one catch-up alert while the warranty is still running', () {
    final plan = planNotifications(makePurchase(expiryDate: '2026-11-24'), prefs, now);
    final catchUp = plan.firstWhere((n) => n.immediate);
    expect(catchUp.id, 500 + kCatchUpSlot);
    expect(catchUp.body, contains('4 days'));
    expect(catchUp.dedupeKey, isNotEmpty);
    expect(plan.any((n) => n.id == 500 + kExpirySlot && !n.immediate), isTrue);
  });

  test('catch-up can be switched off', () {
    final plan = planNotifications(makePurchase(expiryDate: '2026-11-24'), prefs.copyWith(catchUp: false), now);
    expect(plan.where((n) => n.immediate), isEmpty);
    expect(plan.length, 1);
  });

  test('a warranty that expired recently is announced once', () {
    final plan = planNotifications(makePurchase(expiryDate: '2026-11-15'), prefs, now);
    expect(plan.length, 1);
    expect(plan.single.id, 500 + kExpiredNowSlot);
    expect(plan.single.immediate, isTrue);
    expect(plan.single.dedupeKey, 'expiry_notice_shown_5_2026-11-15_09:00');
  });

  test('a warranty that expired long ago stays quiet', () {
    expect(planNotifications(makePurchase(expiryDate: '2026-10-01'), prefs, now), isEmpty);
  });

  test('the expiry alert can be switched off', () {
    final plan = planNotifications(makePurchase(), prefs.copyWith(notifyOnExpiry: false), now);
    expect(plan.any((n) => n.id == 500 + kExpirySlot), isFalse);
  });

  test('expiry alert uses the item\'s own expiry time', () {
    final plan = planNotifications(makePurchase(expiryTime: '17:45'), prefs, now);
    expect(plan.firstWhere((n) => n.id == 500 + kExpirySlot).when, DateTime(2026, 12, 31, 17, 45));
  });

  test('a corrupt expiry time falls back to 09:00 instead of crashing', () {
    final plan = planNotifications(makePurchase(expiryTime: 'oops'), prefs, now);
    expect(plan.firstWhere((n) => n.id == 500 + kExpirySlot).when, DateTime(2026, 12, 31, 9));
  });

  test('a corrupt expiry date plans nothing', () {
    expect(planNotifications(makePurchase(expiryDate: 'not-a-date'), prefs, now), isEmpty);
  });

  group('NotificationPrefs', () {
    test('normalizeLeadDays drops invalid values, sorts large-to-small and caps the list', () {
      expect(NotificationPrefs.normalizeLeadDays([0, 400, 30, 7, 7, 1, 2, 3, 4, 5, 6, 8, 9, 10]), [30, 10, 9, 8, 7, 6, 5, 4]);
    });
    test('copyWith clamps hour, minute and window', () {
      final p = prefs.copyWith(hour: 99, minute: -4, expiringSoonDays: 0);
      expect(p.hour, 23);
      expect(p.minute, 0);
      expect(p.expiringSoonDays, 1);
    });
    test('summary text', () {
      expect(prefs.summary, '7 days before at 9:00 AM and on expiry day');
      expect(prefs.copyWith(enabled: false).summary, 'Turned off');
      expect(prefs.copyWith(leadDays: [1]).summary, '1 day before at 9:00 AM and on expiry day');
      expect(prefs.copyWith(leadDays: [], notifyOnExpiry: false).summary, 'No reminders selected');
    });
    test('formatClock', () {
      expect(formatClock(0, 5), '12:05 AM');
      expect(formatClock(12, 0), '12:00 PM');
      expect(formatClock(13, 30), '1:30 PM');
    });
  });
}
