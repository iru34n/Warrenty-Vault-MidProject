import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import '../models/purchase.dart';
import 'app_settings.dart';

/// A notification the planner wants to exist for one purchase.
class PlannedNotification {
  final int id;
  final String title;
  final String body;
  final DateTime when;
  /// Show right away (once) instead of scheduling for later.
  final bool immediate;
  /// Used to make sure an immediate notification is only shown once.
  final String dedupeKey;
  const PlannedNotification({
    required this.id,
    required this.title,
    required this.body,
    required this.when,
    this.immediate = false,
    this.dedupeKey = '',
  });
}

/// Notification id layout per purchase: id * 100 + slot.
/// Slots 1..8 are the "before expiry" reminders; the rest are fixed.
const int kExpirySlot = 90;
const int kExpiredNowSlot = 91;
const int kCatchUpSlot = 92;
const int kTestNotificationId = 2000000000;

String _leadBody(int days) {
  if (days <= 0) return 'Your warranty expires today. Check your coverage and receipt.';
  if (days == 1) return 'Your warranty expires tomorrow. Check your coverage and receipt.';
  return 'Your warranty expires in $days days. Check your coverage and receipt.';
}

({int hour, int minute}) _parseClock(String value) {
  final parts = value.split(':');
  final hour = parts.isNotEmpty ? int.tryParse(parts[0]) ?? 9 : 9;
  final minute = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
  return (hour: hour.clamp(0, 23).toInt(), minute: minute.clamp(0, 59).toInt());
}

/// Pure scheduling logic (no plugin calls) so it can be unit-tested.
List<PlannedNotification> planNotifications(Purchase purchase, NotificationPrefs prefs, DateTime now) {
  final id = purchase.id;
  if (!prefs.enabled || !purchase.notifyEnabled || id == null) return const [];
  final expiry = DateTime.tryParse(purchase.expiryDate);
  if (expiry == null) return const [];
  final expiryDay = DateTime(expiry.year, expiry.month, expiry.day);
  final clock = _parseClock(purchase.expiryTime);
  final expiryMoment = DateTime(expiryDay.year, expiryDay.month, expiryDay.day, clock.hour, clock.minute);
  final base = id * 100;
  final planned = <PlannedNotification>[];

  // Reminders N days before expiry, at the user's chosen reminder time.
  final leads = NotificationPrefs.normalizeLeadDays(prefs.leadDays);
  final missed = <int>[];
  for (var i = 0; i < leads.length; i++) {
    final lead = leads[i];
    final day = DateTime(expiryDay.year, expiryDay.month, expiryDay.day - lead);
    final when = DateTime(day.year, day.month, day.day, prefs.hour, prefs.minute);
    if (when.isAfter(now)) {
      planned.add(PlannedNotification(
        id: base + i + 1,
        title: 'Warranty ending soon: ${purchase.name}',
        body: _leadBody(lead),
        when: when,
      ));
    } else if (expiryMoment.isAfter(now)) {
      missed.add(lead);
    }
  }

  // One catch-up alert when a reminder time already passed but the warranty is still running.
  if (prefs.catchUp && missed.isNotEmpty) {
    final daysLeft = daysUntilExpiryFrom(expiryDay, now);
    planned.add(PlannedNotification(
      id: base + kCatchUpSlot,
      title: 'Warranty ending soon: ${purchase.name}',
      body: _leadBody(daysLeft),
      when: now,
      immediate: true,
      dedupeKey: 'catchup_${id}_${purchase.expiryDate}_${purchase.expiryTime}',
    ));
  }

  // Alert at the item's own expiry time.
  if (prefs.notifyOnExpiry) {
    if (expiryMoment.isAfter(now)) {
      planned.add(PlannedNotification(
        id: base + kExpirySlot,
        title: 'Warranty expired: ${purchase.name}',
        body: 'The warranty for ${purchase.name} has reached its expiry date.',
        when: expiryMoment,
      ));
    } else if (now.difference(expiryMoment) <= const Duration(days: 14)) {
      // Expired recently: tell the user once (same key the app has always used).
      planned.add(PlannedNotification(
        id: base + kExpiredNowSlot,
        title: 'Warranty expired: ${purchase.name}',
        body: 'This warranty reached its expiry date (${purchase.expiryDate}).',
        when: now,
        immediate: true,
        dedupeKey: 'expiry_notice_shown_${id}_${purchase.expiryDate}_${purchase.expiryTime}',
      ));
    }
  }
  return planned;
}

int daysUntilExpiryFrom(DateTime expiryDay, DateTime now) =>
    expiryDay.difference(DateTime(now.year, now.month, now.day)).inDays;

