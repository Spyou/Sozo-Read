import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/di/injection.dart';
import '../../../core/services/novel_tts_service.dart';
import '../../../core/state/novel_prefs_cubit.dart';
import '../../../core/theme/app_colors.dart';

/// `/settings/tts/pronunciations` — manages the keyword → phonetic map
/// applied to chapter text immediately before each `speak()` call.
///
/// Matching is whole-word, case-insensitive (see [NovelTtsService] —
/// the engine lowercases keys at write-time and matches against
/// `[A-Za-z][A-Za-z’]*` token boundaries at speak-time, so partial /
/// substring matches inside longer words are intentionally NOT applied).
class TtsPronunciationsScreen extends StatelessWidget {
  const TtsPronunciationsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider.value(
      value: sl<NovelPrefsCubit>(),
      child: const _Body(),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body();

  void _syncEngine(Map<String, String> map) {
    sl<NovelTtsService>().setPronunciations(map);
  }

  Future<void> _editEntry(
    BuildContext context, {
    String? originalKey,
    String? originalValue,
  }) async {
    final keyCtrl = TextEditingController(text: originalKey ?? '');
    final valCtrl = TextEditingController(text: originalValue ?? '');
    final isEdit = originalKey != null;
    final result = await showDialog<(String, String)?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isEdit ? 'Edit pronunciation' : 'Add pronunciation'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: keyCtrl,
              autofocus: !isEdit,
              decoration: const InputDecoration(
                labelText: 'Original word',
                hintText: 'e.g. Kael',
              ),
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: valCtrl,
              autofocus: isEdit,
              decoration: const InputDecoration(
                labelText: 'Phonetic spelling',
                hintText: 'e.g. Kale',
              ),
              textInputAction: TextInputAction.done,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, null),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              final k = keyCtrl.text.trim();
              final v = valCtrl.text.trim();
              if (k.isEmpty || v.isEmpty) {
                Navigator.pop(ctx, null);
                return;
              }
              Navigator.pop(ctx, (k, v));
            },
            child: Text(isEdit ? 'Save' : 'Add'),
          ),
        ],
      ),
    );
    if (!context.mounted || result == null) return;
    final cubit = context.read<NovelPrefsCubit>();
    // Rename: drop the old key first so a key-edit doesn't leave both
    // the old and new entry active in the lookup map.
    if (isEdit && originalKey.toLowerCase() != result.$1.toLowerCase()) {
      cubit.setTtsPronunciation(originalKey, null);
    }
    cubit.setTtsPronunciation(result.$1, result.$2);
    _syncEngine(cubit.state.ttsPronunciations);
  }

  Future<void> _confirmDelete(BuildContext context, String key) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete entry?'),
        content: Text('Remove the pronunciation for "$key"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: AppColors.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (!context.mounted || ok != true) return;
    final cubit = context.read<NovelPrefsCubit>();
    cubit.setTtsPronunciation(key, null);
    _syncEngine(cubit.state.ttsPronunciations);
  }

  Future<void> _confirmClearAll(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear all?'),
        content: const Text(
            'This removes every saved pronunciation. The action cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: AppColors.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear all'),
          ),
        ],
      ),
    );
    if (!context.mounted || ok != true) return;
    final cubit = context.read<NovelPrefsCubit>();
    cubit.setTtsPronunciations(const <String, String>{});
    _syncEngine(const <String, String>{});
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<NovelPrefsCubit, NovelPrefs>(
      builder: (context, prefs) {
        final entries = prefs.ttsPronunciations.entries.toList()
          ..sort((a, b) => a.key.compareTo(b.key));
        return Scaffold(
          appBar: AppBar(
            title: const Text('Pronunciations'),
            centerTitle: true,
            actions: [
              PopupMenuButton<String>(
                onSelected: (v) {
                  if (v == 'clear') _confirmClearAll(context);
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'clear', child: Text('Clear all')),
                ],
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton(
            onPressed: () => _editEntry(context),
            child: const Icon(Icons.add),
          ),
          body: entries.isEmpty
              ? const _EmptyState()
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: entries.length,
                  separatorBuilder: (_, _) => const Divider(
                    height: 1,
                    thickness: 0.5,
                    indent: 20,
                    endIndent: 20,
                  ),
                  itemBuilder: (ctx, i) {
                    final e = entries[i];
                    return ListTile(
                      title: Text(e.key),
                      subtitle: Text('→ ${e.value}'),
                      onTap: () => _editEntry(
                        context,
                        originalKey: e.key,
                        originalValue: e.value,
                      ),
                      onLongPress: () => _confirmDelete(context, e.key),
                    );
                  },
                ),
        );
      },
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).textTheme.bodySmall?.color;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.spellcheck_outlined, size: 48, color: muted),
            const SizedBox(height: 16),
            const Text(
              'No pronunciations yet',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              'Add an entry to replace a word with a phonetic spelling before TTS reads it. Matching is whole-word and case-insensitive.',
              textAlign: TextAlign.center,
              style: TextStyle(color: muted),
            ),
          ],
        ),
      ),
    );
  }
}
