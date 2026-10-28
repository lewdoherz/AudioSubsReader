import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class PreparationScreen extends StatefulWidget {
  const PreparationScreen({super.key});
  @override
  State<PreparationScreen> createState() => _PreparationScreenState();
}

class _PreparationScreenState extends State<PreparationScreen> {
  final _model = TextEditingController();
  final _language = TextEditingController(text: 'auto');
  final _logs = <String>[];
  final _audio = <String>[];
  String? _ebook;
  String? _modelRoot;
  String _modelName = 'tiny';
  String _device = 'cpu';
  String _compute = 'int8';
  bool _busy = false;
  bool _cancelled = false;
  String? _error;
  double? _progress;
  Process? _process;
  String? _completed;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      final support = await getApplicationSupportDirectory();
      if (!mounted) return;
      _modelRoot = p.join(support.path, 'models');
      setState(() => _model.text = p.join(_modelRoot!, _modelName));
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<(String, List<String>)> _invocation() async {
    final executable = File(Platform.resolvedExecutable).parent;
    final packaged = File(
      p.join(executable.path, 'preparation_runtime', 'prepare.exe'),
    );
    if (await packaged.exists()) return (packaged.path, <String>[]);
    final visited = <String>{};
    for (final start in [Directory.current, executable]) {
      var root = start;
      for (var depth = 0; depth < 10; depth++) {
        if (visited.add(root.path)) {
          final bundled = File(
            p.join(root.path, 'worker', 'runtime', 'prepare', 'prepare.exe'),
          );
          if (await bundled.exists()) return (bundled.path, <String>[]);
          final python = File(
            p.join(root.path, 'worker', '.venv', 'Scripts', 'python.exe'),
          );
          final script = File(p.join(root.path, 'worker', 'prepare.py'));
          if (await python.exists() && await script.exists()) {
            return (python.path, ['-u', script.path]);
          }
        }
        final parent = root.parent;
        if (parent.path == root.path) break;
        root = parent;
      }
    }
    throw StateError(
      'Preparation runtime is not installed. Run scripts/setup_worker.ps1 from the project folder.',
    );
  }

