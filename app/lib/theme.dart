import 'package:flutter/material.dart';

/// Bundled monospace face — the cyberdeck typography.
const String kMonoFont = 'JetBrainsMono';

/// Status colors are semantic and independent of the dynamic (Material You)
/// accent, so live/stale/down read the same regardless of the system theme.
class StatusColors {
  static const live = Color(0xFF3DDC84); // green
  static const stale = Color(0xFFFFB020); // amber
  static const down = Color(0xFFFF5252); // red
  static const unknown = Color(0xFF8A8A8A); // grey

  static Color forStatus(String status) => switch (status) {
        'live' => live,
        'stale' => stale,
        'down' => down,
        _ => unknown,
      };
}

/// Recency color for a timestamp — the freshness LED across Health/Machines.
Color freshnessColor(DateTime ts) {
  final mins = DateTime.now().difference(ts).inMinutes;
  if (mins < 5) return StatusColors.live;
  if (mins < 60) return StatusColors.stale;
  return StatusColors.unknown;
}

/// A glowing status indicator light.
class StatusLed extends StatelessWidget {
  const StatusLed({super.key, required this.color, this.size = 12});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(color: color.withValues(alpha: 0.6), blurRadius: size / 2, spreadRadius: 0.4),
        ],
      ),
    );
  }
}

/// Builds the app theme from a (possibly dynamic) color scheme, applying the
/// monospace face and a few restrained "cyberdeck" tweaks.
ThemeData buildAisthetronTheme(ColorScheme scheme) {
  final base = ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    fontFamily: kMonoFont,
  );
  return base.copyWith(
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(
      centerTitle: false,
      backgroundColor: scheme.surface,
      titleTextStyle: base.textTheme.titleLarge?.copyWith(
        fontFamily: kMonoFont,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.5,
      ),
    ),
    dividerTheme: DividerThemeData(
      thickness: 1,
      space: 1,
      color: scheme.outlineVariant,
    ),
  );
}
