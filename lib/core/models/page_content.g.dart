// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'page_content.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

PageContent _$PageContentFromJson(Map<String, dynamic> json) => PageContent(
  url: json['url'] as String,
  headers: (json['headers'] as Map<String, dynamic>?)?.map(
    (k, e) => MapEntry(k, e as String),
  ),
  index: (json['index'] as num?)?.toInt(),
);

Map<String, dynamic> _$PageContentToJson(PageContent instance) =>
    <String, dynamic>{
      'url': instance.url,
      'headers': instance.headers,
      'index': instance.index,
    };

NovelContent _$NovelContentFromJson(Map<String, dynamic> json) => NovelContent(
  text: json['text'] as String,
  nextUrl: json['nextUrl'] as String?,
  title: json['title'] as String?,
);

Map<String, dynamic> _$NovelContentToJson(NovelContent instance) =>
    <String, dynamic>{
      'text': instance.text,
      'nextUrl': instance.nextUrl,
      'title': instance.title,
    };
