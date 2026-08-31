import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/design/aivy_ui.dart';
import '../data/project_repository.dart';
import '../models/project_models.dart';

/// The whole of one project or task, opened from a line in the morning brief.
///
/// A sheet rather than a screen: it is something you glance into and dismiss,
/// not somewhere you navigate to and have to come back from. It is read-only,
/// and the button at the bottom says so by offering the only way to change
/// anything — asking Aivy.
///
/// The history is the point of it. Current state answers "what is left"; the
/// timeline answers "kab kya update kiya", which is the question you have when
/// somebody asks how a job has been going.
class ProjectDetailSheet extends StatefulWidget {
  const ProjectDetailSheet({
    super.key,
    required this.userId,
    required this.projectId,
    this.onAskAbout,
    ProjectRepository? repository,
  }) : _repository = repository;

  final String userId;
  final String projectId;

  /// Jumps to Aivy with a question already written.
  final ValueChanged<String>? onAskAbout;

  final ProjectRepository? _repository;

  /// Opens the sheet. Returns once it is dismissed.
  static Future<void> open(
    BuildContext context, {
    required String userId,
    required String projectId,
    ValueChanged<String>? onAskAbout,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => ProjectDetailSheet(
        userId: userId,
        projectId: projectId,
        onAskAbout: onAskAbout,
      ),
    );
  }

  @override
  State<ProjectDetailSheet> createState() => _ProjectDetailSheetState();
}

class _ProjectDetailSheetState extends State<ProjectDetailSheet> {
  late final ProjectRepository _repository =
      widget._repository ?? ProjectRepository();

  ProjectDetail? _detail;
  bool _loading = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final detail = await _repository.detail(widget.userId, widget.projectId);
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _loading = false;
        _failed = detail == null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.of(context).size.height;
    return Container(
      constraints: BoxConstraints(maxHeight: height * 0.86),
      decoration: const BoxDecoration(
        color: AivyUi.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const _Grabber(),
            Flexible(child: _body(context)),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 48),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2, color: AivyUi.brand),
          ),
        ),
      );
    }

    final detail = _detail;
    if (_failed || detail == null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Could not open this one.',
              style: TextStyle(color: AivyUi.inkSoft, fontSize: 13.5),
            ),
            const SizedBox(height: 8),
            TextButton(onPressed: _load, child: const Text('Try again')),
          ],
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Header(project: detail.project),
          if (detail.project.note.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text(
              detail.project.note,
              style: const TextStyle(
                color: AivyUi.inkSoft,
                fontSize: 13,
                height: 1.4,
              ),
            ),
          ],
          const SizedBox(height: 20),
          _Steps(detail: detail),
          const SizedBox(height: 22),
          _Timeline(events: detail.events),
          const SizedBox(height: 20),
          _AskRow(
            project: detail.project,
            onAskAbout: widget.onAskAbout,
          ),
        ],
      ),
    );
  }
}

class _Grabber extends StatelessWidget {
  const _Grabber();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 36,
      height: 4,
      margin: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        color: AivyUi.line,
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }
}

/// How late something is, in the words a person would use.
String _dueWords(int dueMs, {DateTime? now}) {
  if (dueMs <= 0) {
    return 'No deadline';
  }
  final today = DateTime(
    (now ?? DateTime.now()).year,
    (now ?? DateTime.now()).month,
    (now ?? DateTime.now()).day,
  );
  final due = DateTime.fromMillisecondsSinceEpoch(dueMs);
  final dueDay = DateTime(due.year, due.month, due.day);
  final days = dueDay.difference(today).inDays;

  if (days < 0) {
    final n = -days;
    return n == 1 ? '1 day late' : '$n days late';
  }
  if (days == 0) return 'Due today';
  if (days == 1) return 'Due tomorrow';
  return 'Due ${DateFormat('d MMM').format(due)}';
}

Color _dueColour(int dueMs, {DateTime? now}) {
  if (dueMs <= 0) return AivyUi.inkFaint;
  final words = _dueWords(dueMs, now: now);
  if (words.endsWith('late')) return AivyUi.danger;
  if (words == 'Due today' || words == 'Due tomorrow') return AivyUi.warn;
  return AivyUi.inkSoft;
}

class _Header extends StatelessWidget {
  const _Header({required this.project});

  final ProjectRecord project;

  @override
  Widget build(BuildContext context) {
    final pills = <Widget>[
      AivyPill(
        project.isTask ? 'Task' : 'Project',
        color: project.isPersonal ? AivyUi.ok : AivyUi.brand,
        icon: project.isPersonal
            ? Icons.home_outlined
            : Icons.work_outline_rounded,
      ),
      if (project.forWhom.isNotEmpty)
        AivyPill(project.forWhom, icon: Icons.person_outline_rounded),
      // A project has no deadline of its own — its items carry the dates — so
      // showing "No deadline" there would read as something missing.
      if (project.isTask)
        AivyPill(
          _dueWords(project.dueMs),
          color: _dueColour(project.dueMs),
          icon: Icons.event_outlined,
        ),
      if (!project.isLive)
        AivyPill(project.status.replaceAll('_', ' '), color: AivyUi.inkFaint),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(project.name, style: AivyUi.title(context)),
        const SizedBox(height: 10),
        Wrap(spacing: 6, runSpacing: 6, children: pills),
      ],
    );
  }
}

class _Steps extends StatelessWidget {
  const _Steps({required this.detail});

  final ProjectDetail detail;

