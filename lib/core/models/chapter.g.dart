// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'chapter.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

Chapter _$ChapterFromJson(Map<String, dynamic> json) => Chapter(
  id: json['id'] as String,
  title: json['title'] as String,
  number: (json['number'] as num?)?.toDouble(),
  url: json['url'] as String,
  date: json['date'] as String?,
);

Map<String, dynamic> _$ChapterToJson(Chapter instance) => <String, dynamic>{
  'id': instance.id,
  'title': instance.title,
  'number': instance.number,
  'url': instance.url,
  'date': instance.date,
};
