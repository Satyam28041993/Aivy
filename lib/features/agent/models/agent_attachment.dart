import 'dart:typed_data';

/// One file waiting on the composer, before it is uploaded.
class AgentPendingFile {
  const AgentPendingFile({
    required this.name,
    required this.mimeType,
    required this.bytes,
  });

  final String name;
  final String mimeType;
  final Uint8List bytes;

  bool get isPdf => mimeType == 'application/pdf';
  bool get isImage => mimeType.startsWith('image/');
}

/// Path the callable will download. Bytes never leave the device in the request.
class AgentFileRef {
  const AgentFileRef({
    required this.storagePath,
    required this.mimeType,
    required this.name,
  });

  final String storagePath;
  final String mimeType;
  final String name;

  Map<String, String> toPayload() => {
        'storagePath': storagePath,
        'mimeType': mimeType,
        'name': name,
      };
}

const int kAgentMaxAttachments = 3;
const int kAgentMaxAttachmentBytes = 8 * 1024 * 1024;

const Set<String> kAgentAllowedMimes = {
  'image/jpeg',
  'image/png',
  'image/webp',
  'application/pdf',
};

/// Send is allowed with words, or with a file and nothing typed.
bool canSendAgentTurn({required String text, required int attachmentCount}) {
  return text.trim().isNotEmpty || attachmentCount > 0;
}

String? normalizeAgentMime(String raw, {String? fileName}) {
  final mime = raw.trim().toLowerCase();
  if (mime == 'image/jpg') {
    return 'image/jpeg';
  }
  if (kAgentAllowedMimes.contains(mime)) {
    return mime;
  }
  final name = (fileName ?? '').toLowerCase();
  if (name.endsWith('.jpg') || name.endsWith('.jpeg')) {
    return 'image/jpeg';
  }
  if (name.endsWith('.png')) {
    return 'image/png';
  }
  if (name.endsWith('.webp')) {
    return 'image/webp';
  }
  if (name.endsWith('.pdf')) {
    return 'application/pdf';
  }
  return null;
}

/// Storage object names reject spaces; the display name on the chip keeps them.
String safeAgentFileName(String raw) {
  final trimmed = raw.trim();
  final dot = trimmed.lastIndexOf('.');
  final stem = dot > 0 ? trimmed.substring(0, dot) : trimmed;
  final ext = dot > 0 ? trimmed.substring(dot) : '';
  final cleaned = stem.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  final safeExt = ext.replaceAll(RegExp(r'[^A-Za-z0-9.]'), '');
  final out = '${cleaned.isEmpty ? 'file' : cleaned}$safeExt';
  return out.length > 80 ? out.substring(out.length - 80) : out;
}
