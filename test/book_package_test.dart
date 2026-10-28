import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:audiosubs_reader/book.dart';
import 'package:audiosubs_reader/library.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> manifest() => {
  'schemaVersion': 1,
  'id': 'test-book',
  'title': 'A real book',
  'author': 'Author',
  'blocks': [
    {
      'id': 'p1',
      'chapter': 'One',
      'kind': 'p',
      'runs': [
        {'text': 'Hello ', 'italic': true},
        {'text': 'world.', 'bold': true},
      ],
    },
  ],
  'tracks': [
    {'path': 'audio/000.wav', 'title': 'One', 'durationMs': 4000},
  ],
  'cues': [
    {
      'track': 0,
      'startMs': 100,
      'endMs': 600,
      'blockId': 'p1',
      'start': 0,
      'end': 5,
    },
    {
      'track': 0,
      'startMs': 1000,
      'endMs': 1500,
      'blockId': 'p1',
      'start': 6,
      'end': 11,
    },
  ],
  'alignment': {
    'recognizedWords': 2,
    'matchedWords': 2,
    'coverage': 1.0,
    'warnings': [],
  },
};

Future<File> package(
  Directory directory,
  Map<String, dynamic> book, {
  bool withAudio = true,
  String? extraPath,
}) async {
  final archive = Archive()
    ..add(ArchiveFile.string('book.json', jsonEncode(book)));
  if (withAudio) archive.add(ArchiveFile.bytes('audio/000.wav', [1, 2, 3]));
  if (extraPath != null) {
    archive.add(ArchiveFile.string(extraPath, 'untrusted'));
  }
  final file = File('${directory.path}/input.abook');
  await file.writeAsBytes(ZipEncoder().encode(archive));
  return file;
}

void main() {
  test(
    'highlight intervals exclude silence, their end boundary, and other tracks',
    () {
      final book = ReaderBook.fromJson(manifest(), '.');
      expect(book.cueAt(0, 99), isNull);
      expect(book.cueAt(0, 100)?.start, 0);
      expect(book.cueAt(0, 599)?.start, 0);
      expect(book.cueAt(0, 600), isNull);
      expect(book.cueAt(0, 999), isNull);
      expect(book.cueAt(0, 1000)?.start, 6);
      expect(book.cueAt(0, 1500), isNull);
      expect(book.cueAt(1, 1100), isNull);
    },
  );

  test('out-of-range alignment cannot be loaded into a reader', () {
    final json = manifest();
    (json['cues'] as List).first['end'] = 100;
    expect(() => ReaderBook.fromJson(json, '.'), throwsFormatException);
  });

  test(
    'reimport preserves local playback progress and ebook formatting',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'reader-package-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final root = await Directory('${temporary.path}/books').create();
      final library = BookLibrary(root);
      final source = await package(temporary, manifest());
      final first = await library.importPackage(source.path);
      await library.saveProgress(
        first,
        const ReadingProgress(positionMs: 1250, speed: 1.5),
      );
      final second = await library.importPackage(source.path);
      expect(second.blocks.single.text, 'Hello world.');
      expect(second.blocks.single.runs.first.italic, isTrue);
      expect(second.blocks.single.runs.last.bold, isTrue);
      expect((await library.progress(second)).positionMs, 1250);
      expect((await library.progress(second)).speed, 1.5);
    },
  );

  test(
    'incomplete and path-escaping packages leave no imported library entry',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'reader-package-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final root = await Directory('${temporary.path}/books').create();
      final library = BookLibrary(root);
      final missing = await package(temporary, manifest(), withAudio: false);
      await expectLater(
        library.importPackage(missing.path),
        throwsFormatException,
      );
      expect(await root.list().toList(), isEmpty);
      final unsafe = await package(
        temporary,
        manifest(),
        extraPath: '../escaped.txt',
      );
      await expectLater(
        library.importPackage(unsafe.path),
        throwsFormatException,
      );
      expect(await File('${temporary.path}/escaped.txt').exists(), isFalse);
      expect(await root.list().toList(), isEmpty);
    },
  );
}
