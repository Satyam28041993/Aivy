import 'package:firebase_storage/firebase_storage.dart';

/// Web / non-IO: no local file access.
Future<int> voiceLocalFileByteLength(String localFilePath) async => 0;

/// Web / non-IO: voice upload from a local path is not supported.
Future<String> uploadVoiceToStorage({
  required FirebaseStorage storage,
  required String userId,
  required String entryId,
  required String localFilePath,
}) async {
  throw UnsupportedError('Voice file upload requires a native platform');
}
