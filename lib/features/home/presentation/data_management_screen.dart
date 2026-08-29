import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../whatsapp/presentation/whatsapp_connect_screen.dart';
import '../../../core/firebase/clear_user_data_service.dart';

/// Lets the signed-in user delete Firestore data under their account
/// (full wipe or by date) via the [clearUserData] cloud function.
class DataManagementScreen extends StatefulWidget {
  const DataManagementScreen({super.key});

  @override
  State<DataManagementScreen> createState() => _DataManagementScreenState();
}

class _DataManagementScreenState extends State<DataManagementScreen> {
  final _clear = ClearUserDataService();
  final _confirmWipe = TextEditingController();
  final _testWhatsappPhone = TextEditingController();
  final _dateFormat = DateFormat.yMMMd();

  _DeleteMode _mode = _DeleteMode.freshStart;
  bool _working = false;

  @override
  void dispose() {
    _confirmWipe.dispose();
    _testWhatsappPhone.dispose();
    super.dispose();
  }

  Future<void> _runFreshStart() async {
    if (_confirmWipe.text.trim() != ClearUserDataService.wipeConfirmPhrase) {
      _toast('Type the exact phrase: ${ClearUserDataService.wipeConfirmPhrase}');
      return;
    }
    final ok = await _confirmDialog(
      title: 'Start fresh?',
      body:
          'Removes every client, quotation, order, payment, reminder, task, '
          'chat and WhatsApp message. What Aivy remembers about you and your '
          'Google settings are kept. This cannot be undone.',
    );
    if (!ok || !mounted) {
      return;
    }
    setState(() => _working = true);
    try {
      final summary = await _clear.freshStart();
      if (!mounted) {
        return;
      }
      final total = (summary?['total'] as num?)?.toInt() ?? 0;
      _confirmWipe.clear();
      _toast(
        total == 0
            ? 'Nothing left to remove — already clean.'
            : 'Removed $total records. Aivy remembers you, the data is gone.',
      );
    } on FirebaseFunctionsException catch (e) {
      _toast(e.message ?? e.code);
    } catch (e) {
      _toast(e.toString());
    } finally {
      if (mounted) {
        setState(() => _working = false);
      }
    }
  }

  Future<void> _runWipe() async {
    if (_confirmWipe.text.trim() != ClearUserDataService.wipeConfirmPhrase) {
      _toast('Type the exact phrase: ${ClearUserDataService.wipeConfirmPhrase}');
      return;
    }
    final ok = await _confirmDialog(
      title: 'Delete everything?',
      body:
          'This removes all chats, orders, reminders, and other data stored '
          'for this account in the cloud. Your Google sign-in stays active.',
    );
    if (!ok || !mounted) {
      return;
    }
    setState(() => _working = true);
    try {
      await _clear.wipeAll();
      if (!mounted) {
        return;
      }
      _toast('All cloud data for this account was removed.');
    } on FirebaseFunctionsException catch (e) {
      _toast(e.message ?? e.code);
    } catch (e) {
      _toast(e.toString());
    } finally {
      if (mounted) {
        setState(() => _working = false);
      }
    }
  }

  DateTime? _oneDate;
  DateTime? _rangeStart;
  DateTime? _rangeEnd;

