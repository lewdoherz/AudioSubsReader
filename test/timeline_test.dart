import 'package:audiosubs_reader/timeline.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BookTimeline', () {
    test('uses source time rather than speed or listening history', () {
      final timeline = BookTimeline([60000, 90000, 30000]);
      expect(timeline.totalMs, 180000);
      expect(timeline.positionMs(1, 15000), 75000);
      expect(timeline.remainingMs(1, 15000), 105000);
      expect(timeline.positionMs(2, 0), 150000);
      // Rewinding changes the recording position, not a cumulative counter.
      expect(timeline.positionMs(0, 1000), 1000);
    });

    test(
      'joins map forward and the final endpoint stays on the last track',
      () {
        final timeline = BookTimeline([1000, 2000, 3000]);
        final cases = <int, List<int>>{
          -50: [0, 0],
          0: [0, 0],
          999: [0, 999],
          1000: [1, 0],
          2999: [1, 1999],
          3000: [2, 0],
          6000: [2, 3000],
          9000: [2, 3000],
        };
        for (final entry in cases.entries) {
          final target = timeline.seek(entry.key)!;
          expect([target.track, target.positionMs], entry.value);
        }
      },
    );

    test('clamps file positions and rejects invalid track indices', () {
      final timeline = BookTimeline([1000, 2000]);
      expect(timeline.positionMs(1, -500), 1000);
      expect(timeline.positionMs(1, 9000), 3000);
      expect(timeline.remainingMs(1, 9000), 0);
      expect(timeline.positionMs(-1, 10), isNull);
      expect(timeline.positionMs(2, 10), isNull);
    });

    test('unknown durations never fabricate totals or seek destinations', () {
      for (final unknown in [0, -1]) {
        final timeline = BookTimeline([1000, unknown, 3000]);
        expect(timeline.totalMs, isNull);
        expect(timeline.remainingMs(0, 100), isNull);
        expect(timeline.seek(500), isNull);
        expect(timeline.positionMs(0, 100), 100);
        expect(timeline.positionMs(1, 500), 1500);
        expect(timeline.positionMs(2, 0), isNull);
      }
      final empty = BookTimeline([]);
      expect(empty.totalMs, isNull);
      expect(empty.seek(0), isNull);
      expect(empty.positionMs(0, 0), isNull);
    });

    test(
      'native duration replacement changes offsets without mutating input',
      () {
        final durations = [1000, 0, 3000];
        final before = BookTimeline(durations);
        durations[1] = 2500;
        final after = BookTimeline(durations);
        expect(before.totalMs, isNull);
        expect(after.totalMs, 6500);
        expect(after.positionMs(2, 100), 3600);
        expect(after.seek(3500)!.track, 2);
        expect(after.seek(3500)!.positionMs, 0);
      },
    );

    test('file to book to file coordinates round trip without moving audio', () {
      final timeline = BookTimeline([1350, 2750, 1200]);
      for (var track = 0; track < timeline.durationsMs.length; track++) {
        final local = timeline.durationsMs[track] ~/ 2;
        final bookPosition = timeline.positionMs(track, local)!;
        final filePosition = timeline.seek(bookPosition)!;
        expect(filePosition.track, track);
        expect(filePosition.positionMs, local);
      }
      // Book skips cross files; the reader can retain a file-local coordinate.
      final forward = timeline.seek(timeline.positionMs(0, 1300)! + 100)!;
      expect([forward.track, forward.positionMs], [1, 50]);
      final backward = timeline.seek(timeline.positionMs(1, 50)! - 100)!;
      expect([backward.track, backward.positionMs], [0, 1300]);
    });
  });
}
