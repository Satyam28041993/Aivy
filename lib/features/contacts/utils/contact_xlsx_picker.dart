import 'dart:typed_data';

import 'contact_xlsx_picker_stub.dart'
    if (dart.library.html) 'contact_xlsx_picker_web.dart'
    if (dart.library.io) 'contact_xlsx_picker_io.dart' as impl;

/// Picks a single `.xlsx` file and returns its bytes (or null if cancelled).
Future<Uint8List?> pickXlsxBytes() => impl.pickXlsxBytes();
