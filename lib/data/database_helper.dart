import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import '../models/purchase.dart';

class DatabaseHelper {
  DatabaseHelper._();
  static final DatabaseHelper instance = DatabaseHelper._();

  /// Bump when the schema changes. Backups made by a newer app are refused.
  static const int schemaVersion = 4;
  static const String fileName = 'warrantyvault.db';

  Database? _database;
  Future<Database>? _opening;

  Future<Database> get database {
    final existing = _database;
    if (existing != null) return Future<Database>.value(existing);
    return _opening ??= _open().whenComplete(() => _opening = null);
  }

  Future<Database> _open() async {
    final root = await getDatabasesPath();
    final db = await openDatabase(
      p.join(root, fileName),
      version: schemaVersion,
      onConfigure: (db) async => db.execute('PRAGMA foreign_keys = ON'),
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute("ALTER TABLE purchases ADD COLUMN extended_warranty_months INTEGER NOT NULL DEFAULT 0");
          await db.execute("ALTER TABLE purchases ADD COLUMN serial_number TEXT NOT NULL DEFAULT ''");
          await db.execute("ALTER TABLE purchases ADD COLUMN covered_scopes TEXT NOT NULL DEFAULT ''");
          await db.execute("ALTER TABLE purchases ADD COLUMN support_hotline TEXT NOT NULL DEFAULT ''");
        }
        if (oldVersion < 3) {
          await db.execute("ALTER TABLE purchases ADD COLUMN warranty_duration_value INTEGER NOT NULL DEFAULT 12");
          await db.execute("ALTER TABLE purchases ADD COLUMN warranty_duration_unit TEXT NOT NULL DEFAULT 'months'");
          await db.execute("ALTER TABLE purchases ADD COLUMN expiry_time TEXT NOT NULL DEFAULT '09:00'");
        }
        if (oldVersion < 4) {
          await db.execute("ALTER TABLE purchases ADD COLUMN notify_enabled INTEGER NOT NULL DEFAULT 1");
          await _createImagesTable(db);
          // Carry every existing single receipt over into the new multi-photo table.
          await db.execute('''
            INSERT INTO purchase_images (purchase_id, path, position, created_at)
            SELECT id, receipt_path, 0, created_at FROM purchases WHERE receipt_path != ''
          ''');
        }
      },
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE categories (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL UNIQUE
          )
        ''');
        await db.execute('''
          CREATE TABLE purchases (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            category_id INTEGER NOT NULL,
            shop TEXT NOT NULL DEFAULT '',
            price REAL NOT NULL DEFAULT 0,
            purchase_date TEXT NOT NULL,
            warranty_months INTEGER NOT NULL DEFAULT 0,
            expiry_date TEXT NOT NULL,
            receipt_path TEXT NOT NULL DEFAULT '',
            notes TEXT NOT NULL DEFAULT '',
            created_at TEXT NOT NULL,
            extended_warranty_months INTEGER NOT NULL DEFAULT 0,
            serial_number TEXT NOT NULL DEFAULT '',
            covered_scopes TEXT NOT NULL DEFAULT '',
            support_hotline TEXT NOT NULL DEFAULT '',
            warranty_duration_value INTEGER NOT NULL DEFAULT 12,
            warranty_duration_unit TEXT NOT NULL DEFAULT 'months',
            expiry_time TEXT NOT NULL DEFAULT '09:00',
            notify_enabled INTEGER NOT NULL DEFAULT 1,
            FOREIGN KEY (category_id) REFERENCES categories(id)
          )
        ''');
        await _createImagesTable(db);
        final batch = db.batch();
        for (final name in ['Electronics', 'Appliances', 'Furniture', 'Other']) {
          batch.insert('categories', {'name': name}, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
        await batch.commit(noResult: true);
      },
    );
    _database = db;
    return db;
  }

  static Future<void> _createImagesTable(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE purchase_images (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        purchase_id INTEGER NOT NULL,
        path TEXT NOT NULL,
        position INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL,
        FOREIGN KEY (purchase_id) REFERENCES purchases(id) ON DELETE CASCADE
      )
    ''');
    await db.execute('CREATE INDEX idx_purchase_images_purchase ON purchase_images(purchase_id, position)');
  }

  Future<List<Map<String, Object?>>> getCategories() async {
    final db = await database;
    return db.query('categories', orderBy: 'id ASC');
  }

  Future<Map<int, List<String>>> _imagesByPurchase(DatabaseExecutor db) async {
    final rows = await db.query('purchase_images', orderBy: 'purchase_id ASC, position ASC, id ASC');
    final grouped = <int, List<String>>{};
    for (final row in rows) {
      final id = row['purchase_id'] as int;
      final path = (row['path'] as String?) ?? '';
      if (path.isEmpty) continue;
      grouped.putIfAbsent(id, () => <String>[]).add(path);
    }
    return grouped;
  }

  Purchase _withImages(Purchase purchase, Map<int, List<String>> grouped) {
    final images = grouped[purchase.id] ?? (purchase.receiptPath.isEmpty ? <String>[] : <String>[purchase.receiptPath]);
    return purchase.copyWith(imagePaths: images, receiptPath: images.isEmpty ? '' : images.first);
  }

  Future<List<Purchase>> getPurchases() async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT p.*, c.name AS category_name
      FROM purchases p JOIN categories c ON c.id = p.category_id
      ORDER BY p.created_at DESC, p.id DESC
    ''');
    final grouped = await _imagesByPurchase(db);
    return rows.map((row) => _withImages(Purchase.fromMap(row), grouped)).toList();
  }

  Future<Purchase?> getPurchase(int id) async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT p.*, c.name AS category_name
      FROM purchases p JOIN categories c ON c.id = p.category_id
      WHERE p.id = ? LIMIT 1
    ''', [id]);
    if (rows.isEmpty) return null;
    final grouped = await _imagesByPurchase(db);
    return _withImages(Purchase.fromMap(rows.first), grouped);
  }

  Future<void> _writeImages(DatabaseExecutor db, int purchaseId, List<String> images) async {
    await db.delete('purchase_images', where: 'purchase_id = ?', whereArgs: [purchaseId]);
    final now = DateTime.now().toIso8601String();
    for (var i = 0; i < images.length; i++) {
      await db.insert('purchase_images', {'purchase_id': purchaseId, 'path': images[i], 'position': i, 'created_at': now});
    }
  }

  Future<int> insertPurchase(Purchase purchase) async {
    final db = await database;
    final images = purchase.allImages;
    return db.transaction((txn) async {
      final map = purchase.toMap();
      map['receipt_path'] = images.isEmpty ? '' : images.first;
      final id = await txn.insert('purchases', map);
      await _writeImages(txn, id, images);
      return id;
    });
  }

  Future<int> updatePurchase(Purchase purchase) async {
    final db = await database;
    final images = purchase.allImages;
    return db.transaction((txn) async {
      final map = purchase.toMap();
      map['receipt_path'] = images.isEmpty ? '' : images.first;
      final count = await txn.update('purchases', map, where: 'id = ?', whereArgs: [purchase.id]);
      if (purchase.id != null) await _writeImages(txn, purchase.id!, images);
      return count;
    });
  }

  Future<void> deletePurchase(int id) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('purchase_images', where: 'purchase_id = ?', whereArgs: [id]);
      await txn.delete('purchases', where: 'id = ?', whereArgs: [id]);
    });
  }

  Future<int> purchaseCount() async {
    final db = await database;
    return Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM purchases')) ?? 0;
  }

  /// Every photo path referenced by the database (used to find unused files).
  Future<Set<String>> referencedImagePaths() async {
    final db = await database;
    final result = <String>{};
    for (final row in await db.query('purchase_images', columns: ['path'])) {
      final path = (row['path'] as String?) ?? '';
      if (path.isNotEmpty) result.add(path);
    }
    for (final row in await db.query('purchases', columns: ['receipt_path'])) {
      final path = (row['receipt_path'] as String?) ?? '';
      if (path.isNotEmpty) result.add(path);
    }
    return result;
  }

  /// After a restore the app folder may differ from the one stored in the
  /// backup. Re-point every photo to [receiptsDir] and drop rows whose file
  /// did not come along with the backup.
  Future<void> rebaseImagePaths(String receiptsDir) async {
    final db = await database;
    await db.transaction((txn) async {
      final images = await txn.query('purchase_images');
      for (final row in images) {
        final id = row['id'] as int;
        final old = (row['path'] as String?) ?? '';
        final candidate = p.join(receiptsDir, p.basename(old));
        if (old.isNotEmpty && File(candidate).existsSync()) {
          if (candidate != old) {
            await txn.update('purchase_images', {'path': candidate}, where: 'id = ?', whereArgs: [id]);
          }
        } else {
          await txn.delete('purchase_images', where: 'id = ?', whereArgs: [id]);
        }
      }
      final purchases = await txn.query('purchases', columns: ['id']);
      for (final row in purchases) {
        final pid = row['id'] as int;
        final first = await txn.query('purchase_images',
            columns: ['path'], where: 'purchase_id = ?', whereArgs: [pid], orderBy: 'position ASC, id ASC', limit: 1);
        final cover = first.isEmpty ? '' : (first.first['path'] as String? ?? '');
        await txn.update('purchases', {'receipt_path': cover}, where: 'id = ?', whereArgs: [pid]);
      }
    });
  }

  /// Merge the write-ahead log into the main file so a plain file copy is complete.
  Future<void> checkpoint() async {
    final db = _database;
    if (db == null) return;
    try {
      await db.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
    } catch (_) {
      // Not in WAL mode (or unsupported): nothing to merge.
    }
  }

  Future<void> close() async {
    await _database?.close();
    _database = null;
  }
}
