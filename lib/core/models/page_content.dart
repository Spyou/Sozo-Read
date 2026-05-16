import 'package:equatable/equatable.dart';
import 'package:json_annotation/json_annotation.dart';

part 'page_content.g.dart';

@JsonSerializable()
class PageContent extends Equatable {
  final String url;
  final Map<String, String>? headers;
  final int? index;

  const PageContent({
    required this.url,
    this.headers,
    this.index,
  });

  factory PageContent.fromJson(Map<String, dynamic> json) => _$PageContentFromJson(json);
  Map<String, dynamic> toJson() => _$PageContentToJson(this);

  @override
  List<Object?> get props => [url, headers, index];
}

@JsonSerializable()
class NovelContent extends Equatable {
  final String text;
  final String? nextUrl;
  final String? title;

  const NovelContent({
    required this.text,
    this.nextUrl,
    this.title,
  });

  factory NovelContent.fromJson(Map<String, dynamic> json) => _$NovelContentFromJson(json);
  Map<String, dynamic> toJson() => _$NovelContentToJson(this);

  @override
  List<Object?> get props => [text, nextUrl, title];
}
