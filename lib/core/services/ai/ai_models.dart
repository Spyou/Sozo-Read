/// Catalog of Gemini model IDs the AI features can use. The string
/// value is what gets sent to the Gemini REST endpoint (the literal
/// model name in `/v1beta/models/<id>:generateContent`).
enum AiModel {
  gemini35Flash('gemini-3.5-flash', 'Gemini 3.5 Flash', 'Free tier'),
  gemini25Flash('gemini-2.5-flash', 'Gemini 2.5 Flash', 'Free tier'),
  gemini25Pro('gemini-2.5-pro', 'Gemini 2.5 Pro', 'Paid · higher quality');

  const AiModel(this.apiId, this.displayName, this.tierLabel);

  /// Literal string passed to Gemini's REST endpoint.
  final String apiId;

  /// Human-readable label for the settings dropdown.
  final String displayName;

  /// Short pricing hint shown next to the model name.
  final String tierLabel;

  /// Best-effort lookup for a persisted apiId. Defaults to 3.5 Flash
  /// (the documented default in the settings screen) if the stored
  /// value doesn't match any known model — handles users who pick a
  /// model in v1 and we later remove it.
  static AiModel fromApiId(String? id) {
    if (id == null || id.isEmpty) return AiModel.gemini35Flash;
    for (final m in AiModel.values) {
      if (m.apiId == id) return m;
    }
    return AiModel.gemini35Flash;
  }
}
