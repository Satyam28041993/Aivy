import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../structured_actions/models/structured_action.dart';

/// Step 6: review parsed / collected [StructuredAction] before save.
/// Returns [true] = Confirm, [false] = Edit, [null] = dismissed.
Future<bool?> showStructuredActionConfirmDialog(
  BuildContext context, {
  required StructuredAction draft,
}) {
  final df = DateFormat('d MMM y, h:mm a');
  final money = NumberFormat.currency(
    locale: 'en_IN',
    symbol: '₹',
    decimalDigits: 0,
  );
  return showDialog<bool>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) {
      return AlertDialog(
        backgroundColor: const Color(0xFF0F172A),
        title: const Text(
          'Confirm',
          style: TextStyle(color: Color(0xFFE2E8F0)),
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              _row('Type', draft.type),
              _row('Sub-type', draft.subType),
              if (draft.name.isNotEmpty) _row('Name / client', draft.name),
              if (draft.amount != null)
                _row('Amount', money.format(draft.amount)),
              if (draft.date != null)
                _row('Date', df.format(draft.date!.toLocal())),
              if (draft.note != null && draft.note!.trim().isNotEmpty)
                _row('Note', draft.note!.trim()),
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'Save ke pehle verify kar lein — auto-save nahi hota.',
                  style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Edit'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Confirm'),
          ),
        ],
      );
    },
  );
}

Widget _row(String k, String v) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          k,
          style: const TextStyle(
            color: Color(0xFF94A3B8),
            fontSize: 12,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          v,
          style: const TextStyle(
            color: Color(0xFFE2E8F0),
            fontSize: 15,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    ),
  );
}
