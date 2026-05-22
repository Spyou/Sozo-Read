import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/di/injection.dart';
import '../../../core/services/novel_tts_service.dart';
import '../../../core/state/novel_prefs_cubit.dart';
import '../../../core/theme/app_colors.dart';

/// Bottom sheet that lists every voice exposed by the OS TTS engine and
/// lets the user pick one — either as the global default, or as a
/// per-book override when [sourceId] / [bookId] are provided.
///
/// The list can run into hundreds of entries on devices with multiple
/// Google / Samsung voice packs installed, so we lazy-build the rows via
/// a `ListView.builder` inside a [DraggableScrollableSheet]. Filtering
/// by locale keeps the practical visible row count under ~30 in all
/// the common cases we tested.
class VoicePickerSheet extends StatefulWidget {
  const VoicePickerSheet._({
    required this.sourceId,
    required this.bookId,
  });

  final String? sourceId;
  final String? bookId;

  static Future<void> show(
    BuildContext context, {
    String? sourceId,
    String? bookId,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      // The cubit lives above this sheet's route — pass it down explicitly
      // so the sheet can read state + dispatch setters without relying on
      // an ancestor BlocProvider being present in modal route context.
      builder: (ctx) => BlocProvider.value(
        value: context.read<NovelPrefsCubit>(),
        child: VoicePickerSheet._(sourceId: sourceId, bookId: bookId),
      ),
    );
  }

  @override
  State<VoicePickerSheet> createState() => _VoicePickerSheetState();
}

class _VoicePickerSheetState extends State<VoicePickerSheet> {
  late Future<List<Map<String, String>>> _future;
  String? _selectedLocale;

  bool get _isBookScoped =>
      widget.sourceId != null && widget.bookId != null;

  @override
  void initState() {
    super.initState();
    _future = sl<NovelTtsService>().availableVoices();
  }

  /// Writes the chosen voice to either the per-book override map or the
  /// global preference, then mirrors it onto the live TTS engine so the
  /// next paragraph speaks with the new voice.
  void _select(Map<String, String>? voice) {
    final cubit = context.read<NovelPrefsCubit>();
    final name = voice?['name'];
    if (_isBookScoped) {
      cubit.setTtsVoiceForBook(widget.sourceId!, widget.bookId!, name);
    } else {
      cubit.setTtsVoiceName(name);
    }
    if (voice != null) {
      // ignore: discarded_futures
      sl<NovelTtsService>().setVoice(voice);
      final locale = voice['locale'];
      if (locale != null && locale.isNotEmpty) {
        cubit.setTtsLanguage(locale);
        // ignore: discarded_futures
        sl<NovelTtsService>().setLanguage(locale);
      }
    }
    Navigator.pop(context);
  }

  String _resolvedVoiceName(NovelPrefs prefs) {
    if (_isBookScoped) {
      return prefs.perBookTtsVoice[
              NovelPrefsCubit.bookKey(widget.sourceId!, widget.bookId!)] ??
          prefs.ttsVoiceName ??
          '';
    }
    return prefs.ttsVoiceName ?? '';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (ctx, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(16)),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 10, bottom: 6),
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: (theme.textTheme.labelSmall?.color ??
                              AppColors.textTertiary)
                          .withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 6, 20, 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _isBookScoped ? 'Voice (this book)' : 'Voice',
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: FutureBuilder<List<Map<String, String>>>(
                    future: _future,
                    builder: (ctx, snap) {
                      if (snap.connectionState != ConnectionState.done) {
                        return const Center(
                          child: Padding(
                            padding: EdgeInsets.all(24),
                            child: CircularProgressIndicator(),
                          ),
                        );
                      }
                      final voices = snap.data ?? const [];
                      if (voices.isEmpty) {
                        return const Center(
                          child: Padding(
                            padding: EdgeInsets.all(24),
                            child: Text(
                              'No voices available on this device.',
                              textAlign: TextAlign.center,
                            ),
                          ),
                        );
                      }
                      // Distinct locale list, sorted so the chip row is stable.
                      final locales = voices
                          .map((v) => v['locale'] ?? '')
                          .where((l) => l.isNotEmpty)
                          .toSet()
                          .toList()
                        ..sort();
                      final filtered = _selectedLocale == null
                          ? voices
                          : voices
                              .where((v) => v['locale'] == _selectedLocale)
                              .toList(growable: false);
                      return BlocBuilder<NovelPrefsCubit, NovelPrefs>(
                        builder: (ctx, prefs) {
                          final currentName = _resolvedVoiceName(prefs);
                          return Column(
                            children: [
                              SizedBox(
                                height: 44,
                                child: ListView.separated(
                                  scrollDirection: Axis.horizontal,
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 16),
                                  itemCount: locales.length + 1,
                                  separatorBuilder: (_, _) =>
                                      const SizedBox(width: 8),
                                  itemBuilder: (ctx, i) {
                                    if (i == 0) {
                                      final selected = _selectedLocale == null;
                                      return ChoiceChip(
                                        label: const Text('All'),
                                        selected: selected,
                                        onSelected: (_) => setState(
                                            () => _selectedLocale = null),
                                      );
                                    }
                                    final locale = locales[i - 1];
                                    return ChoiceChip(
                                      label: Text(locale),
                                      selected: _selectedLocale == locale,
                                      onSelected: (_) => setState(() =>
                                          _selectedLocale =
                                              _selectedLocale == locale
                                                  ? null
                                                  : locale),
                                    );
                                  },
                                ),
                              ),
                              const SizedBox(height: 4),
                              Expanded(
                                child: ListView.builder(
                                  controller: scrollController,
                                  // +1 for the "Use default" row pinned at top.
                                  itemCount: filtered.length + 1,
                                  itemBuilder: (ctx, i) {
                                    if (i == 0) {
                                      final cleared = currentName.isEmpty;
                                      return ListTile(
                                        leading: const Icon(
                                            Icons.restart_alt_rounded),
                                        title: const Text('Use default'),
                                        subtitle: const Text(
                                            'Let the language pick a voice'),
                                        trailing: cleared
                                            ? Icon(Icons.check,
                                                color: theme
                                                    .colorScheme.primary)
                                            : null,
                                        onTap: () => _select(null),
                                      );
                                    }
                                    final v = filtered[i - 1];
                                    final name = v['name'] ?? '';
                                    final locale = v['locale'] ?? '';
                                    final isSelected = name == currentName;
                                    return ListTile(
                                      title: Text(name),
                                      subtitle: Text(locale),
                                      trailing: isSelected
                                          ? Icon(Icons.check,
                                              color:
                                                  theme.colorScheme.primary)
                                          : null,
                                      onTap: () => _select(v),
                                    );
                                  },
                                ),
                              ),
                            ],
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
