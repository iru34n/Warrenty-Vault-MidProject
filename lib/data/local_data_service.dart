import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import '../models/purchase.dart';
import 'database_helper.dart';

/// One selectable column of the CSV export. The first twelve keep the exact
/// header names of the original export so existing spreadsheets still match.
class CsvColumn {
  final String key;
  final String header;
  final String label;
  final String Function(Purchase) value;
  const CsvColumn(this.key, this.header, this.label, this.value);
}

final List<CsvColumn> csvColumnDefs = [
  CsvColumn('item', 'Item', 'Item name', (x) => x.name),
  CsvColumn('category', 'Category', 'Category', (x) => x.categoryName),
  CsvColumn('seller', 'Seller', 'Shop / seller', (x) => x.shop),
  CsvColumn('price', 'Price_Rs', 'Purchase price', (x) => x.price.toString()),
  CsvColumn('purchase_date', 'Purchase_Date', 'Purchase date', (x) => x.purchaseDate),
  CsvColumn('warranty_months', 'Warranty_Months', 'Warranty (months)', (x) => x.warrantyMonths.toString()),
  CsvColumn('extended_months', 'Extended_Months', 'Extended warranty (months)', (x) => x.extendedWarrantyMonths.toString()),
  CsvColumn('expiry_date', 'Expiry_Date', 'Expiry date', (x) => x.expiryDate),
  CsvColumn('serial', 'Serial_Number', 'Serial number', (x) => x.serialNumber),
  CsvColumn('coverage', 'Coverage', 'What is covered', (x) => x.coveredScopes),
  CsvColumn('support', 'Support', 'Support hotline', (x) => x.supportHotline),
  CsvColumn('notes', 'Notes', 'Notes', (x) => x.notes),
  CsvColumn('duration', 'Warranty_Duration', 'Warranty duration (as entered)', (x) => '${x.warrantyDurationValue} ${x.warrantyDurationUnit}'),
  CsvColumn('expiry_time', 'Expiry_Time', 'Expiry time', (x) => x.expiryTime),
  CsvColumn('status', 'Status', 'Status (Active / Expiring Soon / Expired)', (x) => warrantyStatus(x.expiryDate)),
  CsvColumn('days_left', 'Days_Left', 'Days left', (x) => daysUntilExpiry(x.expiryDate).toString()),
  CsvColumn('photos', 'Photos', 'Number of photos', (x) => x.allImages.length.toString()),
];

List<String> get allCsvColumnKeys => csvColumnDefs.map((c) => c.key).toList();

/// Applies the status / category filters chosen on the export screen.
List<Purchase> filterForExport(List<Purchase> items, {String status = 'All', String category = 'All'}) => items.where((x) {
      final okStatus = status == 'All' || warrantyStatus(x.expiryDate) == status;
      final okCategory = category == 'All' || x.categoryName == category;
      return okStatus && okCategory;
    }).toList();

String _csvCell(String value) => '"${value.replaceAll('"', '""')}"';

/// Builds the CSV text. An empty [columnKeys] list means "all columns".
String buildCsv(List<Purchase> items, List<String> columnKeys) {
  final chosen = <CsvColumn>[];
  if (columnKeys.isEmpty) {
    chosen.addAll(csvColumnDefs);
  } else {
    for (final key in columnKeys) {
      for (final def in csvColumnDefs) {
        if (def.key == key) {
          chosen.add(def);
          break;
        }
      }
    }
    if (chosen.isEmpty) chosen.addAll(csvColumnDefs);
  }
  final rows = <List<String>>[chosen.map((c) => c.header).toList()];
  for (final item in items) {
    rows.add(chosen.map((c) => c.value(item)).toList());
  }
  return rows.map((r) => r.map(_csvCell).join(',')).join('\r\n');
}

