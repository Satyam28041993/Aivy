import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/design/aivy_ui.dart';
import '../../models/morning_brief.dart';

/// The first thing on the Today screen: what happened overnight.
///
/// One card rather than five, because these sections are read in one sweep and
/// five separate cards would put four borders between a person and their
/// morning. Sections keep their own headings and are separated by a rule, so
/// the sweep still has stops in it.
///
/// Sections fold. Not all of them by default, though — a brief that opens
/// entirely shut costs six taps to read one morning, which is more work than
/// scrolling. So the ones that ask something of you open, and the ones you
/// browse start folded with their count on the header, which is what keeps
/// folded from looking like broken. Whatever you change is remembered.
class MorningBriefCard extends StatefulWidget {
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

  /// Opens Aivy with a question about one item already written. Offered on the
  /// two sections that exist to be followed up — news and alerts — and not on
  /// mail or today's list, where the next step is the mail or the task itself.
  final ValueChanged<String>? onAskAbout;

  /// Opens the whole project or task behind a line, by its id.
  ///
  /// The brief gives each one a sentence, which is right for a morning and
  /// wrong the moment you want to know what has actually been happening — so
  /// the sentence is a way in rather than the whole answer.
  final ValueChanged<String>? onOpenProject;

  @override
  State<MorningBriefCard> createState() => _MorningBriefCardState();
}

class _MorningBriefCardState extends State<MorningBriefCard> {
  static const _prefsKey = 'brief_open_sections_v1';

  /// Open unless folded. The four that ask something of you are open; news and
  /// alerts are read when there is time, and both run long.
  static const _defaults = <String, bool>{
    'tasks': true,
    'projects': true,
    'today': true,
    'mail': true,
    'news': false,
    'alerts': false,
    'money': true,
  };

  static const _icons = <String, IconData>{
    'mail': Icons.mail_outline_rounded,
    'news': Icons.public_rounded,
    'alerts': Icons.notifications_none_rounded,
    'today': Icons.today_rounded,
    'money': Icons.currency_rupee_rounded,
    'tasks': Icons.check_circle_outline_rounded,
    'projects': Icons.work_outline_rounded,
  };

