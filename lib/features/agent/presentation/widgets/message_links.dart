import 'package:flutter/material.dart';

/// A URL pulled out of a reply, with a label a person would recognise.
///
/// Aivy writes links inline ("here is the map link: https://…"), which read
/// badly and — inside a plain text widget — could not be tapped at all. Pulling
/// them out lets the bubble show a button instead, the way a shared location
/// arrives on WhatsApp.
@immutable
class MessageLink {
  const MessageLink(this.url, this.label, this.icon);

  final String url;
  final String label;
  final IconData icon;

  @override
  bool operator ==(Object other) =>
      other is MessageLink &&
      other.url == url &&
      other.label == label &&
      other.icon == icon;

  @override
  int get hashCode => Object.hash(url, label, icon);
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
