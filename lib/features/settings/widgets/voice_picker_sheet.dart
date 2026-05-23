import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/di/injection.dart';
import '../../../core/repository/voices_repository.dart';
import '../../../core/services/novel_tts_service.dart';
import '../../../core/services/voice_catalog.dart';
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

  /// Neural counterpart to [_select]. Writes the voice id (not a
  /// display name) so the underlying service can resolve it against
  /// the on-disk model path.
  void _selectNeural(NeuralVoice? voice) {
    final cubit = context.read<NovelPrefsCubit>();
    if (_isBookScoped) {
      cubit.setTtsVoiceForBook(
        widget.sourceId!,
        widget.bookId!,
        voice?.id,
      );
    } else {
      cubit.setTtsNeuralVoiceId(voice?.id);
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

  /// For neural mode, the per-book override + global pref both store a
  /// voice id (matches [NeuralVoice.id]) — never a display name.
  String _resolvedNeuralId(NovelPrefs prefs) {
    if (_isBookScoped) {
      return prefs.perBookTtsVoice[
              NovelPrefsCubit.bookKey(widget.sourceId!, widget.bookId!)] ??
          prefs.ttsNeuralVoiceId ??
          '';
    }
    return prefs.ttsNeuralVoiceId ?? '';
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
                  padding: const EdgeInsets.fromLTRB(20, 6, 20, 4),
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
                BlocBuilder<NovelPrefsCubit, NovelPrefs>(
                  buildWhen: (a, b) => a.ttsEngine != b.ttsEngine,
                  builder: (ctx, prefs) {
                    final isNeural = prefs.ttsEngine == TtsEngine.neural;
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Engine: ${isNeural ? 'Neural' : 'System'}',
                          style: TextStyle(
                            fontSize: 12,
                            color: theme.textTheme.bodySmall?.color,
                          ),
                        ),
                      ),
                    );
                  },
                ),
                Expanded(
                  child: BlocBuilder<NovelPrefsCubit, NovelPrefs>(
                    builder: (ctx, prefs) {
                      if (prefs.ttsEngine == TtsEngine.neural) {
                        return _buildNeuralList(
                          theme,
                          prefs,
                          scrollController,
                        );
                      }
                      return _buildSystemList(theme, scrollController);
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

  /// Neural-engine list. Shows every installed voice from the catalog
  /// plus a "Use default" row that clears the per-book override (or
  /// global pref) so playback falls back to whatever the engine picks
  /// by language.
  Widget _buildNeuralList(
    ThemeData theme,
    NovelPrefs prefs,
    ScrollController scrollController,
  ) {
    final repo = sl<VoicesRepository>();
    final installed = VoiceCatalog.all
        .where((v) => repo.isInstalled(v.id))
        .toList(growable: false);
    if (installed.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'No neural voices downloaded yet.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                icon: const Icon(Icons.library_music_outlined),
                label: const Text('Manage voices'),
                onPressed: () {
                  // Grab the root navigator (which owns go_router) BEFORE
                  // popping the sheet so we still have a valid context
                  // to push from once the modal is gone.
                  final router = GoRouter.of(context);
                  Navigator.pop(context);
                  router.push('/settings/tts/voices');
                },
              ),
            ],
          ),
        ),
      );
    }
    final currentId = _resolvedNeuralId(prefs);
    return ListView.builder(
      controller: scrollController,
      itemCount: installed.length + 1,
      itemBuilder: (ctx, i) {
        if (i == 0) {
          final cleared = currentId.isEmpty;
          return ListTile(
            leading: const Icon(Icons.restart_alt_rounded),
            title: const Text('Use default'),
            subtitle: const Text('Let the engine pick a voice'),
            trailing: cleared
                ? Icon(Icons.check, color: theme.colorScheme.primary)
                : null,
            onTap: () => _selectNeural(null),
          );
        }
        final v = installed[i - 1];
        final isSelected = v.id == currentId;
        return ListTile(
          leading: const Icon(Icons.record_voice_over_rounded),
          title: Text(v.displayName),
          subtitle: Text(v.language),
          trailing: isSelected
              ? Icon(Icons.check, color: theme.colorScheme.primary)
              : null,
          onTap: () => _selectNeural(v),
        );
      },
    );
  }

  /// System-engine list. Pulled out of [build] to keep the engine
  /// switch readable — body is identical to the pre-neural version.
  Widget _buildSystemList(ThemeData theme, ScrollController scrollController) {
    return FutureBuilder<List<Map<String, String>>>(
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
        final voices = snap.data ?? const <Map<String, String>>[];
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
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: locales.length + 1,
                    separatorBuilder: (_, _) => const SizedBox(width: 8),
                    itemBuilder: (ctx, i) {
                      if (i == 0) {
                        final selected = _selectedLocale == null;
                        return ChoiceChip(
                          label: const Text('All'),
                          selected: selected,
                          onSelected: (_) =>
                              setState(() => _selectedLocale = null),
                        );
                      }
                      final locale = locales[i - 1];
                      return ChoiceChip(
                        label: Text(locale),
                        selected: _selectedLocale == locale,
                        onSelected: (_) => setState(() => _selectedLocale =
                            _selectedLocale == locale ? null : locale),
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
                          leading: const Icon(Icons.restart_alt_rounded),
                          title: const Text('Use default'),
                          subtitle:
                              const Text('Let the language pick a voice'),
                          trailing: cleared
                              ? Icon(Icons.check,
                                  color: theme.colorScheme.primary)
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
                                color: theme.colorScheme.primary)
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
    );
  }
}
