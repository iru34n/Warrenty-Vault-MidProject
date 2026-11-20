import '../lib/models/purchase.dart';

Purchase makePurchase({
  int? id = 5,
  String name = 'Phone',
  String category = 'Electronics',
  String expiryDate = '2026-12-31',
  String expiryTime = '09:00',
  bool notify = true,
  String receiptPath = '',
  List<String> images = const [],
  double price = 1500,
  String notes = '',
}) =>
    Purchase(
      id: id,
      name: name,
      categoryId: 1,
      categoryName: category,
      shop: 'Shop',
      price: price,
      purchaseDate: '2026-01-01',
      warrantyMonths: 12,
      expiryDate: expiryDate,
      createdAt: '2026-01-01T10:00:00',
      expiryTime: expiryTime,
      notifyEnabled: notify,
      receiptPath: receiptPath,
      imagePaths: images,
      notes: notes,
    );

String daysFromToday(int days) {
  final t = DateTime.now();
  return dateToDb(DateTime(t.year, t.month, t.day + days));
}
