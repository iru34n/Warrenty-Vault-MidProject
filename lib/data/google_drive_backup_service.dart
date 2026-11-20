import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'app_settings.dart';
import 'database_helper.dart';
import 'local_data_service.dart';

const String kBackupPrefix = 'WarrantyVault_backup';

/// A readable error that can be shown to the user as-is.
class BackupException implements Exception {
  final String message;
  const BackupException(this.message);
  @override
  String toString() => message;
}

class DriveBackupInfo {
  final String id;
  final String name;
  final DateTime? modified;
  final int sizeBytes;
  const DriveBackupInfo({required this.id, required this.name, this.modified, this.sizeBytes = 0});
}

bool isBackupFileName(String name) => name.startsWith(kBackupPrefix) && name.toLowerCase().endsWith('.zip');

/// Newest first. Backups without a date go last.
List<DriveBackupInfo> sortNewestFirst(List<DriveBackupInfo> items) {
  final copy = List<DriveBackupInfo>.of(items);
  copy.sort((a, b) {
    final x = a.modified;
    final y = b.modified;
    if (x == null && y == null) return 0;
    if (x == null) return 1;
    if (y == null) return -1;
    return y.compareTo(x);
  });
  return copy;
}

/// Which backups to delete so only the newest [keep] remain (always keeps at least one).
List<DriveBackupInfo> pickBackupsToDelete(List<DriveBackupInfo> items, int keep) {
  final limit = keep < 1 ? 1 : keep;
  final sorted = sortNewestFirst(items);
  return sorted.length <= limit ? <DriveBackupInfo>[] : sorted.sublist(limit);
}

String backupFileName(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${kBackupPrefix}_${t.year}${two(t.month)}${two(t.day)}_${two(t.hour)}${two(t.minute)}${two(t.second)}.zip';
}

/// Turns Google / network errors into something a person can act on.
String friendlyBackupError(Object e) {
  if (e is BackupException) return e.message;
  if (e is PlatformException) {
    final text = '${e.code} ${e.message ?? ''}';
    if (text.contains('ApiException: 10') || text.contains(': 10:') || text.contains('DEVELOPER_ERROR')) {
      return 'Google sign-in is not set up for this build of the app (error 10). Add this build\'s SHA-1 fingerprint to your Google Cloud Android OAuth client. See SETUP_NOTES.md.';
    }
    if (text.contains('12500')) {
      return 'Google sign-in failed (12500). Set a support email on the OAuth consent screen and add your Google account as a test user.';
    }
    if (text.contains('12501') || text.contains('sign_in_canceled')) return 'Google sign-in was cancelled.';
    if (text.contains('network_error') || text.contains('ApiException: 7')) return 'No internet connection. Check your network and try again.';
    return 'Google sign-in failed: ${e.message ?? e.code}';
  }
  if (e is drive.DetailedApiRequestError) {
    final status = e.status;
    final message = e.message ?? '';
    if (status == 401) return 'Your Google session expired. Please try again and sign in.';
    if (status == 403) {
      if (message.contains('has not been used') || message.contains('accessNotConfigured') || message.contains('disabled')) {
        return 'The Google Drive API is not enabled for your Google Cloud project. Enable it in the Cloud Console.';
      }
      if (message.contains('quota') || message.contains('storageQuota')) return 'Your Google Drive storage is full.';
      return 'Google Drive denied access. Sign in again and allow WarrantyVault to manage its own files.';
    }
    if (status == 404) return 'That backup no longer exists in Google Drive.';
    return 'Google Drive error ($status). ${message.isEmpty ? 'Please try again.' : message}';
  }
  if (e is SocketException || e is http.ClientException) return 'No internet connection. Check your network and try again.';
  if (e is TimeoutException) return 'The request timed out. Please try again.';
  return e.toString().replaceFirst('Exception: ', '');
}

/// Google Drive backup using the least-privilege drive.file scope.
/// Android OAuth must be configured first; see SETUP_NOTES.md.
class GoogleDriveBackupService {
  GoogleDriveBackupService._();
  static final instance = GoogleDriveBackupService._();
  final GoogleSignIn _googleSignIn = GoogleSignIn(scopes: [drive.DriveApi.driveFileScope]);
  bool _autoRunning = false;

  // ---------------------------------------------------------------- account

  Future<GoogleSignInAccount> _account({required bool interactive}) async {
    var account = _googleSignIn.currentUser;
    account ??= await _googleSignIn.signInSilently();
    if (account == null && interactive) account = await _googleSignIn.signIn();
    if (account == null) throw const BackupException('Google sign-in was cancelled.');
    return account;
  }

  /// The signed-in Google account, or null. Never shows a sign-in screen.
  Future<String?> signedInEmail() async {
    try {
      final account = _googleSignIn.currentUser ?? await _googleSignIn.signInSilently();
      return account?.email;
    } catch (_) {
      return null;
    }
  }

