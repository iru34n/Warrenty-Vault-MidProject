import 'package:flutter_test/flutter_test.dart';
import '../lib/data/local_data_service.dart';
import '_fixtures.dart';

void main() {
  test('default (empty) selection exports every column', () {
    final csv = buildCsv([makePurchase()], const []);
    final header = csv.split('\r\n').first;
    expect(header.split(',').length, csvColumnDefs.length);
  });

  test('the first 12 columns keep the original export header names', () {
    final header = buildCsv([], allCsvColumnKeys.take(12).toList());
    expect(header, '"Item","Category","Seller","Price_Rs","Purchase_Date","Warranty_Months","Extended_Months","Expiry_Date","Serial_Number","Coverage","Support","Notes"');
  });

  test('only the chosen columns, in the app\'s order', () {
    final csv = buildCsv([makePurchase(name: 'TV')], ['expiry_date', 'item']);
    final lines = csv.split('\r\n');
    expect(lines[0], '"Expiry_Date","Item"');
    expect(lines[1], '"2026-12-31","TV"');
  });

  test('unknown keys are ignored; all-unknown falls back to everything', () {
    expect(buildCsv([makePurchase()], ['nope']).split('\r\n').first.split(',').length, csvColumnDefs.length);
  });

  test('quotes, commas and line breaks stay inside their cell', () {
    final csv = buildCsv([makePurchase(name: 'He said "hi", ok', notes: 'line1\nline2')], ['item', 'notes']);
    expect(csv.split('\r\n')[1], '"He said ""hi"", ok","line1\nline2"');
  });

  test('photo count column', () {
    final csv = buildCsv([makePurchase(images: ['a', 'b', 'c'])], ['photos']);
    expect(csv.split('\r\n')[1], '"3"');
  });

  group('filters', () {
    final items = [
      makePurchase(id: 1, name: 'Active TV', category: 'Electronics', expiryDate: daysFromToday(200)),
      makePurchase(id: 2, name: 'Old fridge', category: 'Appliances', expiryDate: daysFromToday(-5)),
      makePurchase(id: 3, name: 'Soon phone', category: 'Electronics', expiryDate: daysFromToday(3)),
    ];
    test('by status', () {
      expect(filterForExport(items, status: 'Expired').map((e) => e.name), ['Old fridge']);
      expect(filterForExport(items, status: 'Expiring Soon').map((e) => e.name), ['Soon phone']);
    });
    test('by category', () {
      expect(filterForExport(items, category: 'Electronics').length, 2);
    });
    test('both together, and "All" means no filter', () {
      expect(filterForExport(items, status: 'Active', category: 'Electronics').map((e) => e.name), ['Active TV']);
      expect(filterForExport(items).length, 3);
    });
  });
}