  /// Only the sections whose state has been changed by hand. Everything else
  /// follows the defaults above, so changing a default later actually reaches
  /// the people who never touched it.
  Map<String, bool> _chosen = const {};

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_prefsKey) ?? const <String>[];
      final chosen = <String, bool>{};
      for (final entry in raw) {
        final parts = entry.split(':');
        if (parts.length == 2) {
          chosen[parts.first] = parts.last == '1';
        }
      }
      if (!mounted) return;
      setState(() => _chosen = chosen);
    } catch (_) {
      // A preference that cannot be read is not worth a broken morning.
    }
  }

  bool _isOpen(String kind) => _chosen[kind] ?? _defaults[kind] ?? true;

  Future<void> _toggle(String kind) async {
    final next = Map<String, bool>.from(_chosen)..[kind] = !_isOpen(kind);
    setState(() => _chosen = next);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        _prefsKey,
        next.entries.map((e) => '${e.key}:${e.value ? 1 : 0}').toList(),
      );
    } catch (_) {
      // Remembering it is a convenience; folding it is the thing that mattered.
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.brief;

    if (widget.loading && b == null) {
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
                style: TextStyle(color: AivyUi.inkSoft, fontSize: 14.5),
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
                style: TextStyle(color: AivyUi.inkSoft, fontSize: 14.5),
              ),
            ),
            TextButton(onPressed: widget.onRetry, child: const Text('Retry')),
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
          Expanded(child: Text(b.greeting, style: AivyUi.title(context))),
          if (widget.loading)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2, color: AivyUi.brand),
            ),
        ],
      ),
      if (b.summary != null)
        Padding(
          padding: const EdgeInsets.only(top: 5),
          child: Text(
            b.summary!,
            style: const TextStyle(
              color: AivyUi.brand,
              fontSize: 13.5,
              fontWeight: FontWeight.w700,
              height: 1.3,
            ),
          ),
        ),
    ];

    for (final section in b.sections) {
      children
        ..add(const SizedBox(height: 18))
        ..add(_Section(
          icon: _icons[section.kind] ?? Icons.circle_outlined,
          section: section,
          expanded: _isOpen(section.kind),
          onToggle: () => _toggle(section.kind),
          onAskAbout: const {'news', 'alerts'}.contains(section.kind)
              ? widget.onAskAbout
              : null,
          onOpenProject: widget.onOpenProject,
        ));
    }

    if (b.gaps.isNotEmpty) {
      children
        ..add(const SizedBox(height: 16))
        ..add(
          Text(
            b.gaps.join('  •  '),
            style: const TextStyle(
              color: AivyUi.inkFaint,
              fontSize: 12,
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
    required this.expanded,
    required this.onToggle,
    this.onAskAbout,
    this.onOpenProject,
  });

  final IconData icon;
  final BriefSection section;
  final bool expanded;
  final VoidCallback onToggle;
  final ValueChanged<String>? onAskAbout;
  final ValueChanged<String>? onOpenProject;

  /// What the header says when the section is folded.
  ///
  /// Alerts are counted by topic rather than by line: twenty mails under six
  /// terms is six things to look at, and "20" would read as far more work than
  /// it is.
  String get _countLabel {
    if (section.items.isEmpty) {
      return '';
    }
    if (section.kind == 'alerts') {
      final topics = section.items
          .map((i) => i.group ?? i.headline)
          .toSet()
          .length;
      return '$topics ${topics == 1 ? 'topic' : 'topics'}';
    }
    return '${section.items.length}';
  }

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
        InkWell(
          onTap: onToggle,
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                Icon(icon, size: 15, color: AivyUi.inkFaint),
                const SizedBox(width: 7),
                Text(section.title.toUpperCase(), style: AivyUi.label(context)),
                const SizedBox(width: 8),
                // The count stays on the header when folded, because a folded
                // section and a broken one look identical without it.
                if (!expanded && _countLabel.isNotEmpty)
                  Text(
                    _countLabel,
                    style: const TextStyle(
                      color: AivyUi.brand,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                const Spacer(),
                Icon(
                  expanded
                      ? Icons.keyboard_arrow_up_rounded
                      : Icons.keyboard_arrow_down_rounded,
                  size: 20,
                  color: AivyUi.inkFaint,
                ),
              ],
            ),
          ),
        ),
        if (expanded) ...[
          const SizedBox(height: 8),
          if (section.items.isEmpty)
            Text(
              section.emptyNote ?? 'Nothing here.',
              style: const TextStyle(
                color: AivyUi.inkFaint,
                fontSize: 14,
                height: 1.35,
              ),
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
                    fontSize: 13.5,
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
      padding: EdgeInsets.only(left: indented ? 10 : 0, bottom: 9),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 7, right: 8),
                child: SizedBox(
                  width: 5,
                  height: 5,
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
                    fontSize: 15,
                    height: 1.35,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (item.link != null)
                const Padding(
                  padding: EdgeInsets.only(left: 6, top: 2),
                  child: Icon(
                    Icons.open_in_new_rounded,
                    size: 14,
                    color: AivyUi.inkFaint,
                  ),
                ),
              if (_projectId != null)
                const Padding(
                  padding: EdgeInsets.only(left: 6, top: 1),
                  child: Icon(
                    Icons.chevron_right_rounded,
                    size: 18,
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
              padding: const EdgeInsets.only(left: 13, top: 3),
              child: Text(
                item.detail!,
                style: const TextStyle(
                  color: AivyUi.inkSoft,
                  fontSize: 13.5,
                  height: 1.4,
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
            padding: EdgeInsets.symmetric(horizontal: 6, vertical: 5),
            child: Icon(
              Icons.auto_awesome,
              size: 14,
              color: AivyUi.brand,
            ),
          ),
        ),
      ),
    );
  }
}
