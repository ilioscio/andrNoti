import 'package:flutter/material.dart';

import 'health_view.dart';
import 'machines_view.dart';
import 'notifications_view.dart';

/// The three primary destinations of Aisthetron.
enum AppView { health, notifications, machines }

extension AppViewMeta on AppView {
  String get label => switch (this) {
        AppView.health => 'Health',
        AppView.notifications => 'Notifications',
        AppView.machines => 'Machines',
      };

  IconData get icon => switch (this) {
        AppView.health => Icons.favorite_outline,
        AppView.notifications => Icons.notifications_outlined,
        AppView.machines => Icons.dns_outlined,
      };

  IconData get activeIcon => switch (this) {
        AppView.health => Icons.favorite,
        AppView.notifications => Icons.notifications,
        AppView.machines => Icons.dns,
      };
}

/// The app shell: a labelled icon grid as the "main screen", with a persistent
/// bottom bar of the same (unlabelled) icons for quick switching. Tapping the
/// active bottom icon again — or a view's home affordance — returns to the grid.
class RootScreen extends StatefulWidget {
  const RootScreen({super.key});

  @override
  State<RootScreen> createState() => _RootScreenState();
}

class _RootScreenState extends State<RootScreen> {
  // null → the home grid; otherwise the active destination.
  AppView? _view;

  void _select(AppView? v) => setState(() => _view = v);

  @override
  Widget build(BuildContext context) {
    final Widget body = switch (_view) {
      AppView.health => HealthView(onHome: () => _select(null)),
      AppView.notifications => NotificationsView(onHome: () => _select(null)),
      AppView.machines => MachinesView(onHome: () => _select(null)),
      null => _HomeGrid(onSelect: _select),
    };

    return Scaffold(
      body: body,
      bottomNavigationBar: _AisthetronBottomBar(active: _view, onSelect: _select),
    );
  }
}

class _HomeGrid extends StatelessWidget {
  const _HomeGrid({required this.onSelect});

  final ValueChanged<AppView> onSelect;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        centerTitle: false,
        title: Image.asset('assets/IconWhite.png', height: 32),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: () => Navigator.pushNamed(context, '/config'),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: GridView.count(
            crossAxisCount: 2,
            mainAxisSpacing: 16,
            crossAxisSpacing: 16,
            children: [
              for (final v in AppView.values)
                _GridCard(view: v, onTap: () => onSelect(v)),
            ],
          ),
        ),
      ),
    );
  }
}

class _GridCard extends StatelessWidget {
  const _GridCard({required this.view, required this.onTap});

  final AppView view;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(view.icon, size: 48, color: scheme.primary),
            const SizedBox(height: 12),
            Text(view.label, style: Theme.of(context).textTheme.titleMedium),
          ],
        ),
      ),
    );
  }
}

class _AisthetronBottomBar extends StatelessWidget {
  const _AisthetronBottomBar({required this.active, required this.onSelect});

  final AppView? active;
  final ValueChanged<AppView?> onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return BottomAppBar(
      height: 64,
      padding: EdgeInsets.zero,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          for (final v in AppView.values)
            IconButton(
              isSelected: active == v,
              tooltip: v.label,
              icon: Icon(v.icon),
              selectedIcon: Icon(v.activeIcon, color: scheme.primary),
              // Tapping the active destination again returns to the home grid.
              onPressed: () => onSelect(active == v ? null : v),
            ),
        ],
      ),
    );
  }
}
