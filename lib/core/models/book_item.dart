import 'package:equatable/equatable.dart';
import 'package:json_annotation/json_annotation.dart';

import 'provider_info.dart';

part 'book_item.g.dart';

@JsonSerializable()
class BookItem extends Equatable {
  final String id;
  final String title;
  final String? cover;
  final Map<String, String>? coverHeaders;
  final String url;
  final ProviderType type;
  final String sourceId;

  const BookItem({
    required this.id,
    required this.title,
    this.cover,
    this.coverHeaders,
    required this.url,
    required this.type,
    required this.sourceId,
  });

  factory BookItem.fromJson(Map<String, dynamic> json) => _$BookItemFromJson(json);
  Map<String, dynamic> toJson() => _$BookItemToJson(this);

  BookItem copyWith({
    String? id,
    String? title,
    String? cover,
    Map<String, String>? coverHeaders,
    String? url,
    ProviderType? type,
    String? sourceId,
  }) =>
      BookItem(
        id: id ?? this.id,
        title: title ?? this.title,
        cover: cover ?? this.cover,
        coverHeaders: coverHeaders ?? this.coverHeaders,
        url: url ?? this.url,
        type: type ?? this.type,
        sourceId: sourceId ?? this.sourceId,
      );

  @override
  List<Object?> get props => [id, title, cover, coverHeaders, url, type, sourceId];
}
