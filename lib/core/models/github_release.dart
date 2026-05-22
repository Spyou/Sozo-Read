/// GitHub release payload — slice of the
/// `https://api.github.com/repos/.../releases` response we actually
/// care about (tag, name, body, date, prerelease flag, html URL).
class GitHubRelease {
  const GitHubRelease({
    required this.tagName,
    required this.name,
    required this.body,
    required this.publishedAt,
    required this.htmlUrl,
    required this.prerelease,
  });

  final String tagName;
  final String name;
  final String body;
  final DateTime publishedAt;
  final String htmlUrl;
  final bool prerelease;

  factory GitHubRelease.fromJson(Map<String, dynamic> j) => GitHubRelease(
        tagName: (j['tag_name'] as String?) ?? '',
        name: (j['name'] as String?) ?? (j['tag_name'] as String?) ?? '',
        body: (j['body'] as String?) ?? '',
        publishedAt: DateTime.tryParse(j['published_at'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
        htmlUrl: (j['html_url'] as String?) ?? '',
        prerelease: (j['prerelease'] as bool?) ?? false,
      );

  Map<String, dynamic> toJson() => {
        'tag_name': tagName,
        'name': name,
        'body': body,
        'published_at': publishedAt.toIso8601String(),
        'html_url': htmlUrl,
        'prerelease': prerelease,
      };
}
