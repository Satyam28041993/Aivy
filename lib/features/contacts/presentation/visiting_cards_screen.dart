import 'dart:typed_data';

import 'package:excel/excel.dart';
import 'package:file_saver/file_saver.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/design/aivy_ui.dart';
import '../data/contact_service.dart';
import '../models/aivy_contact.dart';

/// Every visiting card filed through Aivy: who, which company, the number one
/// tap away, and the card itself — front, and back when there was one.
///
/// Read-only, like the other record screens: a card is filed by sending its
/// photo to Aivy. Download Excel builds the list on the phone, so it works
/// without a Google sheet behind it.
class VisitingCardsScreen extends StatefulWidget {
  const VisitingCardsScreen({super.key, required this.userId});

  final String userId;

  static Future<void> open(BuildContext context, {required String userId}) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => VisitingCardsScreen(userId: userId)),
    );
  }

  @override
  State<VisitingCardsScreen> createState() => _VisitingCardsScreenState();
}

class _VisitingCardsScreenState extends State<VisitingCardsScreen> {
  final ContactService _service = ContactService();
  final TextEditingController _search = TextEditingController();
  late final Stream<List<AivyContact>> _contacts = _service.watchContacts(widget.userId);

  @override
  void initState() {
    super.initState();
    _search.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<AivyContact> _filter(List<AivyContact> all) {
    final q = _search.text.trim().toLowerCase();
    final cards = all.where((c) => c.isVisitingCard).toList()
      ..sort((a, b) => b.createdAtMs.compareTo(a.createdAtMs));
    if (q.isEmpty) return cards;
    return cards
        .where((c) => [c.name, c.company, c.phone, c.email, c.notes]
            .any((f) => f.toLowerCase().contains(q)))
        .toList();
  }

  Future<void> _downloadExcel(List<AivyContact> rows) async {
    try {
      final excel = Excel.createExcel();
      final sheet = excel[excel.getDefaultSheet() ?? excel.tables.keys.first];
      const header = ['Name', 'Company', 'Phone', 'Email', 'Notes', 'Card', 'Saved On'];
      sheet.appendRow([for (final h in header) TextCellValue(h)]);
      for (final c in rows) {
        sheet.appendRow([
          TextCellValue(c.name),
          TextCellValue(c.company),
          TextCellValue(c.phone),
          TextCellValue(c.email),
          TextCellValue(c.notes),
          TextCellValue(_sidesLabel(c)),
          TextCellValue(c.createdAtMs > 0
              ? DateFormat('dd-MMM-yyyy').format(DateTime.fromMillisecondsSinceEpoch(c.createdAtMs))
              : ''),
        ]);
      }
      final raw = excel.encode();
      if (raw == null) throw StateError('Excel encode failed');
      await FileSaver.instance.saveFile(
        name: 'Aivy visiting cards ${DateFormat('dd-MMM-yyyy').format(DateTime.now())}',
        bytes: Uint8List.fromList(raw),
        fileExtension: 'xlsx',
        mimeType: MimeType.microsoftExcel,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Excel saved — check Downloads.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save the Excel: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AivyUi.bg,
      appBar: AppBar(
        backgroundColor: AivyUi.bg,
        foregroundColor: AivyUi.ink,
        elevation: 0,
        title: Text('Visiting cards', style: AivyUi.title(context).copyWith(fontSize: 19)),
      ),
      body: SafeArea(
        top: false,
        child: StreamBuilder<List<AivyContact>>(
          stream: _contacts,
          builder: (context, snap) {
            final loading = !snap.hasData && !snap.hasError;
            final rows = _filter(snap.data ?? const <AivyContact>[]);
            final companies = rows
                .map((c) => c.company.trim().toLowerCase())
                .where((c) => c.isNotEmpty)
                .toSet()
                .length;
            return ListView(
              padding: const EdgeInsets.fromLTRB(14, 4, 14, 28),
              children: [
                TextField(
                  controller: _search,
                  style: AivyUi.body(context),
                  decoration: InputDecoration(
                    hintText: 'Search name, company, number',
                    hintStyle: AivyUi.soft(context),
                    prefixIcon: const Icon(Icons.search, size: 19, color: AivyUi.inkFaint),
                    isDense: true,
                    filled: true,
                    fillColor: AivyUi.surface,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AivyUi.radiusSm),
                      borderSide: const BorderSide(color: AivyUi.line),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AivyUi.radiusSm),
                      borderSide: const BorderSide(color: AivyUi.line),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(child: _Tile(label: 'Cards', value: '${rows.length}', color: AivyUi.brand)),
                    const SizedBox(width: 10),
                    Expanded(child: _Tile(label: 'Companies', value: '$companies', color: AivyUi.info)),
                  ],
                ),
                const SizedBox(height: 14),
                FilledButton.icon(
                  onPressed: rows.isEmpty ? null : () => _downloadExcel(rows),
                  icon: const Icon(Icons.download_rounded, size: 18),
                  label: const Text('Download Excel'),
                  style: FilledButton.styleFrom(
                    backgroundColor: AivyUi.ok,
                    foregroundColor: AivyUi.bg,
                    disabledBackgroundColor: AivyUi.surfaceHigh,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AivyUi.radiusSm)),
                  ),
                ),
                const SizedBox(height: 18),
                AivySectionHeader(title: 'Cards', count: rows.length),
                if (snap.hasError)
                  const AivyCard(child: AivyEmpty('Could not load cards.', icon: Icons.error_outline))
                else if (loading)
                  const AivyCard(
                    child: Center(
                      child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                    ),
                  )
                else if (rows.isEmpty)
                  const AivyCard(
                    child: AivyEmpty(
                      'No cards yet. Send a photo of a visiting card to Aivy — the front, or front and back together.',
                      icon: Icons.badge_outlined,
                    ),
                  )
                else
                  for (final c in rows) ...[
                    _CardRow(contact: c, onTap: () => _CardSheet.open(context, c)),
                    const SizedBox(height: 10),
                  ],
              ],
            );
          },
        ),
      ),
    );
  }
}