/// SQLite files always start with this 16-byte header.
bool looksLikeSqlite(List<int> bytes) {
  const header = 'SQLite format 3\u0000';
  if (bytes.length < header.length) return false;
  for (var i = 0; i < header.length; i++) {
    if (bytes[i] != header.codeUnitAt(i)) return false;
  }
  return true;
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

class StorageReport {
  final int itemCount;
  final int dbBytes;
  final int photoCount;
  final int photoBytes;
  final int cacheBytes;
  final int orphanCount;
  final int orphanBytes;
  const StorageReport({
    required this.itemCount,
    required this.dbBytes,
    required this.photoCount,
    required this.photoBytes,
    required this.cacheBytes,
    required this.orphanCount,
    required this.orphanBytes,
  });
  int get totalBytes => dbBytes + photoBytes;
}

class LocalDataService {
  LocalDataService._();
  static final LocalDataService instance = LocalDataService._();

  Future<Directory> receiptsDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'receipts'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Copies a picked / captured image into the app's private receipts folder.
  Future<String> saveImageToReceipts(String sourcePath) async {
    final dir = await receiptsDir();
    var ext = p.extension(sourcePath);
    if (ext.isEmpty) ext = '.jpg';
    var target = p.join(dir.path, 'receipt_${DateTime.now().microsecondsSinceEpoch}$ext');
    var n = 0;
    while (await File(target).exists()) {
      n++;
      target = p.join(dir.path, 'receipt_${DateTime.now().microsecondsSinceEpoch}_$n$ext');
    }
    await File(sourcePath).copy(target);
    return target;
  }

  Future<void> deleteImageFiles(Iterable<String> paths) async {
    for (final path in paths) {
      if (path.isEmpty) continue;
      try {
        final f = File(path);
        if (await f.exists()) await f.delete();
      } catch (_) {
        // A file that cannot be removed is harmless; the clean-up tool finds it later.
      }
    }
  }

  Future<File> _dbFile() async => File(p.join(await getDatabasesPath(), DatabaseHelper.fileName));

  /// Builds a ZIP with the database, optional photos, a manifest and optional CSV.
  Future<File> buildArchive({
    required bool includePhotos,
    required String fileName,
    bool includeCsv = false,
  }) async {
    final purchases = await DatabaseHelper.instance.getPurchases();
    await DatabaseHelper.instance.checkpoint();
    final dbFile = await _dbFile();
    if (!await dbFile.exists()) throw Exception('Warranty database not found.');
    final archive = Archive();
    final dbBytes = await dbFile.readAsBytes();
    archive.addFile(ArchiveFile('warrantyvault.db', dbBytes.length, dbBytes));
    var photoCount = 0;
    if (includePhotos) {
      final receipts = await receiptsDir();
      await for (final entity in receipts.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          final bytes = await entity.readAsBytes();
          archive.addFile(ArchiveFile('receipts/${p.basename(entity.path)}', bytes.length, bytes));
          photoCount++;
        }
      }
    }
    if (includeCsv) {
      final csv = utf8.encode('\uFEFF${buildCsv(purchases, const [])}');
      archive.addFile(ArchiveFile('WarrantyVault_summary.csv', csv.length, csv));
    }
    final manifest = utf8.encode(jsonEncode({
      'app': 'WarrantyVault',
      'schema': DatabaseHelper.schemaVersion,
      'created': DateTime.now().toIso8601String(),
      'items': purchases.length,
      'photos': photoCount,
      'includesPhotos': includePhotos,
    }));
    archive.addFile(ArchiveFile('manifest.json', manifest.length, manifest));
    final encoded = ZipEncoder().encode(archive);
    if (encoded == null) throw Exception('Could not create backup archive.');
    final temp = await getTemporaryDirectory();
    final out = File(p.join(temp.path, fileName));
    await out.writeAsBytes(encoded, flush: true);
    return out;
  }

  Future<int> _dirSize(Directory dir, {bool Function(File)? where}) async {
    var total = 0;
    if (!await dir.exists()) return 0;
    try {
      await for (final e in dir.list(recursive: true, followLinks: false)) {
        if (e is File && (where == null || where(e))) {
          try {
            total += await e.length();
          } catch (_) {}
        }
      }
    } catch (_) {}
    return total;
  }

  Future<List<File>> _orphanFiles() async {
    final receipts = await receiptsDir();
    final referenced = (await DatabaseHelper.instance.referencedImagePaths()).map((e) => p.basename(e)).toSet();
    final orphans = <File>[];
    await for (final e in receipts.list(recursive: false, followLinks: false)) {
      if (e is File && !referenced.contains(p.basename(e.path))) orphans.add(e);
    }
    return orphans;
  }

  Future<StorageReport> storageReport() async {
    final db = await _dbFile();
    final dbBytes = await db.exists() ? await db.length() : 0;
    final receipts = await receiptsDir();
    var photoCount = 0;
    final photoBytes = await _dirSize(receipts, where: (f) {
      photoCount++;
      return true;
    });
    final cacheBytes = await _dirSize(await getTemporaryDirectory());
    final orphans = await _orphanFiles();
    var orphanBytes = 0;
    for (final f in orphans) {
      try {
        orphanBytes += await f.length();
      } catch (_) {}
    }
    return StorageReport(
      itemCount: await DatabaseHelper.instance.purchaseCount(),
      dbBytes: dbBytes,
      photoCount: photoCount,
      photoBytes: photoBytes,
      cacheBytes: cacheBytes,
      orphanCount: orphans.length,
      orphanBytes: orphanBytes,
    );
  }

  /// Deletes photo files that no purchase refers to. Returns the bytes freed.
  Future<int> removeOrphans() async {
    var freed = 0;
    for (final f in await _orphanFiles()) {
      try {
        final size = await f.length();
        await f.delete();
        freed += size;
      } catch (_) {}
    }
    return freed;
  }

  /// Empties the temporary folder (old exports, picker copies). Returns bytes freed.
  Future<int> clearCache() async {
    final temp = await getTemporaryDirectory();
    var freed = 0;
    if (!await temp.exists()) return 0;
    await for (final e in temp.list(followLinks: false)) {
      try {
        if (e is File) {
          freed += await e.length();
          await e.delete();
        } else if (e is Directory) {
          freed += await _dirSize(e);
          await e.delete(recursive: true);
        }
      } catch (_) {}
    }
    return freed;
  }

  /// Writes the CSV to a temp file and returns it, ready to share.
  Future<File> writeCsvFile(String csv, {bool bom = true}) async {
    final dir = await getTemporaryDirectory();
    final file = File(p.join(dir.path, 'WarrantyVault_export.csv'));
    await file.writeAsString(bom ? '\uFEFF$csv' : csv, flush: true);
    return file;
  }
}
