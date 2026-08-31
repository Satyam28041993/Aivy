import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/project_repository.dart';
import '../models/project_models.dart';
import '../utils/project_confirm.dart';

/// Browse-only: chat is how items are created and updated.
class ProjectsBrowseScreen extends StatelessWidget {
  const ProjectsBrowseScreen({super.key, required this.userId});

  final String userId;

  @override
  Widget build(BuildContext context) {
    final repo = ProjectRepository();
    return Scaffold(
      appBar: AppBar(title: const Text('Projects')),
      body: StreamBuilder<List<ProjectRecord>>(
        stream: repo.watchProjects(userId),
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(child: Text('${snap.error}'));
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final projects = snap.data!;
          if (projects.isEmpty) {
            return const Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Abhi koi project nahi. Chat mein notes bhejo — '
                'jaise “Sharma ko 3 label sample dikhaye, rate Monday tak”. '
                'Aivy items nikaal ke confirm card dikhayega.',
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            itemCount: projects.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (context, i) {
              final p = projects[i];
              return _ProjectTile(userId: userId, project: p, repo: repo);
            },
          );
        },
      ),
    );
  }
}

class _ProjectTile extends StatelessWidget {
  const _ProjectTile({
    required this.userId,
    required this.project,
    required this.repo,
  });

  final String userId;
  final ProjectRecord project;
  final ProjectRepository repo;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () {
          Navigator.of(context).push<void>(
            MaterialPageRoute<void>(
              builder: (_) => _ProjectDetailScreen(
                userId: userId,
                project: project,
              ),
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                project.name,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              if (project.client.isNotEmpty)
                Text(
                  project.client,
                  style: theme.textTheme.bodySmall,
                ),
              const SizedBox(height: 4),
              Text(
                project.status,
                style: theme.textTheme.labelSmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProjectDetailScreen extends StatelessWidget {
  const _ProjectDetailScreen({
    required this.userId,
    required this.project,
  });

  final String userId;
  final ProjectRecord project;

  @override
  Widget build(BuildContext context) {
    final repo = ProjectRepository();
    final df = DateFormat('d MMM, h:mm a');
    return Scaffold(
      appBar: AppBar(
        title: Text(project.name),
      ),
      body: StreamBuilder<List<ProjectItemRecord>>(
        stream: repo.watchItemsForProject(userId, project.id),
        builder: (context, snap) {
          final items = snap.data ?? const <ProjectItemRecord>[];
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          if (items.isEmpty) {
            return const Padding(
              padding: EdgeInsets.all(24),
              child: Text('Is project mein items nahi. Chat se add karo.'),
            );
          }
          final waiting =
              items.where((i) => i.status == 'waiting_on_them').toList();
          final pending = items.where((i) => i.status == 'pending').toList();
          final done = items.where((i) => i.status == 'done').toList();
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: [
              if (waiting.isNotEmpty) ...[
                Text(
                  'Waiting on them',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                for (final i in waiting)
                  _ItemLine(item: i, df: df),
                const SizedBox(height: 16),
              ],
              if (pending.isNotEmpty) ...[
                Text(
                  'Pending',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                for (final i in pending)
                  _ItemLine(item: i, df: df),
                const SizedBox(height: 16),
              ],
              if (done.isNotEmpty) ...[
                Text(
                  'Done',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                for (final i in done)
                  _ItemLine(item: i, df: df),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _ItemLine extends StatelessWidget {
  const _ItemLine({required this.item, required this.df});

  final ProjectItemRecord item;
  final DateFormat df;

  @override
  Widget build(BuildContext context) {
    final due = item.dueAtMs == null
        ? null
        : df.format(DateTime.fromMillisecondsSinceEpoch(item.dueAtMs!));
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(item.title),
      subtitle: Text(
        [
          item.kind,
          projectItemStatusLabel(item.status),
          if (item.waitingOn.isNotEmpty) item.waitingOn,
          if (due != null) due,
        ].join(' · '),
      ),
    );
  }
}
