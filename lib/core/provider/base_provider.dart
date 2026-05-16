import '../models/book_detail.dart';
import '../models/book_item.dart';
import '../models/chapter.dart';
import '../models/page_content.dart';
import '../models/provider_info.dart';

/// Dart-side mirror of the JS provider contract.
///
/// Every JS provider in `providers/*.js` must export these functions globally:
///   - getInfo()
///   - search(query, page)
///   - getDetail(url)
///   - getChapters(url)
///   - getPages(chapterUrl)      // manga only
///   - getChapterContent(chapterUrl) // novel only
abstract class BaseProvider {
  String get sourceId;

  Future<ProviderInfo> getInfo();

  Future<List<BookItem>> search(String query, int page);

  Future<BookDetail> getDetail(String url);

  Future<List<Chapter>> getChapters(String url);

  /// Manga-only.
  Future<List<PageContent>> getPages(String chapterUrl);

  /// Novel-only.
  Future<NovelContent> getChapterContent(String chapterUrl);
}
