// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'book_detail.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

BookDetail _$BookDetailFromJson(Map<String, dynamic> json) => BookDetail(
  id: json['id'] as String,
  title: json['title'] as String,
  cover: json['cover'] as String?,
  coverHeaders: (json['coverHeaders'] as Map<String, dynamic>?)?.map(
    (k, e) => MapEntry(k, e as String),
  ),
  url: json['url'] as String,
  description: json['description'] as String?,
  status:
      $enumDecodeNullable(_$BookStatusEnumMap, json['status']) ??
      BookStatus.unknown,
  genres:
      (json['genres'] as List<dynamic>?)?.map((e) => e as String).toList() ??
      const [],
  authors:
      (json['authors'] as List<dynamic>?)?.map((e) => e as String).toList() ??
      const [],
  chapters:
      (json['chapters'] as List<dynamic>?)
          ?.map((e) => Chapter.fromJson(e as Map<String, dynamic>))
          .toList() ??
      const [],
  type: $enumDecode(_$ProviderTypeEnumMap, json['type']),
  sourceId: json['sourceId'] as String,
);

Map<String, dynamic> _$BookDetailToJson(BookDetail instance) =>
    <String, dynamic>{
      'id': instance.id,
      'title': instance.title,
      'cover': instance.cover,
      'coverHeaders': instance.coverHeaders,
      'url': instance.url,
      'description': instance.description,
      'status': _$BookStatusEnumMap[instance.status]!,
      'genres': instance.genres,
      'authors': instance.authors,
      'chapters': instance.chapters.map((e) => e.toJson()).toList(),
      'type': _$ProviderTypeEnumMap[instance.type]!,
      'sourceId': instance.sourceId,
    };

const _$BookStatusEnumMap = {
  BookStatus.ongoing: 'ongoing',
  BookStatus.completed: 'completed',
  BookStatus.hiatus: 'hiatus',
  BookStatus.cancelled: 'cancelled',
  BookStatus.unknown: 'unknown',
};

const _$ProviderTypeEnumMap = {
  ProviderType.manga: 'manga',
  ProviderType.novel: 'novel',
  ProviderType.both: 'both',
};
