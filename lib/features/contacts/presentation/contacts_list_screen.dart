import 'package:file_saver/file_saver.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import 'google_contacts_list_screen.dart';
import '../../../core/auth/aivy_auth_scope.dart';
import '../data/contact_service.dart';
import '../models/aivy_contact.dart';
import '../utils/contact_excel_helper.dart';
import '../utils/contact_xlsx_picker.dart';
import 'contact_edit_screen.dart';

/// Realtime list + search + navigation to add/edit + Excel + delete.
class ContactsListScreen extends StatefulWidget {
  const ContactsListScreen({super.key});

  @override
  State<ContactsListScreen> createState() => _ContactsListScreenState();
}

class _ContactsListScreenState extends State<ContactsListScreen> {
  final _search = TextEditingController();
  final _service = ContactService();
  String _q = '';
  bool _importing = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<AivyContact> _filter(List<AivyContact> all) {
    final t = _q.trim().toLowerCase();
    if (t.isEmpty) {
      return all;
    }
    return all
        .where(
          (c) =>
              c.name.toLowerCase().contains(t) ||
              c.phone.contains(t) ||
              c.company.toLowerCase().contains(t) ||
              c.email.toLowerCase().contains(t) ||
              c.tags.any((e) => e.toLowerCase().contains(t)),
        )
        .toList(growable: false);
  }

  Future<void> _downloadTemplate() async {
    try {
      final bytes = ContactExcelHelper.buildTemplateBytes();
      await FileSaver.instance.saveFile(
        name: 'aivy_contacts_template',
        bytes: bytes,
        fileExtension: 'xlsx',
        mimeType: MimeType.microsoftExcel,
      );
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Template downloaded (check Downloads / save dialog)'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Download failed: $e')),
      );
    }
  }

  Future<void> _importExcel(String uid) async {
    final bytes = await pickXlsxBytes();
    if (bytes == null) {
      return;
    }
    if (bytes.isEmpty) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not read file bytes')),
      );
      return;
    }
    setState(() => _importing = true);
    try {
      final rows = ContactExcelHelper.parseImportBytes(bytes);
      if (rows.isEmpty) {
        if (!mounted) {
          return;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No data rows found — use row 1 as headings, data from row 2'),
          ),
        );
        return;
      }
      final result = await _service.bulkImportContacts(
        ownerUid: uid,
        rows: rows,
      );
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Import done: ${result.imported} added, ${result.skipped} skipped (invalid name/phone)',
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Import failed: $e')),
      );
    } finally {
      if (mounted) {
        setState(() => _importing = false);
      }
    }
  }

  Future<void> _confirmDeleteList(String uid, AivyContact c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete contact?'),
        content: Text('Remove ${c.name} (${c.phone})?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) {
      return;
    }
    try {
      await _service.deleteContact(ownerUid: uid, contactId: c.id);
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Deleted ${c.name}')),
      );
    } catch (e) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final uid = AivyAuthScope.of(context).uid;
    if (uid == null || uid.isEmpty) {
      return const Scaffold(
        body: Center(child: Text('Sign in required')),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Contacts'),
        backgroundColor: theme.colorScheme.surface,
        actions: [
          IconButton(
            tooltip: 'Download Excel template',
            icon: const Icon(Icons.download_outlined),
            onPressed: _importing ? null : _downloadTemplate,
          ),
          IconButton(
            tooltip: 'Import Excel (.xlsx)',
            icon: _importing
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.upload_file_outlined),
            onPressed: _importing ? null : () => _importExcel(uid),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _importing
            ? null
            : () async {
                final saved = await Navigator.of(context).push<bool>(
                  MaterialPageRoute<bool>(
                    builder: (context) => ContactEditScreen(
                      ownerUid: uid,
                      contact: null,
                    ),
                  ),
                );
                if (!context.mounted) {
                  return;
                }
                if (saved == true) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Contact saved — list updates automatically'),
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                }
              },
        icon: const Icon(Icons.person_add_alt_1_rounded),
        label: const Text('Add'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Material(
              color: theme.colorScheme.surfaceContainerHighest.withValues(
                alpha: 0.6,
              ),
              borderRadius: BorderRadius.circular(12),
              child: ListTile(
                leading: Icon(
                  Icons.contact_page_outlined,
                  color: theme.colorScheme.primary,
                ),
                title: const Text('Google Contacts'),
                subtitle: Text(
                  kIsWeb
                      ? 'Poori list + People API ke liye Android app; yahan status'
                      : 'Google account ki phone book — alag se dekhein',
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () {
                  Navigator.of(context).push<void>(
                    MaterialPageRoute<void>(
                      builder: (context) =>
                          GoogleContactsListScreen(ownerUid: uid),
                    ),
                  );
                },
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text(
              'Template: row 1 = Name, Phone, Company, Email, Tags, Notes',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              controller: _search,
              decoration: InputDecoration(
                hintText: 'Search name, phone, tags…',
                prefixIcon: const Icon(Icons.search_rounded),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                isDense: true,
              ),
              onChanged: (v) => setState(() => _q = v),
            ),
          ),
          Expanded(
            child: StreamBuilder<List<AivyContact>>(
              stream: _service.watchContacts(uid),
              builder: (context, snap) {
                if (snap.hasError) {
                  final err = '${snap.error}';
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        err,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                    ),
                  );
                }
                if (snap.connectionState == ConnectionState.waiting &&
                    !snap.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final rows = _filter(snap.data ?? const []);
                if (rows.isEmpty) {
                  return Center(
                    child: Text(
                      _q.isEmpty
                          ? 'No contacts yet.\nUse Add, Import, or WhatsApp auto-save.'
                          : 'No matches for "$_q"',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyLarge,
                    ),
                  );
                }
                return ListView.separated(
                  padding: const EdgeInsets.only(bottom: 88),
                  itemCount: rows.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final c = rows[i];
                    return ListTile(
                      title: Text(c.name),
                      subtitle: Text(
                        [
                          c.phone,
                          if (c.company.isNotEmpty) c.company,
                          if (c.tags.isNotEmpty) c.tags.join(', '),
                        ].where((e) => e.isNotEmpty).join(' · '),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: 'Delete',
                            icon: Icon(
                              Icons.delete_outline_rounded,
                              color: theme.colorScheme.error,
                            ),
                            onPressed: _importing
                                ? null
                                : () => _confirmDeleteList(uid, c),
                          ),
                          Icon(
                            Icons.chevron_right_rounded,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ],
                      ),
                      onTap: _importing
                          ? null
                          : () async {
                              final saved =
                                  await Navigator.of(context).push<bool>(
                                MaterialPageRoute<bool>(
                                  builder: (context) => ContactEditScreen(
                                    ownerUid: uid,
                                    contact: c,
                                  ),
                                ),
                              );
                              if (!context.mounted) {
                                return;
                              }
                              if (saved == true) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('Contact updated'),
                                    behavior: SnackBarBehavior.floating,
                                  ),
                                );
                              }
                            },
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
