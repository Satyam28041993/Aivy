import 'dart:io' show File;

import 'package:firebase_storage/firebase_storage.dart';
import 'package:path/path.dart' as p;

Future<int> voiceLocalFileByteLength(String localFilePath) async {
  final f = File(localFilePath);
  if (!await f.exists()) {
    return 0;
  }
  return await f.length();
}

Future<String> uploadVoiceToStorage({
  required FirebaseStorage storage,
  required String userId,
  required String entryId,
  required String localFilePath,
}) async {
  final ext = p.extension(localFilePath).toLowerCase();
  final storageExt = ext == '.wav' ? 'wav' : 'm4a';
  final contentType = ext == '.wav' ? 'audio/wav' : 'audio/m4a';
  final ref = storage.ref('users/$userId/voice/$entryId.$storageExt');
  final file = File(localFilePath);
  await ref.putFile(
    file,
    SettableMetadata(contentType: contentType),
  );
  final url = await ref.getDownloadURL();
  try {
    if (await file.exists()) {
      await file.delete();
    }
  } catch (_) {}
  return url;
}
