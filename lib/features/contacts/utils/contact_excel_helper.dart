import 'dart:typed_data';

import 'package:excel/excel.dart';

import '../data/contact_service.dart';

/// Excel (.xlsx) template + import for Aivy contacts.
///
/// **Row 1** = headings: Name, Phone, Company, Email, Tags, Notes  
/// **Row 2+** = data. Phone: `91XXXXXXXXXX` or 10-digit Indian mobile.  
/// Tags: comma-separated inside one cell.
class ContactExcelHelper {
  ContactExcelHelper._();

  static const headers = [
    'Name',
    'Phone',
    'Company',
    'Email',
    'Tags',
    'Notes',
  ];

  /// Builds `.xlsx` bytes (heading row + one example row).
  static Uint8List buildTemplateBytes() {
    final excel = Excel.createExcel();
    final sheetName = excel.getDefaultSheet() ?? excel.tables.keys.first;
    final sheet = excel[sheetName];
    sheet.appendRow(
      headers.map((h) => TextCellValue(h)).toList(growable: false),
    );
    sheet.appendRow([
      TextCellValue('Sample Customer'),
      TextCellValue('919876543210'),
      TextCellValue('Acme Pvt Ltd'),
      TextCellValue(''),
      TextCellValue('vip, customer'),
      TextCellValue('Imported via Excel'),
    ]);
    final raw = excel.encode();
    if (raw == null) {
      throw StateError('Excel encode failed');
    }
    return Uint8List.fromList(raw);
  }

  /// Reads first sheet; row 0 = headers (matched flexibly); returns data rows only.
  static List<ContactImportRow> parseImportBytes(Uint8List bytes) {
    final excel = Excel.decodeBytes(bytes);
    if (excel.tables.isEmpty) {
      throw const FormatException('No sheet in workbook');
    }
    final sheet = excel.tables[excel.tables.keys.first]!;
    final rows = sheet.rows;
    if (rows.isEmpty) {
      return const [];
    }

    final headerCells = rows.first.map(_cellString).toList(growable: false);
    final idx = _HeaderIndex.fromRow(headerCells);

    final out = <ContactImportRow>[];
    for (var r = 1; r < rows.length; r++) {
      final line = rows[r];
      if (line.isEmpty) {
        continue;
      }
      String col(int i) {
        if (i < 0 || i >= line.length) {
          return '';
        }
        return _cellString(line[i]);
      }

      final name = col(idx.name);
      final phone = col(idx.phone);
      if (name.isEmpty && phone.isEmpty) {
        continue;
      }
      final tagsRaw = col(idx.tags);
      final tags = tagsRaw
          .split(RegExp(r'[,;]'))
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList(growable: false);
      out.add(
        ContactImportRow(
          name: name,
          phone: phone,
          company: col(idx.company),
          email: col(idx.email),
          tags: tags,
          notes: col(idx.notes),
        ),
      );
    }
    return out;
  }

  static String _cellString(Data? cell) {
    final v = cell?.value;
    if (v == null) {
      return '';
    }
    return v.toString().trim();
  }
}

class _HeaderIndex {
  const _HeaderIndex({
    required this.name,
    required this.phone,
    required this.company,
    required this.email,
    required this.tags,
    required this.notes,
  });

  final int name;
  final int phone;
  final int company;
  final int email;
  final int tags;
  final int notes;

  factory _HeaderIndex.fromRow(List<String> cells) {
    int find(String key) {
      for (var i = 0; i < cells.length; i++) {
        if (cells[i].trim().toLowerCase() == key) {
          return i;
        }
      }
      return -1;
    }

    final n = find('name');
    final p = find('phone');
    if (n >= 0 && p >= 0) {
      return _HeaderIndex(
        name: n,
        phone: p,
        company: _or(find('company'), 2),
        email: _or(find('email'), 3),
        tags: _or(find('tags'), 4),
        notes: _or(find('notes'), 5),
      );
    }
    return const _HeaderIndex(
      name: 0,
      phone: 1,
      company: 2,
      email: 3,
      tags: 4,
      notes: 5,
    );
  }

  static int _or(int v, int fallback) => v >= 0 ? v : fallback;
}
