import 'package:equatable/equatable.dart';
import 'package:json_annotation/json_annotation.dart';

part 'chapter.g.dart';

@JsonSerializable()
class Chapter extends Equatable {
  final String id;
  final String title;
  final double? number;
  final String url;
  final String? date;

  const Chapter({
    required this.id,
    required this.title,
    this.number,
    required this.url,
    this.date,
  });

  factory Chapter.fromJson(Map<String, dynamic> json) => _$ChapterFromJson(json);
  Map<String, dynamic> toJson() => _$ChapterToJson(this);

  @override
  List<Object?> get props => [id, title, number, url, date];
}