class ExpiryNotificationService {
  ExpiryNotificationService._();
  static final instance = ExpiryNotificationService._();
  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;

  void _configureLocalZone() {
    tzdata.initializeTimeZones();
    final now = DateTime.now();
    final offsetMs = now.timeZoneOffset.inMilliseconds;
    tz.Location? chosen;
    try {
      final karachi = tz.getLocation('Asia/Karachi');
      if (karachi.timeZone(now.millisecondsSinceEpoch).offset == offsetMs) chosen = karachi;
    } catch (_) {}
    if (chosen == null) {
      tz.Location? sameOffset;
      for (final loc in tz.timeZoneDatabase.locations.values) {
        final zone = loc.timeZone(now.millisecondsSinceEpoch);
        if (zone.offset != offsetMs) continue;
        sameOffset ??= loc;
        if (zone.abbreviation == now.timeZoneName) {
          chosen = loc;
          break;
        }
      }
      chosen ??= sameOffset;
    }
    tz.setLocalLocation(chosen ?? tz.getLocation('Asia/Karachi'));
  }

  Future<void> initialize() async {
    if (_ready) return;
    _configureLocalZone();
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    await _plugin.initialize(const InitializationSettings(android: android));
    await _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.requestNotificationsPermission();
    _ready = true;
  }

  /// Android notification channels are immutable, so each sound/vibration
  /// combination gets its own channel. The default keeps the original id.
  NotificationDetails _details(NotificationPrefs prefs, {bool bigText = true}) {
    final id = prefs.sound && prefs.vibrate ? 'warranty_expiry' : 'warranty_expiry_${prefs.sound ? 's' : 'q'}${prefs.vibrate ? 'v' : 'n'}';
    return NotificationDetails(
      android: AndroidNotificationDetails(
        id,
        'Warranty expiry alerts',
        channelDescription: 'Reminders before and at warranty expiry.',
        importance: Importance.max,
        priority: Priority.high,
        playSound: prefs.sound,
        enableVibration: prefs.vibrate,
        icon: '@mipmap/ic_launcher',
        styleInformation: bigText ? const BigTextStyleInformation('') : null,
      ),
    );
  }

  Future<void> rescheduleAll(List<Purchase> purchases) async {
    await initialize();
    await _plugin.cancelAll();
    final prefs = AppSettings.instance.notifications;
    if (!prefs.enabled) return;
    final now = DateTime.now();
    final store = await SharedPreferences.getInstance();
    for (final purchase in purchases) {
      // Catch-up alerts are only for warranties the app has not planned before
      // (newly added, edited or restored); otherwise a reminder that was already
      // delivered on time would be repeated.
      final seenKey = 'planned_${purchase.id}_${purchase.expiryDate}_${purchase.expiryTime}';
      final alreadySeen = store.getBool(seenKey) == true;
      for (final n in planNotifications(purchase, prefs, now)) {
        if (n.immediate) {
          if (n.id % 100 == kCatchUpSlot && alreadySeen) continue;
          await _showOnce(n, prefs);
        } else {
          await _schedule(n, prefs);
        }
      }
      if (!alreadySeen && purchase.id != null) await store.setBool(seenKey, true);
    }
  }

  Future<void> _showOnce(PlannedNotification n, NotificationPrefs prefs) async {
    final store = await SharedPreferences.getInstance();
    if (n.dedupeKey.isNotEmpty && store.getBool(n.dedupeKey) == true) return;
    await _plugin.show(n.id, n.title, n.body, _details(prefs, bigText: false));
    if (n.dedupeKey.isNotEmpty) await store.setBool(n.dedupeKey, true);
  }

  Future<void> _schedule(PlannedNotification n, NotificationPrefs prefs) async {
    final w = n.when;
    final scheduled = tz.TZDateTime(tz.local, w.year, w.month, w.day, w.hour, w.minute);
    if (!scheduled.isAfter(tz.TZDateTime.now(tz.local))) return;
    await _plugin.zonedSchedule(
      n.id,
      n.title,
      n.body,
      scheduled,
      _details(prefs),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
      payload: '${n.id}',
    );
  }

  /// Lets the user confirm that notifications and the chosen sound/vibration work.
  Future<void> showTestNotification({NotificationPrefs? prefs}) async {
    await initialize();
    await _plugin.show(
      kTestNotificationId,
      'WarrantyVault test reminder',
      'Notifications are working. Your warranty reminders will look like this.',
      _details(prefs ?? AppSettings.instance.notifications, bigText: false),
    );
  }
}
