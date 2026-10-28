import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

String safeBookPath(String relative) {
  if (relative.isEmpty ||
      relative.contains('\\') ||
      relative.startsWith('/') ||
      RegExp(r'[\x00-\x1f:<>\"|?*]').hasMatch(relative) ||
      relative
          .split('/')
          .any(
            (part) =>
                part.isEmpty ||
                part.endsWith('.') ||
                part.endsWith(' ') ||
                RegExp(
                  r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\.|$)',
                  caseSensitive: false,
                ).hasMatch(part),
          )) {
    throw const FormatException('Package contains an unsafe path.');
  }
  return relative;
}

Map<String, dynamic> _object(dynamic value) {
  if (value is! Map<String, dynamic>) {
    throw const FormatException('Expected a book object.');
  }
  return value;
}

String _string(dynamic value) {
  if (value is! String) throw const FormatException('Expected book text.');
  return value;
}

int _integer(dynamic value) {
  if (value is! int || value < 0) {
    throw const FormatException('Invalid book timing or offset.');
  }
  return value;
}

List<dynamic> _list(dynamic value) {
  if (value is! List) throw const FormatException('Expected a book list.');
  return value;
}

class BookRun {
  final String text;
  final bool bold, italic, underline;
  const BookRun({
    required this.text,
    this.bold = false,
    this.italic = false,
    this.underline = false,
  });
  factory BookRun.fromJson(Map<String, dynamic> json) => BookRun(
    text: _string(json['text']),
    bold: json['bold'] == true,
    italic: json['italic'] == true,
    underline: json['underline'] == true,
  );
}

class BookBlock {
  final String id, chapter, kind;
  final List<BookRun> runs;
  final String? image;
  late final String text = runs.map((run) => run.text).join();
  BookBlock({
    required this.id,
    required this.chapter,
    required this.kind,
    required this.runs,
    this.image,
  });
  factory BookBlock.fromJson(Map<String, dynamic> json) {
    final kind = _string(json['kind']);
    if (!{'p', 'h1', 'h2', 'h3', 'blockquote', 'li', 'image'}.contains(kind)) {
      throw const FormatException('Unsupported ebook block.');
    }
    return BookBlock(
      id: _string(json['id']),
      chapter: _string(json['chapter']),
      kind: kind,
      runs: _list(json['runs'])
          .map((run) => BookRun.fromJson(_object(run)))
          .toList(),
      image: json['image'] == null
          ? null
          : safeBookPath(_string(json['image'])),
    );
  }
}

class AudioTrack {
  final String path, title;
  final int durationMs;
  const AudioTrack({
    required this.path,
    required this.title,
    required this.durationMs,
  });
  factory AudioTrack.fromJson(Map<String, dynamic> json) => AudioTrack(
    path: safeBookPath(_string(json['path'])),
    title: _string(json['title']),
    durationMs: _integer(json['durationMs']),
  );
}

class BookCue {
  final int track, startMs, endMs, start, end;
  final String blockId;
  const BookCue({
    required this.track,
    required this.startMs,
    required this.endMs,
    required this.blockId,
    required this.start,
    required this.end,
  });
  factory BookCue.fromJson(Map<String, dynamic> json) => BookCue(
    track: _integer(json['track']),
    startMs: _integer(json['startMs']),
    endMs: _integer(json['endMs']),
    blockId: _string(json['blockId']),
    start: _integer(json['start']),
    end: _integer(json['end']),
  );
}

class ReaderBook {
  final String id, title, author, directory;
  final List<BookBlock> blocks;
  final List<AudioTrack> tracks;
  final List<BookCue> cues;
  final Map<String, dynamic> alignment;
  ReaderBook({
    required this.id,
    required this.title,
    required this.author,
    required this.directory,
    required this.blocks,
    required this.tracks,
    required this.cues,
    required this.alignment,
  });

  factory ReaderBook.fromJson(Map<String, dynamic> json, String directory) {
    if (json['schemaVersion'] != 1) {
      throw const FormatException('Unsupported book package version.');
    }
    final id = _string(json['id']);
    if (!RegExp(r'^[a-zA-Z0-9_-]{1,100}$').hasMatch(id)) {
      throw const FormatException('Invalid book ID.');
    }
    safeBookPath(id);
    final blocks = _list(json['blocks'])
        .map((value) => BookBlock.fromJson(_object(value)))
        .toList();
    final tracks = _list(json['tracks'])
        .map((value) => AudioTrack.fromJson(_object(value)))
        .toList();
    final cues = _list(json['cues'])
        .map((value) => BookCue.fromJson(_object(value)))
        .toList();
    if (blocks.isEmpty || tracks.isEmpty) {
      throw const FormatException('Book has no text or audio.');
    }
    final byId = <String, BookBlock>{};
    for (final block in blocks) {
      if (block.id.isEmpty || byId.containsKey(block.id)) {
        throw const FormatException('Duplicate ebook block.');
      }
      byId[block.id] = block;
      if (block.kind == 'image' && block.image == null) {
        throw const FormatException('Missing ebook image.');
      }
    }
    BookCue? previous;
    for (final cue in cues) {
      final block = byId[cue.blockId];
      if (cue.track >= tracks.length ||
          cue.endMs <= cue.startMs ||
          block == null ||
          cue.end <= cue.start ||
          cue.end > block.text.length ||
          (tracks[cue.track].durationMs > 0 &&
              cue.endMs > tracks[cue.track].durationMs + 1000) ||
          (previous != null &&
              (cue.track < previous.track ||
                  (cue.track == previous.track &&
                      cue.startMs < previous.startMs)))) {
        throw const FormatException('Invalid or unordered book alignment.');
      }
      previous = cue;
    }
    return ReaderBook(
      id: id,
      title: _string(json['title']),
      author: _string(json['author']),
      directory: directory,
      blocks: blocks,
      tracks: tracks,
      cues: cues,
      alignment: _object(json['alignment']),
    );
  }

  static Future<ReaderBook> load(String directory) async {
    final file = File(p.join(directory, 'book.json'));
    if (await file.length() > 64 * 1024 * 1024) {
      throw const FormatException('Book manifest exceeds 64 MiB.');
    }
    return ReaderBook.fromJson(
      _object(jsonDecode(await file.readAsString())),
      directory,
    );
  }

  String resolve(String relative) =>
      p.joinAll([directory, ...safeBookPath(relative).split('/')]);

  BookCue? cueAt(int track, int positionMs) {
    var low = 0;
    var high = cues.length;
    while (low < high) {
      final middle = low + ((high - low) >> 1);
      final cue = cues[middle];
      if (cue.track < track ||
          (cue.track == track && cue.startMs <= positionMs)) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    if (low == 0) return null;
    final cue = cues[low - 1];
    return cue.track == track && positionMs < cue.endMs ? cue : null;
  }
}

class ReadingProgress {
  final int track, positionMs;
  final double speed;
  const ReadingProgress({this.track = 0, this.positionMs = 0, this.speed = 1});
  factory ReadingProgress.fromJson(Map<String, dynamic> json) {
    final speed = json['speed'];
    return ReadingProgress(
      track: _integer(json['track']),
      positionMs: _integer(json['positionMs']),
      speed: speed is num && speed.isFinite && speed >= 0.5 && speed <= 3
          ? speed.toDouble()
          : 1,
    );
  }
  Map<String, dynamic> toJson() => {
    'track': track,
    'positionMs': positionMs,
    'speed': speed,
  };
}
