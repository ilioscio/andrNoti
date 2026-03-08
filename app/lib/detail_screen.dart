import 'package:flutter/material.dart';

import 'models.dart';

String _fmt(DateTime dt) {
  final d = dt.toLocal();
  String p(int v, [int w = 2]) => v.toString().padLeft(w, '0');
  return '${d.year}-${p(d.month)}-${p(d.day)} ${p(d.hour)}:${p(d.minute)}:${p(d.second)}';
}

class DetailScreen extends StatelessWidget {
  const DetailScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final n = ModalRoute.of(context)!.settings.arguments as AppNotification;
    final formatted = _fmt(n.createdAt);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Notification'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (n.title.isNotEmpty) ...[
              Text(
                n.title,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
            ],
            Row(
              children: [
                Text(
                  formatted,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.outline,
                      ),
                ),
                if (n.source.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      n.source,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 16),
            const Divider(),
            const SizedBox(height: 16),
            SelectableText(
              n.text,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
          ],
        ),
      ),
    );
  }
}
