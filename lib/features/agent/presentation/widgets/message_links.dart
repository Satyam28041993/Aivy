import 'package:flutter/material.dart';

/// A URL pulled out of a reply, with a label a person would recognise.
///
/// Aivy writes links inline ("here is the map link: https://…"), which read
/// badly and — inside a plain text widget — could not be tapped at all. Pulling
/// them out lets the bubble show a button instead, the way a shared location
/// arrives on WhatsApp.
@immutable
class MessageLink {
  const MessageLink(this.url, this.label, this.icon, {this.isFile = false});

  final String url;
  final String label;
  final IconData icon;

  /// A file to hand to someone — a brochure, a form — rather than a page to
  /// open. These get Download / WhatsApp / Gmail buttons, because the reason
  /// Aivy fetched it is almost always to send it to a client.
  final bool isFile;

  @override
  bool operator ==(Object other) =>
      other is MessageLink &&
      other.url == url &&
      other.label == label &&
      other.icon == icon &&
      other.isFile == isFile;

  @override
  int get hashCode => Object.hash(url, label, icon, isFile);
}

/// The file name inside a Firebase Storage download link, or null when the
/// URL is not one. `…/o/library%2FScanner%2FDS-2208.pdf?alt=media&token=…`
/// becomes `DS-2208.pdf` — the host alone ("firebasestorage.googleapis.com")
/// told the user nothing about which brochure it was.
String? storageFileName(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.host.contains('firebasestorage.googleapis.com')) {
    return null;
  }
  final segments = uri.pathSegments;
  final at = segments.indexOf('o');
  if (at < 0 || at + 1 >= segments.length) {
    return null;
  }
  // pathSegments are already decoded once, so "library/Scanner/DS-2208.pdf".
  final path = segments.sublist(at + 1).join('/');
  final name = path.split('/').last.trim();
  return name.isEmpty ? null : name;
}

IconData _fileIcon(String name) {
  final lower = name.toLowerCase();
  if (lower.endsWith('.pdf')) return Icons.picture_as_pdf_rounded;
  if (lower.endsWith('.docx') || lower.endsWith('.doc')) {
    return Icons.description_rounded;
  }
  if (lower.endsWith('.xlsx') || lower.endsWith('.xls')) {
    return Icons.table_chart_rounded;
  }
  if (lower.endsWith('.pptx') || lower.endsWith('.ppt')) {
    return Icons.slideshow_rounded;
  }
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg') || lower.endsWith('.png')) {
    return Icons.image_rounded;
  }
  return Icons.insert_drive_file_rounded;
}

final RegExp _urlPattern = RegExp(r'https?://\S+');

/// Trailing punctuation belongs to the sentence, not to the address.
String _trimUrl(String raw) {
  var url = raw;
  while (url.isNotEmpty && '.,;:!?)]}"\''.contains(url[url.length - 1])) {
    url = url.substring(0, url.length - 1);
  }
  return url;
}

MessageLink describeLink(String url) {
  final fileName = storageFileName(url);
  if (fileName != null) {
    return MessageLink(url, fileName, _fileIcon(fileName), isFile: true);
  }
  final lower = url.toLowerCase();
  if (lower.contains('/maps/dir')) {
    return MessageLink(url, 'Get directions', Icons.directions_rounded);
  }
  if (lower.contains('google.com/maps') || lower.contains('maps.app.goo.gl')) {
    return MessageLink(url, 'Open in Maps', Icons.place_rounded);
  }
  if (lower.contains('mail.google.com')) {
    return MessageLink(url, 'Open in Gmail', Icons.mail_outline_rounded);
  }
  if (lower.contains('calendar.google.com')) {
    return MessageLink(url, 'Open in Calendar', Icons.event_rounded);
  }
  if (lower.contains('docs.google.com/spreadsheets')) {
    return MessageLink(url, 'Open the sheet', Icons.table_chart_rounded);
  }
  final host = Uri.tryParse(url)?.host ?? '';
  return MessageLink(
    url,
    host.isEmpty ? 'Open link' : host.replaceFirst('www.', ''),
    Icons.open_in_new_rounded,
  );
}

/// Every distinct link in the message, in the order it was written.
List<MessageLink> extractLinks(String text) {
  final seen = <String>{};
  final out = <MessageLink>[];
  for (final m in _urlPattern.allMatches(text)) {
    final url = _trimUrl(m.group(0)!);
    if (url.length > 8 && seen.add(url)) {
      out.add(describeLink(url));
    }
  }
  return out;
}

/// The prose without its URLs — and without the "here is the link:" tail that
/// only made sense while an address followed it.
String stripLinks(String text, List<MessageLink> links) {
  var out = text;
  for (final l in links) {
    out = out.replaceAll(l.url, '');
  }
  return out
      .split('\n')
      .map((line) => line.trimRight().replaceFirst(RegExp(r'[\s:\-–—]+$'), ''))
      .where((line) => line.trim().isNotEmpty)
      .join('\n')
      .trim();
}
