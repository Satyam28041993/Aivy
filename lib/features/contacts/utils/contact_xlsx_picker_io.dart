import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

Future<Uint8List?> pickXlsxBytes() async {
  final pick = await FilePicker.pickFiles(
    type: FileType.custom,
    allowedExtensions: const ['xlsx'],
    withData: true,
  );
  if (pick == null || pick.files.isEmpty) {
    return null;
  }
  final bytes = pick.files.single.bytes;
  if (bytes == null || bytes.isEmpty) {
    return null;
  }
  return bytes;
}
