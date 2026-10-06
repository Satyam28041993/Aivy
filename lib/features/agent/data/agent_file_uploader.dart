import 'package:firebase_storage/firebase_storage.dart';

import '../models/agent_attachment.dart';

/// Puts a composer file at `users/{uid}/agent_files/...` so the callable can
/// download it. The request itself only carries the path — a PDF will not fit
/// in a callable body.
class AgentFileUploader {
  AgentFileUploader({FirebaseStorage? storage})
      : _storage = storage ?? FirebaseStorage.instance;

  final FirebaseStorage _storage;

  Future<AgentFileRef> upload({
    required String uid,
    required AgentPendingFile file,
  }) async {
    final mime = normalizeAgentMime(file.mimeType, fileName: file.name);
    if (mime == null) {
      throw ArgumentError.value(file.mimeType, 'mimeType', 'unsupported');
    }
    if (file.bytes.isEmpty || file.bytes.length > kAgentMaxAttachmentBytes) {
      throw ArgumentError.value(file.bytes.length, 'bytes', 'empty or too large');
    }
    final name = safeAgentFileName(file.name);
    final path =
        'users/$uid/agent_files/${DateTime.now().millisecondsSinceEpoch}_$name';
    await _storage.ref(path).putData(
          file.bytes,
          SettableMetadata(contentType: mime),
        );
    return AgentFileRef(storagePath: path, mimeType: mime, name: file.name);
  }
}
