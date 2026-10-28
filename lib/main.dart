import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'appearance.dart';
import 'appearance_panel.dart';
import 'book.dart';
import 'library.dart';
import 'preparation.dart';
import 'reader.dart';
import 'windows_terms.dart';

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final library = await BookLibrary.open();
    final appearance = await AppearanceController.load(
      File('${library.root.parent.path}/appearance.json'),
    );
    registerReaderFontLicenses();
    if (Platform.isWindows && !await requestWindowsTermsAcceptance()) return;
    runApp(
      ReaderApp(
        library: library,
        appearance: appearance,
        initialPackage: arguments.isEmpty ? null : arguments.first,
      ),
    );
  } catch (error) {
    runApp(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SelectableText('Cannot start AudioSubs Reader: $error'),
          ),
        ),
      ),
    );
  }
}

class ReaderApp extends StatelessWidget {
  final BookLibrary library;
  final AppearanceController appearance;
  final String? initialPackage;
  const ReaderApp({
    super.key,
    required this.library,
    required this.appearance,
    this.initialPackage,
  });

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: appearance,
    builder: (context, _) => MaterialApp(
      title: 'AudioSubs Reader',
      debugShowCheckedModeBanner: false,
      theme: appearance.value.theme(Brightness.light),
      darkTheme: appearance.value.theme(Brightness.dark),
      themeMode: appearance.value.themeMode,
      home: LibraryScreen(
        library: library,
        appearance: appearance,
        initialPackage: initialPackage,
      ),
    ),
  );
}

class LibraryScreen extends StatefulWidget {
  final BookLibrary library;
  final AppearanceController appearance;
  final String? initialPackage;
  const LibraryScreen({
    super.key,
    required this.library,
    required this.appearance,
    this.initialPackage,
  });
  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  List<ReaderBook> _books = [];
  bool _busy = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    if (widget.initialPackage != null) {
      await _import(() => widget.library.importPackage(widget.initialPackage!));
    } else {
      await _refresh();
    }
  }

  Future<void> _refresh() async {
    try {
      final books = await widget.library.books();
      if (mounted) {
        setState(() {
          _books = books;
          _error = widget.library.warnings.isEmpty
              ? null
              : widget.library.warnings.join('\n');
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _choosePackage() async {
    try {
      // Android document providers frequently label .abook as application/zip
      // or application/octet-stream. Validate the actual package, not its MIME.
      final result = await FilePicker.pickFile(
        type: Platform.isAndroid ? FileType.any : FileType.custom,
        allowedExtensions: Platform.isAndroid ? null : ['abook'],
      );
      if (result != null) {
        await _import(() => widget.library.importPickedPackage(result));
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _import(Future<ReaderBook> Function() operation) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    ReaderBook? imported;
    try {
      imported = await operation();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
    final error = _error;
    await _refresh();
    if (error != null && mounted) setState(() => _error = error);
    if (imported != null && mounted) await _read(imported);
  }

  Future<void> _read(ReaderBook book) async {
    try {
      final progress = await widget.library.progress(book);
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => ReaderScreen(
            book: book,
            progress: progress,
            appearance: widget.appearance,
            onProgress: (value) => widget.library.saveProgress(book, value),
          ),
        ),
      );
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _prepare() async {
    final output = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const PreparationScreen()),
    );
    if (output != null && mounted) {
      await _import(() => widget.library.importPackage(output));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('AudioSubs Reader'),
      actions: [
        IconButton(
          tooltip: 'Appearance',
          onPressed: () => showAppearancePanel(context, widget.appearance),
          icon: const Icon(Icons.text_fields),
        ),
        IconButton(
          tooltip: 'Open-source licences',
          onPressed: () => showLicensePage(
            context: context,
            applicationName: 'AudioSubs Reader',
            applicationVersion: '0.2.0',
          ),
          icon: const Icon(Icons.info_outline),
        ),
      ],
    ),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1050),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              'Listen to the story.\nStay on the page.',
              style: Theme.of(context).textTheme.displaySmall,
            ),
            const SizedBox(height: 12),
            Text(
              Platform.isWindows
                  ? 'Prepare an audiobook with its EPUB, or open a prepared book. The original book stays on the page while the narration guides your place.'
                  : 'Open a book prepared on Windows. Audio, ebook formatting and timing travel together — no speech model needed on this device.',
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(height: 24),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                FilledButton.icon(
                  onPressed: _busy ? null : _choosePackage,
                  icon: const Icon(Icons.file_open_outlined),
                  label: const Text('Open reading book'),
                ),
                if (Platform.isWindows)
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _prepare,
                    icon: const Icon(Icons.auto_awesome),
                    label: const Text('Prepare on this PC'),
                  ),
              ],
            ),
            if (_busy)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: LinearProgressIndicator(),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 20),
                child: SelectableText(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            const SizedBox(height: 32),
            Text(
              'Your books',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 16),
            if (!_busy && _books.isEmpty)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'Your library is empty. Open a portable .abook file to start reading and listening.',
                  ),
                ),
              ),
            for (final book in _books)
              Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 12,
                  ),
                  leading: const Icon(Icons.auto_stories_outlined, size: 36),
                  title: Text(book.title),
                  subtitle: Text(
                    [
                      if (book.author.isNotEmpty) book.author,
                      '${book.tracks.length} audio ${book.tracks.length == 1 ? 'file' : 'files'}',
                      '${book.alignment['matchedWords'] ?? book.cues.length} timed words',
                    ].join(' · '),
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _busy ? null : () => _read(book),
                ),
              ),
            const SizedBox(height: 20),
            const Text(
              'Reading position stays on this device. Importing a book again keeps its existing copy and progress. Original audio and ebooks are never modified.',
            ),
          ],
        ),
      ),
    ),
  );
}
