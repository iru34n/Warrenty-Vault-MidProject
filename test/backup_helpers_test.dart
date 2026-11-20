import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/data/app_settings.dart';
import '../lib/data/google_drive_backup_service.dart';
import '../lib/data/local_data_service.dart';

DriveBackupInfo info(String id, DateTime? t) => DriveBackupInfo(id: id, name: '${kBackupPrefix}_$id.zip', modified: t);

void main() {
  test('backup file names', () {
    expect(backupFileName(DateTime(2026, 3, 5, 7, 8, 9)), 'WarrantyVault_backup_20260305_070809.zip');
    expect(isBackupFileName('WarrantyVault_backup.zip'), isTrue); // the old single-file name still counts
    expect(isBackupFileName('WarrantyVault_backup_20260305_070809.ZIP'), isTrue);
    expect(isBackupFileName('holiday.zip'), isFalse);
    expect(isBackupFileName('WarrantyVault_backup_notes.txt'), isFalse);
  });

  group('retention', () {
    final list = [
      info('a', DateTime(2026, 1, 1)),
      info('d', DateTime(2026, 4, 1)),
      info('b', DateTime(2026, 2, 1)),
      info('c', DateTime(2026, 3, 1)),
      info('e', DateTime(2026, 5, 1)),
    ];
    test('sorted newest first', () {
      expect(sortNewestFirst(list).map((e) => e.id), ['e', 'd', 'c', 'b', 'a']);
    });
    test('keeps only the newest N', () {
      expect(pickBackupsToDelete(list, 3).map((e) => e.id), ['b', 'a']);
    });
    test('never deletes everything', () {
      expect(pickBackupsToDelete(list, 0).length, 4);
    });
    test('nothing to delete when under the limit', () {
      expect(pickBackupsToDelete(list, 10), isEmpty);
    });
    test('backups without a date are the first to go', () {
      final mixed = [info('x', null), info('y', DateTime(2026, 1, 1))];
      expect(pickBackupsToDelete(mixed, 1).map((e) => e.id), ['x']);
    });
  });

  group('automatic backup schedule', () {
    final now = DateTime(2026, 11, 20, 12);
    test('off is never due', () => expect(const BackupPrefs().isAutoDue(now), isFalse));
    test('due immediately when never backed up', () => expect(const BackupPrefs(autoFrequency: 'daily').isAutoDue(now), isTrue));
    test('weekly', () {
      final twoDays = now.subtract(const Duration(days: 2)).millisecondsSinceEpoch;
      final eightDays = now.subtract(const Duration(days: 8)).millisecondsSinceEpoch;
      expect(BackupPrefs(autoFrequency: 'weekly', lastBackupMs: twoDays).isAutoDue(now), isFalse);
      expect(BackupPrefs(autoFrequency: 'weekly', lastBackupMs: eightDays).isAutoDue(now), isTrue);
    });
    test('copyWith ignores unknown frequencies and clamps keep count', () {
      expect(const BackupPrefs().copyWith(autoFrequency: 'hourly').autoFrequency, 'off');
      expect(const BackupPrefs().copyWith(keepCount: 99).keepCount, 10);
    });
  });

  group('friendly Google errors', () {
    test('error 10 (SHA-1 not registered)', () {
      final e = PlatformException(code: 'sign_in_failed', message: 'com.google.android.gms.common.api.ApiException: 10: ');
      expect(friendlyBackupError(e), contains('error 10'));
    });
    test('error 12500 (consent screen)', () {
      final e = PlatformException(code: 'sign_in_failed', message: 'ApiException: 12500: ');
      expect(friendlyBackupError(e), contains('12500'));
    });
    test('cancelled', () {
      expect(friendlyBackupError(PlatformException(code: 'sign_in_canceled')), contains('cancelled'));
    });
    test('network', () {
      expect(friendlyBackupError(PlatformException(code: 'network_error')), contains('internet'));
    });
    test('plain exceptions lose the "Exception:" prefix', () {
      expect(friendlyBackupError(Exception('boom')), 'boom');
      expect(friendlyBackupError(const BackupException('mine')), 'mine');
    });
  });

  test('looksLikeSqlite', () {
    final header = 'SQLite format 3\u0000'.codeUnits;
    expect(looksLikeSqlite([...header, 1, 2, 3]), isTrue);
    expect(looksLikeSqlite(header.take(5).toList()), isFalse);
    expect(looksLikeSqlite(List<int>.filled(40, 7)), isFalse);
  });

  test('formatBytes', () {
    expect(formatBytes(512), '512 B');
    expect(formatBytes(2048), '2.0 KB');
    expect(formatBytes(5 * 1024 * 1024), '5.00 MB');
  });
}
