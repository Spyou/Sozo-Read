import 'package:equatable/equatable.dart';

/// One curated repo listing from the public Sozo Read directory.
///
/// Each entry points at an existing provider-repo manifest (the same
/// `index.json` format the Repos tab tracks). Tapping "Install" in the
/// Discover tab just hands [repoUrl] to the existing seed-repo flow.
/// The directory is repo-level — individual sources inside a repo are
/// not surfaced here.
class DirectoryEntry extends Equatable {
  const DirectoryEntry({
    required this.name,
    required this.repoUrl,
    this.author = '',
    this.description = '',
    this.tags = const <String>[],
    this.logo,
    this.verified = false,
  });

  /// Human-readable name of the repo (e.g. "Spyou's manga + novel sources").
  final String name;

  /// URL of the repo's `index.json` manifest. Handed to
  /// `ProviderReposRegistry.seedDefaultRepo` on Install.
  final String repoUrl;

  /// Repo maintainer's display name / handle.
  final String author;

  /// One-line summary shown under the name.
  final String description;

  /// Free-form labels rendered as small chips (e.g. "manga", "novel",
  /// "english"). Capped to ~3 visible in the card UI.
  final List<String> tags;

  /// Optional logo / cover image URL. Falls back to a tinted placeholder
  /// when missing.
  final String? logo;

  /// Whether the directory marks this entry as vetted by Spyou. The UI
  /// renders a small badge next to the name; unverified entries get a
  /// "community" tag instead.
  final bool verified;

  factory DirectoryEntry.fromJson(Map<String, dynamic> json) {
    final rawTags = json['tags'];
    final tags = <String>[];
    if (rawTags is List) {
      for (final t in rawTags) {
        if (t is String && t.isNotEmpty) tags.add(t);
      }
    }
    return DirectoryEntry(
      name: (json['name'] as String?)?.trim() ?? '',
      repoUrl: (json['repoUrl'] as String?)?.trim() ?? '',
      author: (json['author'] as String?)?.trim() ?? '',
      description: (json['description'] as String?)?.trim() ?? '',
      tags: tags,
      logo: (json['logo'] as String?)?.trim().isEmpty == false
          ? (json['logo'] as String).trim()
          : null,
      verified: (json['verified'] as bool?) ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'repoUrl': repoUrl,
        'author': author,
        'description': description,
        'tags': tags,
        if (logo != null) 'logo': logo,
        'verified': verified,
      };

  @override
  List<Object?> get props => [
        name,
        repoUrl,
        author,
        description,
        tags,
        logo,
        verified,
      ];
}
