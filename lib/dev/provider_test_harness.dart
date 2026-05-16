// Standalone dev harness to verify JS providers end-to-end.
// Run with: flutter run -t lib/dev/provider_test_harness.dart
//
// Loads each provider's JS from local assets (NOT GitHub) so you can edit and
// hot-restart. Exercises search() and getDetail() and dumps the JSON.

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/provider/provider_manager.dart';
import '../core/theme/app_theme.dart';

void main() {
  runApp(const _HarnessApp());
}

class _HarnessApp extends StatelessWidget {
  const _HarnessApp();
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Provider Test Harness',
      theme: AppTheme.dark,
      debugShowCheckedModeBanner: false,
      home: const _HarnessScreen(),
    );
  }
}

class _HarnessScreen extends StatefulWidget {
  const _HarnessScreen();
  @override
  State<_HarnessScreen> createState() => _HarnessScreenState();
}

class _HarnessScreenState extends State<_HarnessScreen> {
  final _dio = Dio(BaseOptions(
    headers: {
      'User-Agent':
          'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36',
      'Accept': 'text/html,application/json,*/*;q=0.8',
      'Accept-Language': 'en-US,en;q=0.9',
    },
    connectTimeout: const Duration(seconds: 20),
    receiveTimeout: const Duration(seconds: 30),
  ));

  late final ProviderManager _manager = ProviderManager(dio: _dio);

  final _queryCtrl = TextEditingController(text: 'one piece');
  String _provider = 'mangadex';
  String _output = '(idle)';
  bool _busy = false;

  void _log(String s) {
    setState(() => _output += '\n$s');
  }

  Future<void> _loadProvider(String name) async {
    final js = await rootBundle.loadString('providers/$name.js');
    await _manager.load(sourceId: name, jsSource: js);
    _manager.get(name)?.onConsole = (level, msg) => _log('  [$level] $msg');
  }

  Future<void> _runSearch() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _output = 'Loading $_provider...';
    });
    try {
      final t0 = DateTime.now();
      await _loadProvider(_provider);
      _log('Loaded $_provider in ${DateTime.now().difference(t0).inMilliseconds}ms');

      final p = _manager.get(_provider)!;
      final info = await p.getInfo();
      _log('getInfo: ${info.name} (${info.type})');

      final t1 = DateTime.now();
      final results = await p.search(_queryCtrl.text, 1).timeout(const Duration(seconds: 30));
      _log('search("${_queryCtrl.text}") -> ${results.length} results in ${DateTime.now().difference(t1).inMilliseconds}ms');
      for (var i = 0; i < results.length && i < 5; i++) {
        final b = results[i];
        _log('  [${i + 1}] ${b.title}  |  ${b.url}');
      }

      if (results.isNotEmpty) {
        final t2 = DateTime.now();
        final detail = await p.getDetail(results.first.url).timeout(const Duration(seconds: 45));
        _log('getDetail -> "${detail.title}" status=${detail.status.name} chapters=${detail.chapters.length} in ${DateTime.now().difference(t2).inMilliseconds}ms');
        if (detail.chapters.isNotEmpty) {
          final ch = detail.chapters.first;
          _log('  first chapter: ${ch.title}  |  ${ch.url}');
          final t3 = DateTime.now();
          final pages = await p.getPages(ch.url).timeout(const Duration(seconds: 30));
          _log('getPages -> ${pages.length} pages in ${DateTime.now().difference(t3).inMilliseconds}ms');
          if (pages.isNotEmpty) _log('  page 1: ${pages.first.url}');
        }
      }
      _log('\n✅ DONE');
    } catch (e, st) {
      _log('❌ ERROR: $e');
      _log(st.toString().split('\n').take(6).join('\n'));
    } finally {
      setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _manager.disposeAll();
    _queryCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Provider Test Harness')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _provider,
                    decoration: const InputDecoration(labelText: 'Provider'),
                    items: const [
                      DropdownMenuItem(value: 'mangadex', child: Text('MangaDex')),
                      DropdownMenuItem(value: 'mangakakalot', child: Text('Mangakakalot')),
                    ],
                    onChanged: (v) => setState(() => _provider = v ?? 'mangadex'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _queryCtrl,
                    decoration: const InputDecoration(labelText: 'Query'),
                  ),
                ),
              ]),
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: _busy ? null : _runSearch,
                child: Text(_busy ? 'Running...' : 'Run search + detail + pages'),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1C1C1C),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      _output,
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.4),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
