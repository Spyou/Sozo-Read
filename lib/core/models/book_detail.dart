import 'package:equatable/equatable.dart';
import 'package:json_annotation/json_annotation.dart';

import 'chapter.dart';
import 'provider_info.dart';

part 'book_detail.g.dart';

enum BookStatus {
  @JsonValue('ongoing')
  ongoing,
  @JsonValue('completed')
  completed,
  @JsonValue('hiatus')
  hiatus,
  @JsonValue('cancelled')
  cancelled,
  @JsonValue('unknown')
  unknown,
}

@JsonSerializable(explicitToJson: true)
class BookDetail extends Equatable {
  final String id;
  final String title;
  final String? cover;
  final Map<String, String>? coverHeaders;
  final String url;
  final String? description;
  final BookStatus status;
  final List<String> genres;
  final List<String> authors;
  final List<Chapter> chapters;
  final ProviderType type;
  final String sourceId;

  const BookDetail({
    required this.id,
    required this.title,
    this.cover,
    this.coverHeaders,
    required this.url,
    this.description,
    this.status = BookStatus.unknown,
    this.genres = const [],
    this.authors = const [],
    this.chapters = const [],
    required this.type,
    required this.sourceId,
  });

  factory BookDetail.fromJson(Map<String, dynamic> json) => _$BookDetailFromJson(json);
  Map<String, dynamic> toJson() => _$BookDetailToJson(this);

  @override
  List<Object?> get props => [id, title, cover, coverHeaders, url, description, status, genres, authors, chapters, type, sourceId];
}
