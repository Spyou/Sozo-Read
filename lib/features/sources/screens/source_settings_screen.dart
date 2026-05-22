import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/di/injection.dart';
import '../../../core/models/provider_setting_schema.dart';
import '../../../core/provider/provider_manager.dart';
import '../../../core/repository/provider_settings_repository.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/state_views.dart';

/// `/sources/:sourceId/settings` — generic form rendered from the
/// provider's `getSettings()` schema. The composite `(repoUrl,
/// sourceId)` key is required because two repos publishing the same
/// `sourceId` keep independent settings.
class SourceSettingsScreen extends StatefulWidget {
  const SourceSettingsScreen({
    super.key,
    required this.sourceId,
    required this.repoUrl,
    this.displayName,
  });

  final String sourceId;
  final String repoUrl;

  /// Optional pre-fetched display name — saves an extra resolve hop
  /// when the caller already knows the source's pretty name.
  final String? displayName;

  @override
  State<SourceSettingsScreen> createState() => _SourceSettingsScreenState();
}

class _SourceSettingsScreenState extends State<SourceSettingsScreen> {
  late Future<List<ProviderSettingSchema>?> _schemaFuture;
  Map<String, dynamic> _values = <String, dynamic>{};
  bool _initialised = false;

  // One debounce timer per text field so typing in two boxes back to
  // back doesn't cancel each other's pending save.
  final Map<String, Timer> _textDebounce = {};

  ProviderSettingsRepository get _repo => sl<ProviderSettingsRepository>();
  ProviderManager get _manager => sl<ProviderManager>();

  @override
  void initState() {
    super.initState();
    _schemaFuture = _loadSchema();
  }

  @override
  void dispose() {
    for (final t in _textDebounce.values) {
      t.cancel();
    }
    super.dispose();
  }

  Future<List<ProviderSettingSchema>?> _loadSchema() async {
    final provider = _manager.get(widget.sourceId);
    if (provider == null) return null;
    final raw = await provider.getSettingsSchema();
    if (raw == null) return null;
    final parsed = ProviderSettingSchema.parseAll(raw);
    // Seed values: saved row blended on top of schema defaults so
    // newly-introduced fields appear with their default selected.
    final saved = _repo.getFor(widget.repoUrl, widget.sourceId);
    final values = <String, dynamic>{};
    for (final entry in parsed) {
      if (saved.containsKey(entry.key)) {
        values[entry.key] = _coerceSavedValue(entry, saved[entry.key]);
      } else {
        values[entry.key] = entry.defaultValue;
      }
    }
    if (mounted) {
      setState(() {
        _values = values;
        _initialised = true;
      });
    } else {
      _values = values;
      _initialised = true;
    }
    return parsed;
  }

  /// Saved Hive values come back as `dynamic` — re-shape them to the
  /// type the schema expects so the form doesn't crash when an old
  /// row's payload doesn't match a renamed field's new type.
  Object? _coerceSavedValue(ProviderSettingSchema schema, Object? raw) {
    switch (schema.type) {
      case ProviderSettingType.bool_:
        return raw is bool ? raw : schema.defaultValue;
      case ProviderSettingType.enum_:
        if (raw is String && schema.options.any((o) => o.value == raw)) {
          return raw;
        }
        return schema.defaultValue;
      case ProviderSettingType.multiEnum:
        if (raw is List) {
          final allowed = schema.options.map((o) => o.value).toSet();
          return raw.whereType<String>().where(allowed.contains).toList();
        }
        return schema.defaultValue;
      case ProviderSettingType.text:
        return raw is String ? raw : schema.defaultValue;
    }
  }

  /// Persist the current map and mirror it into the JS runtime so the
  /// very next provider call (e.g. the user backing out to Home and
  /// pulling-to-refresh) reads the updated values.
  Future<void> _persist() async {
    await _repo.setFor(widget.repoUrl, widget.sourceId, _values);
    _manager.setSettings(widget.sourceId, _values);
  }

  void _updateImmediate(String key, Object? value) {
    setState(() => _values[key] = value);
    // ignore: discarded_futures
    _persist();
  }

  void _updateDebounced(String key, String value) {
    setState(() => _values[key] = value);
    _textDebounce[key]?.cancel();
    _textDebounce[key] = Timer(const Duration(milliseconds: 300), () {
      // ignore: discarded_futures
      _persist();
    });
  }

  Future<void> _resetDefaults(List<ProviderSettingSchema> schema) async {
    final defaults = <String, dynamic>{
      for (final s in schema) s.key: s.defaultValue,
    };
    setState(() => _values = defaults);
    await _persist();
  }

