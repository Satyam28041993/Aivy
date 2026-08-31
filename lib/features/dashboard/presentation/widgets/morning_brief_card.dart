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
    this.onAskAbout,
    this.onOpenProject,
  });

  final MorningBrief? brief;
  final bool loading;
  final VoidCallback onRetry;

  /// Opens the whole project or task behind a line, by its id.
  ///
  /// The brief gives each one a sentence, which is right for a morning and
  /// wrong the moment you want to know what has actually been happening — so
  /// the sentence is a way in rather than the whole answer.
  final ValueChanged<String>? onOpenProject;

  /// Opens Aivy with a question about one item already written. Offered on the
  /// two sections that exist to be followed up — news and alerts — and not on
  /// mail or today's list, where the next step is the mail or the task itself.
  final ValueChanged<String>? onAskAbout;

  static const _icons = <String, IconData>{
    'mail': Icons.mail_outline_rounded,
    'news': Icons.public_rounded,
    'alerts': Icons.notifications_none_rounded,
    'today': Icons.today_rounded,
    'money': Icons.currency_rupee_rounded,
    'tasks': Icons.check_circle_outline_rounded,
    'projects': Icons.work_outline_rounded,
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
          onAskAbout: const {'news', 'alerts'}.contains(section.kind)
              ? onAskAbout
              : null,
          onOpenProject: onOpenProject,
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
  const _Section({
    required this.icon,
    required this.section,
    this.onAskAbout,
    this.onOpenProject,
  });

  final IconData icon;
  final BriefSection section;
  final ValueChanged<String>? onAskAbout;
  final ValueChanged<String>? onOpenProject;

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
          for (final item in loose)
            _Item(
              item: item,
              onAskAbout: onAskAbout,
              onOpenProject: onOpenProject,
            ),
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
            for (final item in entry.value)
              _Item(
                item: item,
                indented: true,
                // The alert term is the topic, not the one-line summary under
                // it — "Canva ai" is what he wants to ask about.
                topic: entry.key,
                onAskAbout: onAskAbout,
                onOpenProject: onOpenProject,
              ),
          ],
        ],
      ],
    );
  }
}

/// Red is late, amber is due, green is settled — the same meanings these
/// colours carry everywhere else in the app. A line with no tone keeps the
/// faint grey dot, so colour stays rare enough to mean something.
Color _toneColour(String? tone) {
  switch (tone) {
    case 'late':
      return AivyUi.danger;
    case 'due':
      return AivyUi.warn;
    case 'ok':
      return AivyUi.ok;
    default:
      return AivyUi.inkFaint;
  }
}

class _Item extends StatelessWidget {
  const _Item({
    required this.item,
    this.indented = false,
    this.topic,
    this.onAskAbout,
    this.onOpenProject,
  });

  final BriefItem item;
  final bool indented;

  final ValueChanged<String>? onOpenProject;

  /// What to ask Aivy about, when it is not simply the headline.
  final String? topic;
  final ValueChanged<String>? onAskAbout;

  /// A line that stands for a project or task, with somewhere to open it.
  String? get _projectId {
    final id = item.refId;
    return (id != null && id.isNotEmpty && onOpenProject != null) ? id : null;
  }

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
              Padding(
                padding: const EdgeInsets.only(top: 6, right: 8),
                child: SizedBox(
                  width: 4,
                  height: 4,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: _toneColour(item.tone),
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
                const Padding(
                  padding: EdgeInsets.only(left: 6, top: 1),
                  child: Icon(
                    Icons.open_in_new_rounded,
                    size: 13,
                    color: AivyUi.inkFaint,
                  ),
                ),
              if (_projectId != null)
                const Padding(
                  padding: EdgeInsets.only(left: 6, top: 1),
                  child: Icon(
                    Icons.chevron_right_rounded,
                    size: 16,
                    color: AivyUi.inkFaint,
                  ),
                ),
              if (onAskAbout != null)
                _AskAivyButton(
                  onTap: () => onAskAbout!(topic ?? item.headline),
                ),
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

    final projectId = _projectId;
    if (projectId != null) {
      return InkWell(
        onTap: () => onOpenProject!(projectId),
        borderRadius: BorderRadius.circular(6),
        child: row,
      );
    }
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

/// The one tap that turns reading into asking.
///
/// Sits on news and alert lines, because those are the two things worth
/// following up and the brief deliberately keeps them to a sentence — the rest
/// of the story is a question away rather than a longer card.
class _AskAivyButton extends StatelessWidget {
  const _AskAivyButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: Material(
        color: AivyUi.brand.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(7),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(7),
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 5, vertical: 4),
            child: Icon(
              Icons.auto_awesome,
              size: 13,
              color: AivyUi.brand,
            ),
          ),
        ),
      ),
    );
  }
}
