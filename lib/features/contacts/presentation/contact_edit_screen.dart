import 'package:flutter/material.dart';

import '../data/contact_service.dart';
import '../models/aivy_contact.dart';

/// Create or update a single contact.
class ContactEditScreen extends StatefulWidget {
  const ContactEditScreen({
    super.key,
    required this.ownerUid,
    this.contact,
  });

  final String ownerUid;
  final AivyContact? contact;

  @override
  State<ContactEditScreen> createState() => _ContactEditScreenState();
}

class _ContactEditScreenState extends State<ContactEditScreen> {
  final _service = ContactService();
  late final TextEditingController _name;
  late final TextEditingController _phone;
  late final TextEditingController _company;
  late final TextEditingController _email;
  late final TextEditingController _tags;
  late final TextEditingController _notes;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final c = widget.contact;
    _name = TextEditingController(text: c?.name ?? '');
    _phone = TextEditingController(text: c?.phone ?? '');
    _company = TextEditingController(text: c?.company ?? '');
    _email = TextEditingController(text: c?.email ?? '');
    _tags = TextEditingController(text: c?.tags.join(', ') ?? '');
    _notes = TextEditingController(text: c?.notes ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _company.dispose();
    _email.dispose();
    _tags.dispose();
    _notes.dispose();
    super.dispose();
  }

  List<String> _parseTags(String raw) {
    return raw
        .split(RegExp(r'[,\n]'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
  }

  Future<void> _delete() async {
    final c = widget.contact;
    if (c == null || _busy) {
      return;
    }
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
    setState(() => _busy = true);
    try {
      await _service.deleteContact(
        ownerUid: widget.ownerUid,
        contactId: c.id,
      );
      if (!mounted) {
        return;
      }
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e')),
      );
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _save() async {
    if (_busy) {
      return;
    }
    final nameTrim = _name.text.trim();
    if (nameTrim.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a name')),
      );
      return;
    }
    if (ContactService.normalizeIndiaPhone(_phone.text) == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Phone: use 10 digits or 91XXXXXXXXXX'),
        ),
      );
      return;
    }
    setState(() => _busy = true);
    try {
      final tags = _parseTags(_tags.text);
      if (widget.contact == null) {
        await _service.addContact(
          ownerUid: widget.ownerUid,
          name: _name.text,
          phone: _phone.text,
          company: _company.text,
          email: _email.text,
          tags: tags,
          notes: _notes.text,
        );
      } else {
        await _service.updateContact(
          ownerUid: widget.ownerUid,
          contactId: widget.contact!.id,
          name: _name.text,
          phone: _phone.text,
          company: _company.text,
          email: _email.text,
          tags: tags,
          notes: _notes.text,
        );
      }
      if (!mounted) {
        return;
      }
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e')),
      );
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isNew = widget.contact == null;
    return Scaffold(
      appBar: AppBar(
        title: Text(isNew ? 'Add contact' : 'Edit contact'),
        backgroundColor: theme.colorScheme.surface,
        actions: [
          if (!isNew)
            IconButton(
              tooltip: 'Delete',
              onPressed: _busy ? null : _delete,
              icon: Icon(
                Icons.delete_outline_rounded,
                color: theme.colorScheme.error,
              ),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          TextField(
            controller: _name,
            decoration: const InputDecoration(
              labelText: 'Name *',
              border: OutlineInputBorder(),
            ),
            textCapitalization: TextCapitalization.words,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _phone,
            decoration: const InputDecoration(
              labelText: 'Phone (91XXXXXXXXXX) *',
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.phone,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _company,
            decoration: const InputDecoration(
              labelText: 'Company',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _email,
            decoration: const InputDecoration(
              labelText: 'Email',
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.emailAddress,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _tags,
            decoration: const InputDecoration(
              labelText: 'Tags (comma separated)',
              border: OutlineInputBorder(),
              hintText: 'vip, supplier, followup',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _notes,
            decoration: const InputDecoration(
              labelText: 'Notes',
              border: OutlineInputBorder(),
            ),
            minLines: 3,
            maxLines: 8,
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _busy ? null : _save,
            icon: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_rounded),
            label: Text(isNew ? 'Create' : 'Save'),
          ),
        ],
      ),
    );
  }
}
