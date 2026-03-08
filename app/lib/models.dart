class AppNotification {
  final int id;
  final String title;
  final String text;
  final String source; // empty string when no source was set
  final DateTime createdAt;
  final DateTime? seenAt;

  const AppNotification({
    required this.id,
    required this.title,
    required this.text,
    this.source = '',
    required this.createdAt,
    this.seenAt,
  });

  factory AppNotification.fromJson(Map<String, dynamic> json) {
    return AppNotification(
      id: (json['id'] as num).toInt(),
      title: (json['title'] as String?) ?? '',
      text: json['text'] as String,
      source: (json['source'] as String?) ?? '',
      createdAt: DateTime.parse(json['created_at'] as String),
      seenAt: json['seen_at'] != null
          ? DateTime.parse(json['seen_at'] as String)
          : null,
    );
  }

  @override
  String toString() => 'AppNotification(id: $id, source: $source, title: $title)';
}
