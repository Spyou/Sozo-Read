// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'book_item.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

BookItem _$BookItemFromJson(Map<String, dynamic> json) => BookItem(
  id: json['id'] as String,
  title: json['title'] as String,
  cover: json['cover'] as String?,
  coverHeaders: (json['coverHeaders'] as Map<String, dynamic>?)?.map(
    (k, e) => MapEntry(k, e as String),
  ),
  url: json['url'] as String,
  type: $enumDecode(_$ProviderTypeEnumMap, json['type']),
  sourceId: json['sourceId'] as String,
);

Map<String, dynamic> _$BookItemToJson(BookItem instance) => <String, dynamic>{
  'id': instance.id,
  'title': instance.title,
  'cover': instance.cover,
  'coverHeaders': instance.coverHeaders,
  'url': instance.url,
  'type': _$ProviderTypeEnumMap[instance.type]!,
  'sourceId': instance.sourceId,
};

const _$ProviderTypeEnumMap = {
  ProviderType.manga: 'manga',
  ProviderType.novel: 'novel',
  ProviderType.both: 'both',
};
