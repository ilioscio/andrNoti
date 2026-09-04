/// Compact relative-time label, e.g. "just now", "5m ago", "3h ago", "2d ago".
/// Accepts UTC or local [DateTime]; comparison is instant-based either way.
String relativeTime(DateTime dt) {
  final diff = DateTime.now().difference(dt);
  if (diff.inSeconds < 60) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  return '${diff.inDays}d ago';
}