  Future<void> _pickEnum(ProviderSettingSchema schema) async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        final current = _values[schema.key] as String?;
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Text(
                  schema.label,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              for (final opt in schema.options)
                ListTile(
                  onTap: () => Navigator.pop(ctx, opt.value),
                  title: Text(
                    opt.label,
                    style: const TextStyle(color: AppColors.textPrimary),
                  ),
                  trailing: Icon(
                    current == opt.value
                        ? Icons.radio_button_checked_rounded
                        : Icons.radio_button_unchecked_rounded,
                    color: current == opt.value
                        ? AppColors.primary
                        : AppColors.textTertiary,
                  ),
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
    if (selected != null) _updateImmediate(schema.key, selected);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(widget.displayName ?? widget.sourceId),
      ),
      body: FutureBuilder<List<ProviderSettingSchema>?>(
        future: _schemaFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting ||
              !_initialised && snapshot.data != null) {
            return const LoadingView();
          }
          if (snapshot.hasError) {
            return ErrorView(
              message: 'Could not load settings:\n${snapshot.error}',
            );
          }
          final schema = snapshot.data;
          if (schema == null) {
            return const EmptyView(
              message: 'This source has no settings.',
              icon: Icons.tune_rounded,
            );
          }
          if (schema.isEmpty) {
            return const EmptyView(
              message: 'This source has no settings.',
              icon: Icons.tune_rounded,
            );
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
            children: [
              for (final entry in schema) _buildEntry(entry),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: TextButton.icon(
                  onPressed: () => _resetDefaults(schema),
                  icon: const Icon(
                    Icons.restore_rounded,
                    color: AppColors.textSecondary,
                  ),
                  label: const Text(
                    'Reset to defaults',
                    style: TextStyle(color: AppColors.textSecondary),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildEntry(ProviderSettingSchema schema) {
    switch (schema.type) {
      case ProviderSettingType.bool_:
        final v = _values[schema.key] as bool? ?? false;
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(10),
          ),
          child: SwitchListTile.adaptive(
            value: v,
            activeThumbColor: AppColors.primary,
            title: Text(
              schema.label,
              style: const TextStyle(color: AppColors.textPrimary),
            ),
            onChanged: (next) => _updateImmediate(schema.key, next),
          ),
        );
      case ProviderSettingType.enum_:
        final current = _values[schema.key] as String?;
        final label = schema.options
            .firstWhere(
              (o) => o.value == current,
              orElse: () => ProviderSettingOption(
                value: current ?? '',
                label: current ?? '',
              ),
            )
            .label;
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(10),
          ),
          child: ListTile(
            title: Text(
              schema.label,
              style: const TextStyle(color: AppColors.textPrimary),
            ),
            subtitle: Text(
              label,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
            trailing: const Icon(
              Icons.chevron_right_rounded,
              color: AppColors.textSecondary,
            ),
            onTap: () => _pickEnum(schema),
          ),
        );
      case ProviderSettingType.multiEnum:
        final raw = _values[schema.key];
        final selected = raw is List
            ? raw.whereType<String>().toSet()
            : <String>{};
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                schema.label,
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final opt in schema.options)
                    ChoiceChip(
                      label: Text(opt.label),
                      selected: selected.contains(opt.value),
                      selectedColor: AppColors.primary.withValues(alpha: 0.25),
                      backgroundColor: AppColors.cardElevated,
                      side: BorderSide(
                        color: selected.contains(opt.value)
                            ? AppColors.primary
                            : AppColors.divider,
                      ),
                      labelStyle: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 13,
                      ),
                      onSelected: (next) {
                        final updated = selected.toSet();
                        if (next) {
                          updated.add(opt.value);
                        } else {
                          updated.remove(opt.value);
                        }
                        _updateImmediate(schema.key, updated.toList());
                      },
                    ),
                ],
              ),
            ],
          ),
        );
      case ProviderSettingType.text:
        final v = _values[schema.key] as String? ?? '';
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(10),
          ),
          child: TextFormField(
            initialValue: v,
            style: const TextStyle(color: AppColors.textPrimary),
            decoration: InputDecoration(
              labelText: schema.label,
              labelStyle: const TextStyle(color: AppColors.textSecondary),
              border: InputBorder.none,
              isDense: true,
            ),
            onChanged: (next) => _updateDebounced(schema.key, next),
          ),
        );
    }
  }
}