  Future<String?> signIn() async {
    try {
      final account = await _googleSignIn.signIn();
      return account?.email;
    } catch (e) {
      throw BackupException(friendlyBackupError(e));
    }
  }

  Future<String?> switchAccount() async {
    try {
      await _googleSignIn.signOut();
      final account = await _googleSignIn.signIn();
      return account?.email;
    } catch (e) {
      throw BackupException(friendlyBackupError(e));
    }
  }

  Future<void> signOut() async {
    try {
      await _googleSignIn.signOut();
    } catch (_) {}
  }

  Future<T> _withApi<T>(Future<T> Function(drive.DriveApi api) action, {bool interactive = true}) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      final account = await _account(interactive: interactive);
      final client = _GoogleAuthClient(await account.authHeaders);
      try {
        return await action(drive.DriveApi(client));
      } on drive.DetailedApiRequestError catch (e) {
        if (e.status == 401 && attempt == 0) {
          await account.clearAuthCache();
          continue;
        }
        rethrow;
      } finally {
        client.close();
      }
    }
    throw const BackupException('Could not authorise with Google Drive.');
  }

  Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on BackupException {
      rethrow;
    } catch (e) {
      throw BackupException(friendlyBackupError(e));
    }
  }

  // ---------------------------------------------------------------- listing

  Future<List<DriveBackupInfo>> _list(drive.DriveApi api) async {
    final result = await api.files.list(
      q: "name contains 'WarrantyVault' and trashed = false",
      orderBy: 'modifiedTime desc',
      pageSize: 100,
      spaces: 'drive',
      $fields: 'files(id,name,size,modifiedTime)',
    );
    final out = <DriveBackupInfo>[];
    for (final f in result.files ?? <drive.File>[]) {
      final id = f.id;
      final name = f.name ?? '';
      if (id == null || !isBackupFileName(name)) continue;
      out.add(DriveBackupInfo(id: id, name: name, modified: f.modifiedTime, sizeBytes: int.tryParse(f.size ?? '') ?? 0));
    }
    return sortNewestFirst(out);
  }

  Future<List<DriveBackupInfo>> listBackups() => _guard(() => _withApi((api) => _list(api)));

  Future<void> deleteBackup(String id) => _guard(() => _withApi((api) => api.files.delete(id)));

  // ----------------------------------------------------------------- backup

  Future<String> backupToDrive({bool interactive = true, bool? includePhotos, int? keepCount}) {
    final prefs = AppSettings.instance.backup;
    final photos = includePhotos ?? prefs.includePhotos;
    final keep = keepCount ?? prefs.keepCount;
    return _guard(() async {
      final name = backupFileName(DateTime.now());
      final zip = await LocalDataService.instance.buildArchive(includePhotos: photos, fileName: name);
      try {
        final size = await zip.length();
        await _withApi((api) async {
          final media = drive.Media(zip.openRead(), size);
          await api.files.create(drive.File(name: name), uploadMedia: media, $fields: 'id,name');
          // Keep only the newest backups so Drive does not fill up.
          final all = await _list(api);
          for (final old in pickBackupsToDelete(all, keep)) {
            try {
              await api.files.delete(old.id);
            } catch (_) {}
          }
        }, interactive: interactive);
        final current = AppSettings.instance.backup;
        await AppSettings.instance.saveBackup(current.copyWith(lastBackupMs: DateTime.now().millisecondsSinceEpoch));
        return 'Backup saved to Google Drive (${formatBytes(size)}).';
      } finally {
        if (await zip.exists()) await zip.delete();
      }
    });
  }

  /// Runs a backup in the background when automatic backup is on and due.
  /// Never throws and never shows a sign-in screen.
  Future<void> maybeAutoBackup() async {
    if (_autoRunning) return;
    if (!AppSettings.instance.backup.isAutoDue(DateTime.now())) return;
    _autoRunning = true;
    try {
      if (await signedInEmail() == null) return;
      await backupToDrive(interactive: false);
    } catch (_) {
      // Best effort: the next app start tries again.
    } finally {
      _autoRunning = false;
    }
  }

  // ---------------------------------------------------------------- restore

  Archive _decode(List<int> bytes) {
    try {
      return ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw const BackupException('The backup file is damaged or is not a WarrantyVault backup.');
    }
  }

  List<int> _bytesOf(ArchiveFile file) => (file.content as List).cast<int>();

  Future<void> _deleteIfExists(String path) async {
    final f = File(path);
    if (await f.exists()) await f.delete();
  }

  /// Opens the downloaded database read-only to make sure it is usable
  /// before the current vault is touched. Returns the number of items in it.
  Future<int> _verifyDatabase(List<int> dbBytes) async {
    if (!looksLikeSqlite(dbBytes)) throw const BackupException('The backup database is not valid.');
    final temp = await getTemporaryDirectory();
    final probe = File(p.join(temp.path, 'restore_check.db'));
    await probe.writeAsBytes(dbBytes, flush: true);
    Database? db;
    try {
      db = await openReadOnlyDatabase(probe.path);
      final tables = await db.rawQuery("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'purchases'");
      if (tables.isEmpty) throw const BackupException('The backup does not contain any warranty data.');
      final version = Sqflite.firstIntValue(await db.rawQuery('PRAGMA user_version')) ?? 0;
      if (version > DatabaseHelper.schemaVersion) {
        throw const BackupException('This backup was made by a newer version of WarrantyVault. Update the app, then restore again.');
      }
      return Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM purchases')) ?? 0;
    } on BackupException {
      rethrow;
    } catch (_) {
      throw const BackupException('The backup database could not be read.');
    } finally {
      await db?.close();
      if (await probe.exists()) await probe.delete();
    }
  }

  Future<String> restoreFromDrive({String? fileId}) {
    return _guard(() async {
      final bytes = await _withApi((api) async {
        final String id;
        if (fileId != null) {
          id = fileId;
        } else {
          final list = await _list(api);
          if (list.isEmpty) throw const BackupException('No WarrantyVault backup was found in this Google account.');
          id = list.first.id;
        }
        final response = await api.files.get(id, downloadOptions: drive.DownloadOptions.fullMedia);
        if (response is! drive.Media) throw const BackupException('Google Drive did not return a backup file.');
        final builder = BytesBuilder(copy: false);
        await for (final chunk in response.stream) {
          builder.add(chunk);
        }
        return builder.takeBytes();
      });
      return _applyBackup(bytes);
    });
  }

  Future<String> _applyBackup(List<int> zipBytes) async {
    final archive = _decode(zipBytes);
    ArchiveFile? dbEntry;
    for (final entry in archive.files) {
      if (entry.isFile && entry.name == 'warrantyvault.db') {
        dbEntry = entry;
        break;
      }
    }
    if (dbEntry == null) throw const BackupException('The backup does not contain a database.');
    final dbBytes = _bytesOf(dbEntry);
    await _verifyDatabase(dbBytes);

    final dbPath = p.join(await getDatabasesPath(), DatabaseHelper.fileName);
    final docs = await getApplicationDocumentsDirectory();
    final receiptsDir = Directory(p.join(docs.path, 'receipts'));
    final oldReceipts = Directory(p.join(docs.path, 'receipts_before_restore'));
    final safetyDb = File('$dbPath.before_restore');
    final dbFile = File(dbPath);

    // Keep a safety copy so a failed restore can be undone.
    await DatabaseHelper.instance.close();
    if (await oldReceipts.exists()) await oldReceipts.delete(recursive: true);
    await _deleteIfExists(safetyDb.path);
    final hadDb = await dbFile.exists();
    if (hadDb) await dbFile.copy(safetyDb.path);
    final hadReceipts = await receiptsDir.exists();
    if (hadReceipts) await receiptsDir.rename(oldReceipts.path);

    var restoredItems = 0;
    try {
      for (final suffix in ['-wal', '-shm', '-journal']) {
        await _deleteIfExists('$dbPath$suffix');
      }
      await dbFile.writeAsBytes(dbBytes, flush: true);
      await receiptsDir.create(recursive: true);
      for (final entry in archive.files) {
        if (!entry.isFile || !entry.name.startsWith('receipts/')) continue;
        final fileName = p.basename(entry.name);
        if (fileName.isEmpty) continue;
        await File(p.join(receiptsDir.path, fileName)).writeAsBytes(_bytesOf(entry), flush: true);
      }
      // Opening the database also upgrades backups made by older app versions.
      await DatabaseHelper.instance.rebaseImagePaths(receiptsDir.path);
      restoredItems = await DatabaseHelper.instance.purchaseCount();
      await DatabaseHelper.instance.close();
    } catch (_) {
      await DatabaseHelper.instance.close();
      for (final suffix in ['', '-wal', '-shm', '-journal']) {
        await _deleteIfExists('$dbPath$suffix');
      }
      if (hadDb && await safetyDb.exists()) await safetyDb.copy(dbPath);
      if (await receiptsDir.exists()) await receiptsDir.delete(recursive: true);
      if (hadReceipts && await oldReceipts.exists()) await oldReceipts.rename(receiptsDir.path);
      rethrow;
    }
    if (await oldReceipts.exists()) await oldReceipts.delete(recursive: true);
    await _deleteIfExists(safetyDb.path);
    return 'Backup restored ($restoredItems ${restoredItems == 1 ? 'item' : 'items'}). Returning to your vault.';
  }
}

class _GoogleAuthClient extends http.BaseClient {
  final Map<String, String> _headers;
  final http.Client _inner = http.Client();
  _GoogleAuthClient(this._headers);
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers.addAll(_headers);
    return _inner.send(request);
  }

  @override
  void close() {
    _inner.close();
  }
}
