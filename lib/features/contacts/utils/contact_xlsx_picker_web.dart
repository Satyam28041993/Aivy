// Web-only: `dart:html` is the stable way to trigger `<input type="file">` from
// app code; `file_picker` on web can hit MissingPluginException when the
// platform implementation is not registered.
//
// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:async';
import 'dart:html' as html;
import 'dart:typed_data';

/// Web: [FilePicker] can hit [MissingPluginException] when the web
/// implementation is not bound to [FilePickerPlatform.instance]. A hidden
/// `<input type="file">` matches what `file_picker` does on web and always
/// works in browsers.
Future<Uint8List?> pickXlsxBytes() async {
  final input = html.FileUploadInputElement()
    ..accept =
        '.xlsx,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
    ..style.display = 'none';
  html.document.body!.append(input);

  final completer = Completer<Uint8List?>();
  late final StreamSubscription<html.Event> sub;

  void complete(Uint8List? bytes) {
    if (!completer.isCompleted) {
      completer.complete(bytes);
    }
  }

  sub = input.onChange.listen((_) {
    final files = input.files;
    if (files == null || files.isEmpty) {
      complete(null);
      return;
    }
    final file = files.first;
    final reader = html.FileReader();
    reader.onLoadEnd.listen((_) {
      final Object? result = reader.result;
      if (result is ByteBuffer) {
        complete(result.asUint8List());
      } else if (result is Uint8List) {
        complete(result);
      } else {
        complete(null);
      }
    });
    reader.readAsArrayBuffer(file);
  });

  try {
    input.click();
    return await completer.future.timeout(
      const Duration(minutes: 2),
      onTimeout: () => null,
    );
  } finally {
    await sub.cancel();
    input.remove();
  }
}
