/// GitHub release payload — slice of the
/// `https://api.github.com/repos/.../releases` response we actually
/// care about (tag, name, body, date, prerelease flag, html URL, assets).
class GitHubRelease {
  const GitHubRelease({
    required this.tagName,
    required this.name,
    required this.body,
    required this.publishedAt,
    required this.htmlUrl,
    required this.prerelease,
    required this.assets,
  });

  final String tagName;
  final String name;
  final String body;
  final DateTime publishedAt;
  final String htmlUrl;
  final bool prerelease;
  final List<GitHubReleaseAsset> assets;

  factory GitHubRelease.fromJson(Map<String, dynamic> j) => GitHubRelease(
        tagName: (j['tag_name'] as String?) ?? '',
        name: (j['name'] as String?) ?? (j['tag_name'] as String?) ?? '',
        body: (j['body'] as String?) ?? '',
        publishedAt: DateTime.tryParse(j['published_at'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
        htmlUrl: (j['html_url'] as String?) ?? '',
        prerelease: (j['prerelease'] as bool?) ?? false,
        assets: ((j['assets'] as List<dynamic>?) ?? const <dynamic>[])
            .whereType<Map<String, dynamic>>()
            .map(GitHubReleaseAsset.fromJson)
            .toList(),
      );

  Map<String, dynamic> toJson() => {
        'tag_name': tagName,
        'name': name,
        'body': body,
        'published_at': publishedAt.toIso8601String(),
        'html_url': htmlUrl,
        'prerelease': prerelease,
        'assets': assets.map((a) => a.toJson()).toList(),
      };

  /// Convenience: first APK asset attached to this release, or null.
  GitHubReleaseAsset? get apkAsset {
    for (final a in assets) {
      if (a.name.toLowerCase().endsWith('.apk')) return a;
    }
    return null;
  }
}

/// One file attached to a GitHub release (APK, source archive, etc).
class GitHubReleaseAsset {
  const GitHubReleaseAsset({
    required this.name,
    required this.browserDownloadUrl,
    required this.size,
  });

  final String name;
  final String browserDownloadUrl;
  final int size;

  factory GitHubReleaseAsset.fromJson(Map<String, dynamic> j) =>
      GitHubReleaseAsset(
        name: (j['name'] as String?) ?? '',
        browserDownloadUrl: (j['browser_download_url'] as String?) ?? '',
        size: (j['size'] as int?) ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'browser_download_url': browserDownloadUrl,
        'size': size,
      };
}
