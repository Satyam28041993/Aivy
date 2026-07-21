import 'package:flutter/material.dart';

import '../../application/flow_catalog.dart';

/// Step 4: sub-type options for [categoryId] (e.g. Payment received / due / follow-up).
Future<FlowSubcategoryOption?> showSubcategorySelector(
  BuildContext context, {
  required String categoryId,
}) {
  final options = subcategoriesFor(categoryId);
  return showModalBottomSheet<FlowSubcategoryOption>(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(0xFF121826),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Type',
                style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                      color: const Color(0xFFE2E8F0),
                      fontWeight: FontWeight.w600,
                    ),
              ),
              const SizedBox(height: 4),
              Text(
                'Details chuniye',
                style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                      color: const Color(0xFF94A3B8),
                    ),
              ),
              const SizedBox(height: 12),
              if (options.isEmpty)
                Text(
                  'No sub-options for this category.',
                  style: Theme.of(ctx).textTheme.bodyMedium?.copyWith(
                        color: const Color(0xFF94A3B8),
                      ),
                )
              else
                ...options.map(
                  (c) => Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Material(
                      color: const Color(0xFF0F172A),
                      borderRadius: BorderRadius.circular(12),
                      child: InkWell(
                        onTap: () => Navigator.of(ctx).pop(c),
                        borderRadius: BorderRadius.circular(12),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 14,
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  c.label,
                                  style: const TextStyle(
                                    color: Color(0xFFE2E8F0),
                                    fontSize: 16,
                                  ),
                                ),
                              ),
                              const Icon(
                                Icons.chevron_right_rounded,
                                color: Color(0xFF64748B),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );
}