  Future<void> _pickOneDate() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: _oneDate ?? now,
      firstDate: DateTime(2020),
      lastDate: DateTime(now.year + 1, 12, 31),
    );
    if (d != null) {
      setState(() => _oneDate = d);
    }
  }

  Future<void> _pickRangeStart() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: _rangeStart ?? now,
      firstDate: DateTime(2020),
      lastDate: DateTime(now.year + 1, 12, 31),
    );
    if (d != null) {
      setState(() => _rangeStart = d);
    }
  }

  Future<void> _pickRangeEnd() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: _rangeEnd ?? _rangeStart ?? now,
      firstDate: _rangeStart ?? DateTime(2020),
      lastDate: DateTime(now.year + 1, 12, 31),
    );
    if (d != null) {
      setState(() => _rangeEnd = d);
    }
  }

  Future<void> _runDateDelete() async {
    final desc = _mode == _DeleteMode.before
        ? 'with timestamps before ${_oneDate != null ? _dateFormat.format(_oneDate!) : "the chosen day"}'
        : _mode == _DeleteMode.after
        ? 'with timestamps after end of ${_oneDate != null ? _dateFormat.format(_oneDate!) : "the chosen day"}'
        : 'between ${_rangeStart != null ? _dateFormat.format(_rangeStart!) : "…"} and ${_rangeEnd != null ? _dateFormat.format(_rangeEnd!) : "…"}';

    final ok = await _confirmDialog(
      title: 'Delete matching records?',
      body:
          'Removes Firestore records $desc. Items without a stored date are '
          'kept. This cannot be undone.',
    );
    if (!ok || !mounted) {
      return;
    }

    setState(() => _working = true);
    try {
      Map<String, dynamic>? summary;
      switch (_mode) {
        case _DeleteMode.freshStart:
        case _DeleteMode.wipe:
          break;
        case _DeleteMode.before:
          if (_oneDate == null) {
            _toast('Choose a date.');
            return;
          }
          summary = await _clear.deleteBefore(_oneDate!);
        case _DeleteMode.after:
          if (_oneDate == null) {
            _toast('Choose a date.');
            return;
          }
          summary = await _clear.deleteAfter(_oneDate!);
        case _DeleteMode.between:
          if (_rangeStart == null || _rangeEnd == null) {
            _toast('Choose start and end dates.');
            return;
          }
          summary = await _clear.deleteBetween(_rangeStart!, _rangeEnd!);
      }
      if (!mounted) {
        return;
      }
      final n = summary?['totalDeleted'];
      _toast(
        n is num
            ? 'Done. Removed $n document(s) (plus nested chat messages).'
            : 'Done. Date filter completed.',
      );
    } on FirebaseFunctionsException catch (e) {
      _toast(e.message ?? e.code);
    } catch (e) {
      _toast(e.toString());
    } finally {
      if (mounted) {
        setState(() => _working = false);
      }
    }
  }

  void _toast(String m) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _runTestWhatsapp() async {
    final phone = _testWhatsappPhone.text.trim();
    if (!RegExp(r'^91\d{10}$').hasMatch(phone)) {
      _toast('Phone must be 91XXXXXXXXXX (12 digits, no +).');
      return;
    }
    setState(() => _working = true);
    try {
      final callable = FirebaseFunctions.instanceFor(
        region: 'us-central1',
      ).httpsCallable('testWhatsapp');
      final result = await callable.call(<String, String>{
          'phone': phone,
          'message': 'Test from Aivy',
        });
      if (!mounted) {
        return;
      }
      final data = (result.data is Map)
          ? Map<String, dynamic>.from(result.data as Map)
          : const <String, dynamic>{};
      if (data['success'] == true) {
        _toast('WhatsApp sent: ${data['messageId'] ?? 'ok'}');
        return;
      }
      _toast('WhatsApp send failed.');
    } on FirebaseFunctionsException catch (e) {
      if (mounted) {
        final code = e.code.toLowerCase();
        if (code == 'permission-denied') {
          _toast('Only admins can run WhatsApp test sends.');
        } else {
          _toast(e.message ?? e.code);
        }
      }
    } catch (e) {
      if (mounted) {
        _toast(e.toString());
      }
    } finally {
      if (mounted) {
        setState(() => _working = false);
      }
    }
  }

  Future<bool> _confirmDialog({
    required String title,
    required String body,
  }) async {
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
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
    return r == true;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Cloud data'),
        backgroundColor: theme.colorScheme.surface,
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            'Delete data in Firebase (cloud) for this Google account. '
            'Chats, orders, reminders, and related records are removed '
            'according to your choice below.',
            style: theme.textTheme.bodySmall?.copyWith(height: 1.4),
          ),
          const SizedBox(height: 20),
          SegmentedButton<_DeleteMode>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(
                value: _DeleteMode.freshStart,
                label: Text('Fresh'),
                icon: Icon(Icons.auto_delete_outlined, size: 18),
              ),
              ButtonSegment(
                value: _DeleteMode.wipe,
                label: Text('All'),
                icon: Icon(Icons.delete_forever_outlined, size: 18),
              ),
              ButtonSegment(
                value: _DeleteMode.before,
                label: Text('Before'),
                icon: Icon(Icons.history, size: 18),
              ),
              ButtonSegment(
                value: _DeleteMode.after,
                label: Text('After'),
                icon: Icon(Icons.update, size: 18),
              ),
              ButtonSegment(
                value: _DeleteMode.between,
                label: Text('Range'),
                icon: Icon(Icons.date_range, size: 18),
              ),
            ],
            selected: {_mode},
            onSelectionChanged: (s) {
              setState(() {
                _mode = s.first;
              });
            },
          ),
          const SizedBox(height: 20),
          if (_mode == _DeleteMode.freshStart) ...[
            Text(
              'Fresh start',
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            Text(
              'Clients, quotations, orders, payments, reminders, tasks, chats '
              'and WhatsApp history are removed.\n\n'
              'Kept: what Aivy remembers about you, and your Google settings. '
              'Your sign-in and WhatsApp connection are untouched.',
              style: theme.textTheme.bodySmall?.copyWith(height: 1.4),
            ),
            const SizedBox(height: 12),
            Text(
              'Type this phrase exactly:',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            SelectableText(
              ClearUserDataService.wipeConfirmPhrase,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
                fontFamily: 'monospace',
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _confirmWipe,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Confirmation phrase',
              ),
              enabled: !_working,
              autocorrect: false,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _working ? null : _runFreshStart,
              icon: _working
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.auto_delete_outlined),
              label: const Text('Start fresh'),
            ),
          ] else if (_mode == _DeleteMode.wipe) ...[
            Text(
              'Full reset',
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            Text(
              'Type this phrase exactly (copy from the label below):',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            SelectableText(
              ClearUserDataService.wipeConfirmPhrase,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
                fontFamily: 'monospace',
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _confirmWipe,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Confirmation phrase',
              ),
              enabled: !_working,
              autocorrect: false,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _working ? null : _runWipe,
              icon: _working
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.delete_forever),
              label: const Text('Delete all my cloud data'),
            ),
          ] else if (_mode == _DeleteMode.before) ...[
            Text(
              'Delete records strictly before the start of this calendar day. '
              'Undated items are not removed.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Cutoff day'),
              subtitle: Text(
                _oneDate != null
                    ? _dateFormat.format(_oneDate!)
                    : 'Not selected',
              ),
              trailing: const Icon(Icons.calendar_today),
              onTap: _working ? null : _pickOneDate,
            ),
            FilledButton(
              onPressed: _working ? null : _runDateDelete,
              child: const Text('Delete data before this day'),
            ),
          ] else if (_mode == _DeleteMode.after) ...[
            Text(
              'Delete records with a timestamp after the end of this calendar day. '
              'Undated items are not removed.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Day'),
              subtitle: Text(
                _oneDate != null
                    ? _dateFormat.format(_oneDate!)
                    : 'Not selected',
              ),
              trailing: const Icon(Icons.calendar_today),
              onTap: _working ? null : _pickOneDate,
            ),
            FilledButton(
              onPressed: _working ? null : _runDateDelete,
              child: const Text('Delete data after this day'),
            ),
          ] else ...[
            Text(
              'Delete records whose time falls in this range (inclusive). '
              'Undated items are not removed.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('From'),
              subtitle: Text(
                _rangeStart != null
                    ? _dateFormat.format(_rangeStart!)
                    : 'Not selected',
              ),
              trailing: const Icon(Icons.calendar_today),
              onTap: _working ? null : _pickRangeStart,
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('To'),
              subtitle: Text(
                _rangeEnd != null
                    ? _dateFormat.format(_rangeEnd!)
                    : 'Not selected',
              ),
              trailing: const Icon(Icons.calendar_today),
              onTap: _working ? null : _pickRangeEnd,
            ),
            FilledButton(
              onPressed: _working ? null : _runDateDelete,
              child: const Text('Delete data in this range'),
            ),
          ],
          const SizedBox(height: 24),
          if (_working &&
              _mode != _DeleteMode.wipe &&
              _mode != _DeleteMode.freshStart)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Center(child: CircularProgressIndicator()),
            ),
          const SizedBox(height: 32),
          Divider(color: theme.colorScheme.outlineVariant),
          const SizedBox(height: 12),
          Text(
            'WhatsApp Cloud API',
            style: theme.textTheme.titleSmall,
          ),
          const SizedBox(height: 8),
          Text(
            'Credentials live in Firestore (app_config/whatsapp). The test '
            'endpoint uses the saved token and phone number ID.',
            style: theme.textTheme.bodySmall?.copyWith(height: 1.4),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _working
                  ? null
                  : () {
                      Navigator.of(context).push<void>(
                        MaterialPageRoute<void>(
                          builder: (context) => const WhatsAppConnectScreen(),
                        ),
                      );
                    },
              icon: const Icon(Icons.settings_outlined, size: 20),
              label: const Text('Configure WhatsApp'),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _testWhatsappPhone,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: 'Test recipient (91XXXXXXXXXX)',
            ),
            enabled: !_working,
            keyboardType: TextInputType.phone,
            autocorrect: false,
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _working ? null : _runTestWhatsapp,
            icon: const Icon(Icons.sms_outlined, size: 20),
            label: const Text('Send test WhatsApp'),
          ),
        ],
      ),
    );
  }
}

enum _DeleteMode { freshStart, wipe, before, after, between }
