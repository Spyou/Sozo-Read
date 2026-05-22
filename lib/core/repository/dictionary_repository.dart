import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

/// One sense of a word — part of speech plus a list of definitions
/// and example sentences. Sliced down from the Free Dictionary API
/// payload to only the fields we render in the popup.
class DictionaryMeaning {
  const DictionaryMeaning({
    required this.partOfSpeech,
    required this.definitions,
    required this.examples,
  });

  final String partOfSpeech;
  final List<String> definitions;
  final List<String> examples;

  Map<String, dynamic> toJson() => {
        'partOfSpeech': partOfSpeech,
        'definitions': definitions,
        'examples': examples,
      };

  factory DictionaryMeaning.fromJson(Map<String, dynamic> j) =>
      DictionaryMeaning(
        partOfSpeech: (j['partOfSpeech'] as String?) ?? '',
        definitions: ((j['definitions'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(),
        examples: ((j['examples'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(),
      );
}

class DictionaryEntry {
  const DictionaryEntry({
    required this.word,
    required this.phonetic,
    required this.meanings,
  });

  final String word;
  final String phonetic;
  final List<DictionaryMeaning> meanings;

  bool get isEmpty => meanings.isEmpty;

  Map<String, dynamic> toJson() => {
        'word': word,
        'phonetic': phonetic,
        'meanings': meanings.map((m) => m.toJson()).toList(),
      };

  factory DictionaryEntry.fromJson(Map<String, dynamic> j) => DictionaryEntry(
        word: (j['word'] as String?) ?? '',
        phonetic: (j['phonetic'] as String?) ?? '',
        meanings: ((j['meanings'] as List?) ?? const [])
            .whereType<Map>()
            .map((m) =>
                DictionaryMeaning.fromJson(Map<String, dynamic>.from(m)))
            .toList(),
      );

  /// Distilled from the Free Dictionary API's response shape
  /// (`https://api.dictionaryapi.dev/api/v2/entries/en/<word>`).
  /// The API returns a list of "entries" each with its own meanings —
  /// we flatten them into a single bag, taking the first phonetic
  /// transcription we find.
  factory DictionaryEntry.fromApi(String word, List<dynamic> raw) {
    String phonetic = '';
    final meanings = <DictionaryMeaning>[];
    for (final entry in raw.whereType<Map>()) {
      if (phonetic.isEmpty) {
        final p = entry['phonetic'];
        if (p is String && p.isNotEmpty) {
          phonetic = p;
        } else {
          final list = entry['phonetics'];
          if (list is List) {
            for (final ph in list.whereType<Map>()) {
              final t = ph['text'];
              if (t is String && t.isNotEmpty) {
                phonetic = t;
                break;
              }
            }
          }
        }
      }
      final ms = entry['meanings'];
      if (ms is List) {
        for (final m in ms.whereType<Map>()) {
          final partOfSpeech = (m['partOfSpeech'] as String?) ?? '';
          final defs = <String>[];
          final examples = <String>[];
          final defList = m['definitions'];
          if (defList is List) {
            for (final d in defList.whereType<Map>()) {
              final def = d['definition'];
              if (def is String && def.isNotEmpty) defs.add(def);
              final ex = d['example'];
              if (ex is String && ex.isNotEmpty) examples.add(ex);
            }
          }
          if (defs.isNotEmpty) {
            meanings.add(DictionaryMeaning(
              partOfSpeech: partOfSpeech,
              definitions: defs,
              examples: examples,
            ));
          }
        }
      }
    }
    return DictionaryEntry(
      word: word,
      phonetic: phonetic,
      meanings: meanings,
    );
  }
}

/// On-disk cache + network fetcher for the Free Dictionary API.
/// Caches both hits and 404 markers so repeated lookups of the same
/// non-English / mistyped word don't re-hit the network every time.
class DictionaryRepository {
  DictionaryRepository({required Dio dio}) : _dio = dio;

  static const String boxName = 'dictionary_cache';
  /// Sentinel stored in the cache for words the API didn't find.
  static const String _notFoundMarker = '__not_found__';

  final Dio _dio;

  static Box<String> get _box => Hive.box<String>(boxName);

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) {
      await Hive.openBox<String>(boxName);
    }
  }

  /// Returns the cached entry, or fetches + caches it, or null when
  /// the word has no English dictionary entry.
  Future<DictionaryEntry?> lookup(String word) async {
    final key = word.trim().toLowerCase();
    if (key.isEmpty) return null;
    final cached = _box.get(key);
    if (cached == _notFoundMarker) return null;
    if (cached != null) {
      try {
        return DictionaryEntry.fromJson(
            jsonDecode(cached) as Map<String, dynamic>);
      } catch (_) {/* corrupt, fall through to refetch */}
    }
    try {
      final res = await _dio.get<List<dynamic>>(
        'https://api.dictionaryapi.dev/api/v2/entries/en/$key',
        options: Options(
          responseType: ResponseType.json,
          validateStatus: (s) => s != null && s < 500,
        ),
      );
      if (res.statusCode == 404) {
        await _box.put(key, _notFoundMarker);
        return null;
      }
      if (res.statusCode != 200 || res.data == null) {
        return null;
      }
      final entry = DictionaryEntry.fromApi(key, res.data!);
      if (entry.isEmpty) {
        await _box.put(key, _notFoundMarker);
        return null;
      }
      await _box.put(key, jsonEncode(entry.toJson()));
      return entry;
    } catch (e) {
      debugPrint('[dictionary] lookup failed for "$key": $e');
      return null;
    }
  }
}
