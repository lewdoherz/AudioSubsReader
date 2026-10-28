import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:file_picker/file_picker.dart' show PlatformFile;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'book.dart';

class BookLibrary {
  final Directory root;
  final List<String> warnings = [];
  Future<void> _saving = Future.value();
  BookLibrary(this.root);

  static Future<BookLibrary> open() async {
    final support = await getApplicationSupportDirectory();
    final root = Directory(p.join(support.path, 'books'));
    await root.create(recursive: true);
    return BookLibrary(root);
  }

  Future<List<ReaderBook>> books() async {
    final result = <ReaderBook>[];
    warnings.clear();
    await for (final entry in root.list()) {
      if (entry is! Directory || p.basename(entry.path).startsWith('.')) {
        continue;
      }
      try {
        result.add(await Isolate.run(() => ReaderBook.load(entry.path)));
      } catch (error) {
        warnings.add('${p.basename(entry.path)}: $error');
      }
    }
    result.sort(
      (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
    );
    return result;
  }

  Future<ReaderBook> importPackage(String path) async {
    final rootPath = root.path;
    return Isolate.run(() => _importPackage(path, rootPath));
  }

  Future<ReaderBook> importPickedPackage(PlatformFile selected) async {
    final path = selected.path;
    if (path != null) return importPackage(path);
    // SAF content URIs are not filesystem paths. Stream the provider content;
    // do not hold an audiobook-sized ZIP in memory or retain a transient URI.
    final cache = await getTemporaryDirectory();
    final staging = await cache.createTemp('reading-book-');
    try {
      final file = File(p.join(staging.path, 'import.abook'));
      await selected.readAsByteStream().cast<List<int>>().pipe(
        file.openWrite(),
      );
      return await importPackage(file.path);
    } finally {
      await staging.delete(recursive: true);
    }
  }

  Future<ReadingProgress> progress(ReaderBook book) async {
    final file = File(p.join(book.directory, 'progress.json'));
    if (!await file.exists()) return const ReadingProgress();
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final value = ReadingProgress.fromJson(json);
    if (value.track >= book.tracks.length) {
      throw const FormatException('Saved audio track is missing.');
    }
    return value;
  }

  Future<void> saveProgress(ReaderBook book, ReadingProgress progress) {
    final operation = _saving.then((_) async {
      final file = File(p.join(book.directory, 'progress.json'));
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(jsonEncode(progress.toJson()), flush: true);
      await temporary.rename(file.path);
    });
    _saving = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }
}

Future<ReaderBook> _importPackage(String source, String root) async {
  final staging = await Directory(root).createTemp('.import-');
  InputFileStream? input;
  try {
    input = InputFileStream(source);
    final decoder = ZipDecoder();
    final archive = decoder.decodeStream(input);
    if (archive.length != decoder.directory.fileHeaders.length) {
      throw const FormatException('Package contains duplicate paths.');
    }
    if (archive.length > 100000) {
      throw const FormatException('Too many package entries.');
    }
    final names = <String>{};
    var total = 0;
    for (final entry in archive) {
      final name = entry.isDirectory && entry.name.endsWith('/')
          ? entry.name.substring(0, entry.name.length - 1)
          : entry.name;
      safeBookPath(name);
      if (entry.isSymbolicLink || !names.add(name.toLowerCase())) {
        throw const FormatException(
          'Package contains links or duplicate paths.',
        );
      }
      total += entry.size;
      if (entry.size < 0 || total > 64 * 1024 * 1024 * 1024) {
        throw const FormatException('Expanded package exceeds 64 GiB.');
      }
      if (entry.name == 'book.json' && entry.size > 64 * 1024 * 1024) {
        throw const FormatException('Book manifest exceeds 64 MiB.');
      }
      // Never accept a package's playback state: it belongs to this device.
      if (name.toLowerCase() == 'progress.json' ||
          name.toLowerCase() == 'progress.json.tmp') {
        throw const FormatException(
          'Package must not contain device playback state.',
        );
      }
    }
    for (final entry in archive) {
      if (!entry.isFile) continue;
      final target = File(p.joinAll([staging.path, ...entry.name.split('/')]));
      await target.parent.create(recursive: true);
      final output = OutputFileStream(target.path);
      try {
        entry.writeContent(output);
      } finally {
        output.closeSync();
      }
      if (await target.length() != entry.size) {
        throw const FormatException('Truncated package entry.');
      }
    }
    final book = await ReaderBook.load(staging.path);
    for (final relative in [
      ...book.tracks.map((track) => track.path),
      ...book.blocks
          .where((block) => block.image != null)
          .map((block) => block.image!),
    ]) {
      if (!await File(book.resolve(relative)).exists()) {
        throw FormatException('Package is missing $relative.');
      }
    }
    final destination = Directory(p.join(root, book.id));
    if (await destination.exists()) {
      return await ReaderBook.load(destination.path);
    }
    await staging.rename(destination.path);
    return await ReaderBook.load(destination.path);
  } finally {
    input?.closeSync();
    if (await staging.exists()) await staging.delete(recursive: true);
  }
}
