import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../lib/data/app_settings.dart';
import '../lib/models/purchase.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => expiringSoonWindowDays = 30);

  test('first launch uses the original behaviour (7 days before at 9 AM + on expiry)', () async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.instance.load();
    final n = AppSettings.instance.notifications;
    expect(n.enabled, isTrue);
    expect(n.leadDays, [7]);
    expect((n.hour, n.minute), (9, 0));
    expect(n.notifyOnExpiry, isTrue);
    expect(expiringSoonWindowDays, 30);
  });

  test('notification choices survive a restart and update the expiring-soon window', () async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.instance.load();
    await AppSettings.instance.saveNotifications(const NotificationPrefs(leadDays: [30, 7, 1], hour: 18, minute: 15, sound: false, vibrate: false, catchUp: false, expiringSoonDays: 60));
    expect(expiringSoonWindowDays, 60);
    await AppSettings.instance.load(); // reads back what was saved
    final n = AppSettings.instance.notifications;
    expect(n.leadDays, [30, 7, 1]);
    expect((n.hour, n.minute), (18, 15));
    expect(n.sound, isFalse);
    expect(n.vibrate, isFalse);
    expect(n.catchUp, isFalse);
    expect(n.expiringSoonDays, 60);
    expect(expiringSoonWindowDays, 60);
  });

  test('backup and export choices survive a restart', () async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.instance.load();
    await AppSettings.instance.saveBackup(const BackupPrefs(includePhotos: false, keepCount: 5, autoFrequency: 'weekly', lastBackupMs: 123));
    await AppSettings.instance.saveExport(const ExportPrefs(csvColumns: ['item', 'price'], csvStatus: 'Expired', csvBom: false, zipIncludeCsv: true));
    await AppSettings.instance.load();
    final b = AppSettings.instance.backup;
    expect((b.includePhotos, b.keepCount, b.autoFrequency, b.lastBackupMs), (false, 5, 'weekly', 123));
    final e = AppSettings.instance.export;
    expect(e.csvColumns, ['item', 'price']);
    expect(e.csvStatus, 'Expired');
    expect(e.csvBom, isFalse);
    expect(e.zipIncludeCsv, isTrue);
  });

  test('garbage in saved settings is repaired, not trusted', () async {
    SharedPreferences.setMockInitialValues({'notif_lead_days': ['abc', '0', '14'], 'notif_hour': 99, 'backup_auto': 'hourly', 'backup_keep_count': 0});
    await AppSettings.instance.load();
    expect(AppSettings.instance.notifications.leadDays, [14]);
    expect(AppSettings.instance.notifications.hour, 23);
    expect(AppSettings.instance.backup.autoFrequency, 'off');
    expect(AppSettings.instance.backup.keepCount, 1);
  });
}
