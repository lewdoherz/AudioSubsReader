import 'package:audiosubs_reader/appearance.dart';
import 'package:audiosubs_reader/reader.dart';
import 'package:flutter/material.dart' show TextRange;
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Reader visual highlight ranges', () {
    test(
      'word ranges retain UTF-16 offsets after supplementary characters',
      () {
        const text = 'An 😀 introduction, then the word.';
        final start = text.indexOf('word');
        final range = readerHighlightRange(
          text,
          start,
          start + 4,
          HighlightRangeMode.word,
        );
        expect(range, TextRange(start: start, end: start + 4));
        expect(range.textInside(text), 'word');
      },
    );

    test(
      'phrase expansion stops at a comma while sentence expansion does not',
      () {
        const text = 'First phrase, the next phrase. Another sentence!';
        final start = text.indexOf('next');
        final phrase = readerHighlightRange(
          text,
          start,
          start + 4,
          HighlightRangeMode.phrase,
        );
        final sentence = readerHighlightRange(
          text,
          start,
          start + 4,
          HighlightRangeMode.sentence,
        );
        expect(phrase.textInside(text), 'the next phrase.');
        expect(sentence.textInside(text), 'First phrase, the next phrase.');
      },
    );

    test(
      'terminal punctuation inside a cue never captures the next sentence',
      () {
        const text = 'She said “Hello.” Next sentence.';
        final start = text.indexOf('Hello');
        final range = readerHighlightRange(
          text,
          start,
          start + 'Hello.'.length,
          HighlightRangeMode.sentence,
        );
        expect(range.textInside(text), 'She said “Hello.”');
      },
    );

    test('newlines and non-Latin punctuation bound sentence expansion', () {
      const text = 'Previous line\n  你好世界。接下来！';
      final start = text.indexOf('世界');
      final range = readerHighlightRange(
        text,
        start,
        start + 2,
        HighlightRangeMode.sentence,
      );
      expect(range.textInside(text), '你好世界。');
    });

    test('empty and out-of-bounds ranges cannot invent a highlight', () {
      expect(
        readerHighlightRange('', -10, 80, HighlightRangeMode.sentence),
        const TextRange(start: 0, end: 0),
      );
      expect(
        readerHighlightRange('text', 3, 1, HighlightRangeMode.phrase),
        const TextRange(start: 3, end: 3),
      );
      expect(
        readerHighlightRange('text', 80, 100, HighlightRangeMode.word),
        const TextRange(start: 4, end: 4),
      );
    });
  });
}
