class Purchase {
  final int? id;
  final String name;
  final int categoryId;
  final String categoryName;
  final String shop;
  final double price;
  final String purchaseDate; // yyyy-MM-dd
  final int warrantyMonths;
  final String expiryDate; // yyyy-MM-dd
  final String receiptPath;
  final String notes;
  final String createdAt;
  final int extendedWarrantyMonths;
  final String serialNumber;
  final String coveredScopes;
  final String supportHotline;
  final int warrantyDurationValue;
  final String warrantyDurationUnit;
  final String expiryTime;
  final bool notifyEnabled;
  /// Every photo attached to this purchase, in display order (first = cover).
  final List<String> imagePaths;

  const Purchase({
    this.id,
    required this.name,
    required this.categoryId,
    required this.categoryName,
    required this.shop,
    required this.price,
    required this.purchaseDate,
    required this.warrantyMonths,
    required this.expiryDate,
    this.receiptPath = '',
    this.notes = '',
    required this.createdAt,
    this.extendedWarrantyMonths = 0,
    this.serialNumber = '',
    this.coveredScopes = '',
    this.supportHotline = '',
    this.warrantyDurationValue = 12,
    this.warrantyDurationUnit = 'months',
    this.expiryTime = '09:00',
    this.notifyEnabled = true,
    this.imagePaths = const [],
  });

  /// All photos. Falls back to the legacy single receipt for older records.
  List<String> get allImages {
    if (imagePaths.isNotEmpty) return imagePaths;
    return receiptPath.isEmpty ? const <String>[] : <String>[receiptPath];
  }

  Purchase copyWith({
    List<String>? imagePaths,
    String? receiptPath,
    bool? notifyEnabled,
    String? name,
    String? expiryDate,
    String? expiryTime,
  }) =>
      Purchase(
        id: id,
        name: name ?? this.name,
        categoryId: categoryId,
        categoryName: categoryName,
        shop: shop,
        price: price,
        purchaseDate: purchaseDate,
        warrantyMonths: warrantyMonths,
        expiryDate: expiryDate ?? this.expiryDate,
        receiptPath: receiptPath ?? this.receiptPath,
        notes: notes,
        createdAt: createdAt,
        extendedWarrantyMonths: extendedWarrantyMonths,
        serialNumber: serialNumber,
        coveredScopes: coveredScopes,
        supportHotline: supportHotline,
        warrantyDurationValue: warrantyDurationValue,
        warrantyDurationUnit: warrantyDurationUnit,
        expiryTime: expiryTime ?? this.expiryTime,
        notifyEnabled: notifyEnabled ?? this.notifyEnabled,
        imagePaths: imagePaths ?? this.imagePaths,
      );

  factory Purchase.fromMap(Map<String, Object?> map) => Purchase(
        id: map['id'] as int?,
        name: map['name'] as String? ?? '',
        categoryId: map['category_id'] as int? ?? 4,
        categoryName: map['category_name'] as String? ?? 'Other',
        shop: map['shop'] as String? ?? '',
        price: (map['price'] as num?)?.toDouble() ?? 0,
        purchaseDate: map['purchase_date'] as String? ?? '',
        warrantyMonths: map['warranty_months'] as int? ?? 0,
        expiryDate: map['expiry_date'] as String? ?? '',
        receiptPath: map['receipt_path'] as String? ?? '',
        notes: map['notes'] as String? ?? '',
        createdAt: map['created_at'] as String? ?? '',
        extendedWarrantyMonths: map['extended_warranty_months'] as int? ?? 0,
        serialNumber: map['serial_number'] as String? ?? '',
        coveredScopes: map['covered_scopes'] as String? ?? '',
        supportHotline: map['support_hotline'] as String? ?? '',
        warrantyDurationValue: map['warranty_duration_value'] as int? ?? (map['warranty_months'] as int? ?? 12),
        warrantyDurationUnit: map['warranty_duration_unit'] as String? ?? 'months',
        expiryTime: map['expiry_time'] as String? ?? '09:00',
        notifyEnabled: ((map['notify_enabled'] as int?) ?? 1) != 0,
      );

  Map<String, Object?> toMap() => {
        'name': name,
        'category_id': categoryId,
        'shop': shop,
        'price': price,
        'purchase_date': purchaseDate,
        'warranty_months': warrantyMonths,
        'expiry_date': expiryDate,
        'receipt_path': receiptPath,
        'notes': notes,
        'created_at': createdAt,
        'extended_warranty_months': extendedWarrantyMonths,
        'serial_number': serialNumber,
        'covered_scopes': coveredScopes,
        'support_hotline': supportHotline,
        'warranty_duration_value': warrantyDurationValue,
        'warranty_duration_unit': warrantyDurationUnit,
        'expiry_time': expiryTime,
        'notify_enabled': notifyEnabled ? 1 : 0,
      };
}

/// How many days before expiry a warranty counts as "Expiring Soon".
/// Changed from Settings > Expiry notifications (default 30).
int expiringSoonWindowDays = 30;

DateTime addMonthsClamped(DateTime date, int months) {
  final monthIndex = date.month - 1 + months;
  final year = date.year + monthIndex ~/ 12;
  final month = monthIndex % 12 + 1;
  final lastDay = DateTime(year, month + 1, 0).day;
  return DateTime(year, month, date.day > lastDay ? lastDay : date.day);
}

String dateToDb(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

DateTime parseDbDate(String value) => DateTime.tryParse(value) ?? DateTime.now();

String warrantyStatus(String expiryDate) {
  final today = DateTime.now();
  final d = parseDbDate(expiryDate);
  final days = DateTime(d.year, d.month, d.day)
      .difference(DateTime(today.year, today.month, today.day))
      .inDays;
  if (days < 0) return 'Expired';
  if (days <= expiringSoonWindowDays) return 'Expiring Soon';
  return 'Active';
}

int daysUntilExpiry(String expiryDate) {
  final today = DateTime.now();
  final d = parseDbDate(expiryDate);
  return DateTime(d.year, d.month, d.day)
      .difference(DateTime(today.year, today.month, today.day))
      .inDays;
}


/// Calendar-aware countdown shown on warranty cards and detail screens.
String warrantyTimeLeft(String expiryDate) {
  final expiry = parseDbDate(expiryDate);
  final todayNow = DateTime.now();
  final today = DateTime(todayNow.year, todayNow.month, todayNow.day);
  final target = DateTime(expiry.year, expiry.month, expiry.day);
  if (target.isBefore(today)) {
    final n = today.difference(target).inDays;
    return n == 1 ? 'Expired 1 day ago' : 'Expired $n days ago';
  }
  if (target == today) return 'Expires today';
  var cursor = today;
  var months = 0;
  while (true) {
    final next = addMonthsClamped(cursor, 1);
    if (next.isAfter(target) || next.isAtSameMomentAs(cursor)) break;
    cursor = next;
    months++;
  }
  final remainingDays = target.difference(cursor).inDays;
  final weeks = remainingDays ~/ 7;
  final days = remainingDays % 7;
  final parts = <String>[];
  if (months > 0) parts.add('$months ${months == 1 ? 'month' : 'months'}');
  if (weeks > 0) parts.add('$weeks ${weeks == 1 ? 'week' : 'weeks'}');
  if (days > 0) parts.add('$days ${days == 1 ? 'day' : 'days'}');
  return '${parts.join(', ')} left';
}
