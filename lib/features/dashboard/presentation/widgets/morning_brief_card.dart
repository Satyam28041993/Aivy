import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/design/aivy_ui.dart';
import '../../models/morning_brief.dart';

/// The first thing on the Today screen: what happened overnight.
///
/// One card rather than five, because these sections are read in one sweep and
/// five separate cards would put four borders between a person and their
/// morning. Sections keep their own headings and are separated by a rule, so
/// the sweep still has stops in it.
class MorningBriefCard extends StatelessWidget {
  const MorningBriefCard({
    super.key,
    required this.brief,
    required this.loading,
    required this.onRetry,
  });

  final MorningBrief? brief;
  final bool loading;
  final VoidCallback onRetry;

  static const _icons = <String, IconData>{
    'mail': Icons.mail_outline_rounded,
    'news': Icons.public_rounded,
    'alerts': Icons.notifications_none_rounded,
    'today': Icons.today_rounded,
    'money': Icons.currency_rupee_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final b = brief;

    if (loading && b == null) {
      return const AivyCard(
        accent: AivyUi.brand,
        child: Row(
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: AivyUi.brand),
            ),
            SizedBox(width: 12),
            Expanded(
              child: Text(
                'Reading your morning…',
                style: TextStyle(color: AivyUi.inkSoft, fontSize: 13.5),
              ),
            ),
          ],
        ),
      );
    }

    if (b == null) {
      // Say what is missing and offer the one thing that might fix it, rather
      // than leaving a blank where the brief should be.
      return AivyCard(
        child: Row(
          children: [
            const Expanded(
              child: Text(
                'Could not build your brief just now.',
                style: TextStyle(color: AivyUi.inkSoft, fontSize: 13.5),
              ),
            ),
            TextButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      );
    }

    if (b.isEmpty && b.gaps.isEmpty) {
      return const SizedBox.shrink();
    }

    final children = <Widget>[
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              b.greeting,
              style: AivyUi.title(context),
            ),
          ),
          if (loading)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2, color: AivyUi.brand),
            ),
        ],
      ),
    ];

    for (final section in b.sections) {
      children
        ..add(const SizedBox(height: 16))
        ..add(_Section(
          icon: _icons[section.kind] ?? Icons.circle_outlined,
          section: section,
        ));
    }

    if (b.gaps.isNotEmpty) {
      children
        ..add(const SizedBox(height: 14))
        ..add(
          Text(
            b.gaps.join('  •  '),
            style: const TextStyle(
              color: AivyUi.inkFaint,
              fontSize: 11.5,
              height: 1.35,
            ),
          ),
        );
    }

    return AivyCard(
      accent: AivyUi.brand,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.icon, required this.section});

  final IconData icon;
  final BriefSection section;

  @override
  Widget build(BuildContext context) {
    // Items carrying a group are drawn under it — this is what turns a wall of
    // Google Alerts into something scannable by subject.
    final groups = <String, List<BriefItem>>{};
    final loose = <BriefItem>[];
    for (final item in section.items) {
      final g = item.group;
      if (g == null || g.isEmpty) {
        loose.add(item);
      } else {
        groups.putIfAbsent(g, () => []).add(item);
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 14, color: AivyUi.inkFaint),
            const SizedBox(width: 7),
            Text(section.title.toUpperCase(), style: AivyUi.label(context)),
          ],
        ),
        const SizedBox(height: 8),
        if (section.items.isEmpty)
          Text(
            section.emptyNote ?? 'Nothing here.',
            style: const TextStyle(color: AivyUi.inkFaint, fontSize: 13, height: 1.35),
          )
        else ...[
          for (final item in loose) _Item(item: item),
          for (final entry in groups.entries) ...[
            Padding(
              padding: const EdgeInsets.only(top: 6, bottom: 2),
              child: Text(
                entry.key,
                style: const TextStyle(
                  color: AivyUi.brand,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            for (final item in entry.value) _Item(item: item, indented: true),
          ],
        ],
      ],
    );
  }
}

class _Item extends StatelessWidget {
  const _Item({required this.item, this.indented = false});

  final BriefItem item;
  final bool indented;

  Future<void> _open(BuildContext context) async {
    final url = item.link;
    if (url == null) {
      return;
    }
    final uri = Uri.tryParse(url);
    if (uri == null) {
      return;
    }
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      // A dead link is not worth interrupting the morning for.
    }
  }

  @override
  Widget build(BuildContext context) {
    final row = Padding(
      padding: EdgeInsets.only(left: indented ? 10 : 0, bottom: 7),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 6, right: 8),
                child: SizedBox(
                  width: 4,
                  height: 4,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: AivyUi.inkFaint,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  item.headline,
                  style: const TextStyle(
                    color: AivyUi.ink,
                    fontSize: 13.5,
                    height: 1.35,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (item.link != null)
                const Icon(Icons.open_in_new_rounded, size: 13, color: AivyUi.inkFaint),
            ],
          ),
          if (item.detail != null)
            Padding(
              padding: const EdgeInsets.only(left: 12, top: 2),
              child: Text(
                item.detail!,
                style: const TextStyle(
                  color: AivyUi.inkSoft,
                  fontSize: 12.5,
                  height: 1.35,
                ),
              ),
            ),
        ],
      ),
    );

    if (item.link == null) {
      return row;
    }
    return InkWell(
      onTap: () => _open(context),
      borderRadius: BorderRadius.circular(6),
      child: row,
    );
  }
}