  Future<void> _pickEbook() async {
    try {
      final result = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['epub'],
      );
      if (result != null && mounted) {
        setState(() => _ebook = result.path);
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _pickAudio() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['mp3', 'm4b', 'm4a', 'wav', 'flac', 'ogg', 'aac'],
      );
      if (result.isEmpty || !mounted) return;
      final additions =
          result
              .map((file) => file.path)
              .whereType<String>()
              .where((path) => !_audio.contains(path))
              .toList()
            ..sort((a, b) => _naturalCompare(p.basename(a), p.basename(b)));
      setState(() => _audio.addAll(additions));
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _start({required bool download}) async {
    if (_busy) return;
    String? output;
    if (!download) {
      if (_ebook == null || _audio.isEmpty || _model.text.trim().isEmpty) {
        setState(
          () => _error =
              'Choose an EPUB, audio files, and a local model directory.',
        );
        return;
      }
      try {
        final folder = await FilePicker.getDirectoryPath(
          dialogTitle: 'Choose folder for the portable reading book',
        );
        if (folder == null || !mounted) return;
        final stem = p.basenameWithoutExtension(_ebook!);
        output = p.join(folder, '$stem.abook');
        var number = 2;
        while (await File(output!).exists()) {
          output = p.join(folder, '$stem-${number++}.abook');
        }
      } catch (error) {
        if (mounted) setState(() => _error = error.toString());
        return;
      }
    }
    if (!mounted) return;
    setState(() {
      _busy = true;
      _cancelled = false;
      _error = null;
      _completed = null;
      _progress = null;
      _logs.clear();
    });
    File? request;
    StreamSubscription<String>? diagnostics;
    var stderr = '';
    var done = false;
    try {
      final invocation = await _invocation();
      final arguments = [...invocation.$2];
      if (download) {
        if (_modelRoot == null) {
          throw StateError('Model storage is not available.');
        }
        arguments.addAll([
          '--download-model',
          _modelName,
          '--model-directory',
          _modelRoot!,
        ]);
      } else {
        final temp = await getTemporaryDirectory();
        request = File(
          p.join(
            temp.path,
            'prepare-${DateTime.now().microsecondsSinceEpoch}.json',
          ),
        );
        await request.writeAsString(
          jsonEncode({
            'ebook': _ebook,
            'audio': _audio,
            'output': output,
            'model': _model.text.trim(),
            'language': _language.text.trim(),
            'device': _device,
            'computeType': _compute,
          }),
          flush: true,
        );
        arguments.addAll(['--request', request.path]);
      }
      final process = await Process.start(
        invocation.$1,
        arguments,
        environment: {'PYTHONUTF8': '1', 'PYTHONUNBUFFERED': '1'},
      );
      _process = process;
      if (_cancelled) process.kill();
      diagnostics = process.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen((text) {
            stderr += text;
            if (stderr.length > 8000) {
              stderr = stderr.substring(stderr.length - 8000);
            }
          });
      await for (final line
          in process.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        if (!mounted || line.trim().isEmpty) continue;
        final event = jsonDecode(line) as Map<String, dynamic>;
        setState(() {
          if (event['type'] == 'error') _error = event['message'].toString();
          if (event['type'] == 'done') {
            done = true;
            _completed = download ? null : output;
            if (!download) {
              _logs.add(
                '${event['matchedWords']} of ${event['recognizedWords']} recognized words anchored to the ebook.',
              );
            }
          }
          final message = event['message'];
          if (message != null) {
            _logs.add(message.toString());
            if (_logs.length > 80) _logs.removeAt(0);
          }
          final progress = event['progress'];
          _progress = progress is num ? progress.toDouble().clamp(0, 1) : null;
        });
      }
      final code = await process.exitCode;
      if (_cancelled) {
        if (mounted) {
          setState(
            () => _error =
                'Operation cancelled. No unfinished book was imported.',
          );
        }
      } else if (code != 0 || !done) {
        throw StateError(_error ?? 'Worker exited ($code). $stderr');
      } else if (download && mounted) {
        setState(() {
          _model.text = p.join(_modelRoot!, _modelName);
          _logs.add('Model ready. You can now prepare books offline.');
        });
      }
    } catch (error) {
      _process?.kill();
      if (mounted) setState(() => _error = error.toString());
    } finally {
      await diagnostics?.cancel();
      if (request != null && await request.exists()) await request.delete();
      _process = null;
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _process?.kill();
    _model.dispose();
    _language.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: Scaffold(
      appBar: AppBar(title: const Text('Prepare a reading book')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text(
                'Audio timing. Ebook wording.',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 8),
              const Text(
                'Choose the same edition as the narration. Preparation transcribes locally, then anchors spoken words to the original EPUB. Unmatched passages remain readable without invented highlights.',
              ),
              const SizedBox(height: 24),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _pickEbook,
                    icon: const Icon(Icons.menu_book),
                    label: const Text('Choose EPUB'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _pickAudio,
                    icon: const Icon(Icons.library_music),
                    label: const Text('Add audio files'),
                  ),
                ],
              ),
              if (_ebook != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(_ebook!),
                ),
              if (_audio.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text('Audio order — adjust before preparing'),
                for (var index = 0; index < _audio.length; index++)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Text('${index + 1}'),
                    title: Text(p.basename(_audio[index])),
                    subtitle: Text(
                      _audio[index],
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: 'Move earlier',
                          onPressed: _busy || index == 0
                              ? null
                              : () => setState(() {
                                  final value = _audio.removeAt(index);
                                  _audio.insert(index - 1, value);
                                }),
                          icon: const Icon(Icons.arrow_upward),
                        ),
                        IconButton(
                          tooltip: 'Remove audio',
                          onPressed: _busy
                              ? null
                              : () => setState(() => _audio.removeAt(index)),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                  ),
              ],
              const Divider(height: 40),
              const Text(
                'Speech model — downloaded explicitly; inference stays local',
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 16,
                runSpacing: 12,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  DropdownButton<String>(
                    value: _modelName,
                    onChanged: _busy
                        ? null
                        : (value) => setState(() {
                            _modelName = value!;
                            if (_modelRoot != null) {
                              _model.text = p.join(_modelRoot!, value);
                            }
                          }),
                    items: ['tiny', 'base', 'small', 'medium', 'large-v3']
                        .map(
                          (value) => DropdownMenuItem(
                            value: value,
                            child: Text(value),
                          ),
                        )
                        .toList(),
                  ),
                  OutlinedButton.icon(
                    onPressed: _busy || _modelRoot == null
                        ? null
                        : () => _start(download: true),
                    icon: const Icon(Icons.download),
                    label: const Text('Download selected model'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _model,
                enabled: !_busy,
                decoration: const InputDecoration(
                  labelText: 'Local CTranslate2 model directory',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _language,
                enabled: !_busy,
                decoration: const InputDecoration(
                  labelText: 'Spoken language (auto, en, de, es, …)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 24,
                runSpacing: 12,
                children: [
                  DropdownButton<String>(
                    value: _device,
                    onChanged: _busy
                        ? null
                        : (value) => setState(() => _device = value!),
                    items: ['cpu', 'cuda']
                        .map(
                          (value) => DropdownMenuItem(
                            value: value,
                            child: Text('Device: $value'),
                          ),
                        )
                        .toList(),
                  ),
                  DropdownButton<String>(
                    value: _compute,
                    onChanged: _busy
                        ? null
                        : (value) => setState(() => _compute = value!),
                    items: ['int8', 'float16', 'float32']
                        .map(
                          (value) => DropdownMenuItem(
                            value: value,
                            child: Text('Precision: $value'),
                          ),
                        )
                        .toList(),
                  ),
                ],
              ),
              const Text(
                'CPU + int8 is the safe starting point. CUDA needs a compatible NVIDIA installation. Models are not included.',
              ),
              const SizedBox(height: 24),
              if (_busy) ...[
                LinearProgressIndicator(value: _progress),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: _cancelled
                      ? null
                      : () {
                          setState(() => _cancelled = true);
                          _process?.kill();
                        },
                  child: const Text('Cancel operation'),
                ),
              ] else if (_completed != null) ...[
                const Text(
                  'Portable book created. Copy this .abook to Android for playback.',
                ),
                SelectableText(_completed!),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: () => Navigator.pop(context, _completed),
                  icon: const Icon(Icons.auto_stories),
                  label: const Text('Import and read'),
                ),
              ] else
                FilledButton.icon(
                  onPressed: () => _start(download: false),
                  icon: const Icon(Icons.auto_awesome),
                  label: const Text('Create reading book'),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: SelectableText(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              if (_logs.isNotEmpty) ...[
                const SizedBox(height: 20),
                SelectableText(
                  _logs.join('\n'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              const SizedBox(height: 24),
              const Text(
                'DRM-free EPUB only. Semantic headings, paragraphs, emphasis, lists and images are retained; publisher CSS, fixed-layout books and DRM removal are not supported. No translation or secondary subtitles.',
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

int _naturalCompare(String a, String b) {
  final pattern = RegExp(r'\d+|\D+');
  final left = pattern
      .allMatches(a.toLowerCase())
      .map((match) => match.group(0)!)
      .toList();
  final right = pattern
      .allMatches(b.toLowerCase())
      .map((match) => match.group(0)!)
      .toList();
  for (var i = 0; i < left.length && i < right.length; i++) {
    final x = int.tryParse(left[i]);
    final y = int.tryParse(right[i]);
    final result = x != null && y != null
        ? x.compareTo(y)
        : left[i].compareTo(right[i]);
    if (result != 0) return result;
  }
  return left.length.compareTo(right.length);
}