  @override
  Widget build(BuildContext context) {
    final items = detail.items;
    if (items.isEmpty) {
      return const _Block(
        title: 'Steps',
        child: Text(
          'Nothing in it yet. Tell Aivy what needs doing.',
          style: TextStyle(color: AivyUi.inkFaint, fontSize: 13, height: 1.35),
        ),
      );
    }

    // Late first, then what is on him, then what is on somebody else, then what
    // is finished. The same order Aivy speaks a status in.
    final ordered = <ProjectItemRecord>[
      ...detail.open.where((i) => i.dueMs > 0 && i.dueMs < DateTime.now().millisecondsSinceEpoch),
      ...detail.open.where((i) => !(i.dueMs > 0 && i.dueMs < DateTime.now().millisecondsSinceEpoch)),
      ...detail.waiting,
      ...detail.done,
      ...items.where((i) => i.status == 'dropped'),
    ];

    return _Block(
      title: 'Steps',
      trailing: '${detail.done.length}/${items.length} done',
      child: Column(
        children: [for (final item in ordered) _StepRow(item: item)],
      ),
    );
  }
}

class _StepRow extends StatelessWidget {
  const _StepRow({required this.item});

  final ProjectItemRecord item;

  @override
  Widget build(BuildContext context) {
    final done = item.status == 'done';
    final dropped = item.status == 'dropped';
    final late = item.isLive &&
        item.dueMs > 0 &&
        item.dueMs < DateTime.now().millisecondsSinceEpoch;

    final Color mark = done
        ? AivyUi.ok
        : dropped
            ? AivyUi.inkFaint
            : late
                ? AivyUi.danger
                : item.status == 'waiting_on_them'
                    ? AivyUi.warn
                    : AivyUi.inkSoft;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1, right: 9),
            child: Icon(
              done
                  ? Icons.check_circle_rounded
                  : dropped
                      ? Icons.remove_circle_outline_rounded
                      : Icons.radio_button_unchecked_rounded,
              size: 15,
              color: mark,
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.title,
                  style: TextStyle(
                    color: done || dropped ? AivyUi.inkSoft : AivyUi.ink,
                    fontSize: 13.5,
                    height: 1.3,
                    fontWeight: FontWeight.w600,
                    decoration: dropped ? TextDecoration.lineThrough : null,
                  ),
                ),
                if (item.status != 'open' || item.dueMs > 0 || item.note.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      [
                        if (item.status != 'open') item.statusLabel,
                        if (item.dueMs > 0) _dueWords(item.dueMs),
                        if (item.note.isNotEmpty) item.note,
                      ].join(' · '),
                      style: TextStyle(
                        color: late ? AivyUi.danger : AivyUi.inkFaint,
                        fontSize: 12,
                        height: 1.3,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Timeline extends StatelessWidget {
  const _Timeline({required this.events});

  final List<ProjectEventRecord> events;

  @override
  Widget build(BuildContext context) {
    if (events.isEmpty) {
      return const _Block(
        title: 'History',
        child: Text(
          'Nothing recorded yet. Every change you make through Aivy from now on '
          'shows up here.',
          style: TextStyle(color: AivyUi.inkFaint, fontSize: 13, height: 1.35),
        ),
      );
    }

    return _Block(
      title: 'History',
      child: Column(
        children: [
          for (var i = 0; i < events.length; i++)
            _TimelineRow(
              event: events[i],
              isFirst: i == 0,
              isLast: i == events.length - 1,
            ),
        ],
      ),
    );
  }
}

class _TimelineRow extends StatelessWidget {
  const _TimelineRow({
    required this.event,
    required this.isFirst,
    required this.isLast,
  });

  final ProjectEventRecord event;
  final bool isFirst;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final at = DateTime.fromMillisecondsSinceEpoch(event.atMs);
    final colour = isFirst ? AivyUi.brand : AivyUi.line;

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The rail: a dot for this entry and a line down to the next, so the
          // eye reads it as one sequence rather than a list of sentences.
          Column(
            children: [
              Container(
                width: 8,
                height: 8,
                margin: const EdgeInsets.only(top: 5),
                decoration: BoxDecoration(
                  color: colour,
                  shape: BoxShape.circle,
                ),
              ),
              if (!isLast)
                Expanded(
                  child: Container(width: 1.5, color: AivyUi.line),
                ),
            ],
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: isLast ? 0 : 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    DateFormat('d MMM, h:mm a').format(at),
                    style: const TextStyle(
                      color: AivyUi.inkFaint,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    event.text,
                    style: const TextStyle(
                      color: AivyUi.ink,
                      fontSize: 13,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Block extends StatelessWidget {
  const _Block({required this.title, required this.child, this.trailing});

  final String title;
  final Widget child;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(title.toUpperCase(), style: AivyUi.label(context)),
            const Spacer(),
            if (trailing != null)
              Text(
                trailing!,
                style: const TextStyle(color: AivyUi.inkFaint, fontSize: 11.5),
              ),
          ],
        ),
        const SizedBox(height: 10),
        child,
      ],
    );
  }
}

/// The only way anything here changes.
class _AskRow extends StatelessWidget {
  const _AskRow({required this.project, this.onAskAbout});

  final ProjectRecord project;
  final ValueChanged<String>? onAskAbout;

  @override
  Widget build(BuildContext context) {
    if (onAskAbout == null) {
      return const SizedBox.shrink();
    }
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: () {
          Navigator.of(context).maybePop();
          onAskAbout!(project.name);
        },
        icon: const Icon(Icons.auto_awesome, size: 15),
        label: Text(
          project.isTask ? 'Update this with Aivy' : 'Ask Aivy about this',
        ),
        style: OutlinedButton.styleFrom(
          foregroundColor: AivyUi.brand,
          side: const BorderSide(color: AivyUi.brandDim),
          padding: const EdgeInsets.symmetric(vertical: 12),
        ),
      ),
    );
  }
}
