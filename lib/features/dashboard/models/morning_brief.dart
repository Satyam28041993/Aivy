import 'package:flutter/foundation.dart';

/// One line in the brief — a mail worth answering, a headline, an alert term.
@immutable
class BriefItem {
  const BriefItem({
    required this.headline,
    this.detail,
    this.group,
    this.link,
  });

  final String headline;
  final String? detail;

  /// Grouping inside a section, which is what makes the alerts readable.
  final String? group;
  final String? link;

  static BriefItem? fromMap(Map<String, dynamic> m) {
    final headline = (m['headline'] as String?)?.trim() ?? '';
    if (headline.isEmpty) {
      return null;
    }
    String? text(String key) {
      final v = (m[key] as String?)?.trim();
      return (v == null || v.isEmpty) ? null : v;
    }

    return BriefItem(
      headline: headline,
      detail: text('detail'),
      group: text('group'),
      link: text('link'),
    );
  }
}

@immutable
class BriefSection {
  const BriefSection({
    required this.kind,
    required this.title,
    required this.items,
    this.emptyNote,
  });

  final String kind;
  final String title;
  final List<BriefItem> items;
  final String? emptyNote;

  /// A named section always earns its heading.
  ///
  /// It used to be dropped when it had no items and no note, which is how the
  /// whole Google Alerts section disappeared without a word — worse than an
  /// empty one, because silence is indistinguishable from a bug.
  bool get worthShowing => title.isNotEmpty;

  static BriefSection? fromMap(Map<String, dynamic> m) {
    final title = (m['title'] as String?)?.trim() ?? '';
    final items = (m['items'] as List?)
            ?.whereType<Map>()
            .map((i) => BriefItem.fromMap(Map<String, dynamic>.from(i)))
            .whereType<BriefItem>()
            .toList() ??
        const <BriefItem>[];
    final note = (m['emptyNote'] as String?)?.trim();
    if (title.isEmpty && items.isEmpty) {
      return null;
    }
    return BriefSection(
      kind: (m['kind'] as String?)?.trim() ?? 'other',
      title: title,
      items: items,
      // A section that says nothing still has to say that it has nothing.
      emptyNote: (note == null || note.isEmpty) ? 'Nothing new.' : note,
    );
  }
}

@immutable
class MorningBrief {
  const MorningBrief({
    required this.dateKey,
    required this.builtAtMs,
    required this.greeting,
    required this.sections,
    required this.gaps,
  });

  final String dateKey;
  final int builtAtMs;
  final String greeting;
  final List<BriefSection> sections;

  /// What could not be read — said out loud rather than left as a silent gap.
  final List<String> gaps;

  bool get isEmpty => sections.every((s) => !s.worthShowing);

  static MorningBrief fromMap(Map<String, dynamic> m) {
    return MorningBrief(
      dateKey: (m['dateKey'] as String?) ?? '',
      builtAtMs: (m['builtAtMs'] as num?)?.toInt() ?? 0,
      greeting: (m['greeting'] as String?)?.trim() ?? 'Good morning.',
      sections: (m['sections'] as List?)
              ?.whereType<Map>()
              .map((s) => BriefSection.fromMap(Map<String, dynamic>.from(s)))
              .whereType<BriefSection>()
              .where((s) => s.worthShowing)
              .toList() ??
          const <BriefSection>[],
      gaps: (m['gaps'] as List?)?.whereType<String>().toList() ??
          const <String>[],
    );
  }
}