String _sidesLabel(AivyContact c) {
  final n = c.cardImages.length;
  if (n == 0) return '';
  return n >= 2 ? 'Front + back' : 'Front';
}

class _Tile extends StatelessWidget {
  const _Tile({required this.label, required this.value, required this.color});

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return AivyCard(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value, style: AivyUi.display(context).copyWith(fontSize: 24, color: color)),
          const SizedBox(height: 2),
          Text(label, style: AivyUi.soft(context)),
        ],
      ),
    );
  }
}

class _CardRow extends StatelessWidget {
  const _CardRow({required this.contact, required this.onTap});

  final AivyContact contact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = contact;
    final sides = _sidesLabel(c);
    return AivyCard(
      onTap: onTap,
      child: Row(
        children: [
          SizedBox(
            width: 64,
            height: 40,
            child: c.cardImages.isEmpty
                ? const Icon(Icons.badge_outlined, color: AivyUi.inkFaint)
                : _StorageImage(path: c.cardImages.first, fit: BoxFit.cover),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  c.name,
                  style: AivyUi.body(context).copyWith(fontWeight: FontWeight.w600),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  [c.company, c.phone].where((s) => s.isNotEmpty).join(' · '),
                  style: AivyUi.soft(context),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (sides.isNotEmpty) AivyPill(sides, color: AivyUi.info),
        ],
      ),
    );
  }
}

/// A photo kept in Firebase Storage, shown through a download link.
class _StorageImage extends StatefulWidget {
  const _StorageImage({required this.path, this.fit = BoxFit.contain});

  final String path;
  final BoxFit fit;

  @override
  State<_StorageImage> createState() => _StorageImageState();
}

class _StorageImageState extends State<_StorageImage> {
  late final Future<String> _url = FirebaseStorage.instance.ref(widget.path).getDownloadURL();

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: FutureBuilder<String>(
        future: _url,
        builder: (context, snap) {
          if (snap.hasError) {
            return const Center(child: Icon(Icons.broken_image_outlined, color: AivyUi.inkFaint));
          }
          if (!snap.hasData) {
            return const ColoredBox(color: AivyUi.surfaceHigh);
          }
          return Image.network(
            snap.data!,
            fit: widget.fit,
            errorBuilder: (_, __, ___) =>
                const Center(child: Icon(Icons.broken_image_outlined, color: AivyUi.inkFaint)),
          );
        },
      ),
    );
  }
}

class _CardSheet extends StatelessWidget {
  const _CardSheet({required this.contact});

  final AivyContact contact;

  static Future<void> open(BuildContext context, AivyContact c) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AivyUi.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AivyUi.radius)),
      ),
      builder: (_) => _CardSheet(contact: c),
    );
  }

  Future<void> _launch(String url) async {
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {
      // Nothing to do: the number is on screen to dial by hand.
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = contact;
    final digits = c.phone.replaceAll(RegExp(r'\D'), '');
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 28),
        children: [
          Text(c.name, style: AivyUi.title(context)),
          if (c.company.isNotEmpty) Text(c.company, style: AivyUi.soft(context)),
          const SizedBox(height: 14),
          for (var i = 0; i < c.cardImages.length; i++) ...[
            Text(i == 0 ? 'FRONT' : (i == 1 ? 'BACK' : 'PHOTO ${i + 1}'), style: AivyUi.label(context)),
            const SizedBox(height: 6),
            AspectRatio(
              aspectRatio: 1.6,
              child: _StorageImage(path: c.cardImages[i]),
            ),
            const SizedBox(height: 12),
          ],
          if (c.phone.isNotEmpty) _line(context, 'Phone', c.phone),
          if (c.email.isNotEmpty) _line(context, 'Email', c.email),
          if (c.notes.isNotEmpty) _line(context, 'Notes', c.notes),
          const SizedBox(height: 12),
          if (digits.isNotEmpty)
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () => _launch('tel:+$digits'),
                    icon: const Icon(Icons.call, size: 18),
                    label: const Text('Call'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _launch('https://wa.me/$digits'),
                    icon: const Icon(Icons.chat_outlined, size: 18),
                    label: const Text('WhatsApp'),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _line(BuildContext context, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label.toUpperCase(), style: AivyUi.label(context)),
          const SizedBox(height: 2),
          SelectableText(value, style: AivyUi.body(context)),
        ],
      ),
    );
  }
}
