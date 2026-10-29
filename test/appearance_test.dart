import 'dart:convert';
import 'dart:io';

import 'package:audiosubs_reader/appearance.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

double contrast(Color first, Color second) {
  final a = first.computeLuminance();
  final b = second.computeLuminance();
  return a > b ? (a + 0.05) / (b + 0.05) : (b + 0.05) / (a + 0.05);
}

void main() {
  group('Reader preferences', () {
    test(
      'unknown values fall back and unsafe stored numbers are normalized',
      () {
        final settings = ReaderPreferences.fromJson({
          'schemaVersion': 1,
          'themeMode': 'future',
          'font': 5,
          'fontSize': 1000,
          'highlightStyle': null,
          'highlightArgb': 0x00123456,
          'highlightRange': 'paragraph',
          'timelineMode': 'elapsed',
          'readingWidth': 'future-width',
        });
        expect(settings.fontSize, 40);
        expect(settings.highlightArgb, 0xff123456);
        expect(settings.themeMode, ThemeMode.system);
        expect(settings.font, ReaderFont.system);
        expect(settings.highlightStyle, HighlightStyle.background);
        expect(settings.highlightRange, HighlightRangeMode.word);
        expect(settings.timelineMode, TimelineMode.book);
        expect(settings.readingWidth, ReadingWidth.standard);
        for (final value in [null, '19', double.nan, double.infinity]) {
          expect(
            ReaderPreferences.fromJson({'schemaVersion': 1, 'fontSize': value})
                .fontSize,
            19,
          );
        }
        expect(settings.copyWith(fontSize: -20).fontSize, 14);
        expect(settings.copyWith(fontSize: double.nan).fontSize, 19);
        for (final value in [-1, 0x100000000, 'red', 3.5]) {
          expect(
            ReaderPreferences.fromJson({
              'schemaVersion': 1,
              'highlightArgb': value,
            }).highlightArgb,
            0xff80cbc4,
          );
        }
        expect(
          ReaderPreferences.fromJson({'schemaVersion': 999, 'fontSize': 40})
              .toJson(),
          const ReaderPreferences().toJson(),
        );
        expect(
          const ReaderPreferences(
            fontSize: double.infinity,
            highlightArgb: 0,
          ).toJson()['fontSize'],
          19,
        );
        expect(
          const ReaderPreferences(highlightArgb: 0).toJson()['highlightArgb'],
          0xff000000,
        );
      },
    );

    test('highlighting preserves ebook emphasis and readable colors', () {
      const emphasized = TextStyle(
        fontWeight: FontWeight.bold,
        fontStyle: FontStyle.italic,
        decoration: TextDecoration.underline,
        letterSpacing: 1.2,
        fontSize: 23,
      );
      for (final brightness in Brightness.values) {
        final colors = const ReaderPreferences().theme(brightness).colorScheme;
        for (final style in HighlightStyle.values) {
          for (final argb in [0xff000000, 0xffffffff, 0xff80cbc4, 0xff777777]) {
            final preferences = ReaderPreferences(
              highlightStyle: style,
              highlightArgb: argb,
            );
            final result = preferences.applyHighlight(emphasized, colors);
            expect(result.fontWeight, FontWeight.bold);
            expect(result.fontStyle, FontStyle.italic);
            expect(
              result.decoration!.contains(TextDecoration.underline),
              isTrue,
            );
            expect(result.letterSpacing, 1.2);
            expect(result.fontSize, 23);
            if (style != HighlightStyle.none) {
              final background = style == HighlightStyle.background
                  ? result.backgroundColor!
                  : colors.surface;
              expect(
                contrast(result.color!, background),
                greaterThanOrEqualTo(4.5),
              );
            }
            if (style == HighlightStyle.underline) {
              expect(
                contrast(result.decorationColor!, colors.surface),
                greaterThanOrEqualTo(4.5),
              );
            }
          }
          final plain = ReaderPreferences(highlightStyle: style)
              .applyHighlight(const TextStyle(), colors);
          expect(plain.fontWeight, isNull);
          expect(plain.fontStyle, isNull);
        }
      }
    });

    test('bold highlighting preserves ebook ink and formatting without adding color', () {
      const preferences = ReaderPreferences(
        highlightStyle: HighlightStyle.none,
        boldHighlight: true,
        highlightArgb: 0xffff0000,
      );
      const base = TextStyle(
        color: Colors.blue,
        fontWeight: FontWeight.normal,
        fontStyle: FontStyle.italic,
        decoration: TextDecoration.lineThrough,
        fontSize: 23,
      );
      final result = preferences.applyHighlight(
        base,
        const ReaderPreferences().theme(Brightness.light).colorScheme,
      );
      expect(result.fontWeight, FontWeight.bold);
      expect(result.fontStyle, FontStyle.italic);
      expect(result.decoration, TextDecoration.lineThrough);
      expect(result.color, Colors.blue);
      expect(result.backgroundColor, isNull);
      final painted = base.copyWith(
        color: null,
        foreground: Paint()..color = Colors.green,
        fontWeight: FontWeight.w900,
      );
      final paintedResult = preferences.applyHighlight(
        painted,
        const ReaderPreferences().theme(Brightness.dark).colorScheme,
      );
      expect(paintedResult.foreground, same(painted.foreground));
      expect(paintedResult.fontWeight, FontWeight.w900);
    });

    test(
      'bold combines with every color style without losing ebook emphasis',
      () {
        for (final brightness in Brightness.values) {
          final colors = const ReaderPreferences()
              .theme(brightness)
              .colorScheme;
          for (final mode in [
            HighlightStyle.background,
            HighlightStyle.underline,
            HighlightStyle.text,
          ]) {
            final preferences = ReaderPreferences(
              highlightStyle: mode,
              boldHighlight: true,
              highlightArgb: 0xffe91e63,
            );
            const base = TextStyle(
              fontStyle: FontStyle.italic,
              decoration: TextDecoration.lineThrough,
            );
            final result = preferences.applyHighlight(base, colors);
            expect(result.fontWeight, FontWeight.bold);
            expect(result.fontStyle, FontStyle.italic);
            expect(
              result.decoration!.contains(TextDecoration.lineThrough),
              isTrue,
            );
            if (mode == HighlightStyle.background) {
              expect(result.backgroundColor, const Color(0xffe91e63));
              expect(
                contrast(result.color!, result.backgroundColor!),
                greaterThanOrEqualTo(4.5),
              );
            } else if (mode == HighlightStyle.underline) {
              expect(
                result.decoration!.contains(TextDecoration.underline),
                isTrue,
              );
              expect(
                contrast(result.decorationColor!, colors.surface),
                greaterThanOrEqualTo(4.5),
              );
            } else {
              expect(
                contrast(result.color!, colors.surface),
                greaterThanOrEqualTo(4.5),
              );
            }
            final normal = preferences
                .copyWith(boldHighlight: false)
                .applyHighlight(base, colors);
            expect(normal.fontWeight, isNull);
            expect(normal.backgroundColor, result.backgroundColor);
            expect(normal.color, result.color);
            expect(normal.decoration, result.decoration);
          }
        }
      },
    );

    test(
      'legacy bold-only preferences migrate without adding a color fill',
      () {
        final migrated = ReaderPreferences.fromJson({
          'schemaVersion': 1,
          'highlightStyle': 'bold',
          'highlightArgb': 0xffff0000,
          'fontSize': 26,
        });
        expect(migrated.highlightStyle, HighlightStyle.none);
        expect(migrated.boldHighlight, isTrue);
        expect(migrated.fontSize, 26);
        final result = migrated.applyHighlight(
          const TextStyle(color: Colors.blue),
          migrated.theme(Brightness.light).colorScheme,
        );
        expect(result.fontWeight, FontWeight.bold);
        expect(result.color, Colors.blue);
        expect(result.backgroundColor, isNull);
        final reopened = ReaderPreferences.fromJson(migrated.toJson());
        expect(reopened.boldHighlight, isTrue);
        expect(reopened.highlightStyle, HighlightStyle.none);
        expect(reopened.toJson()['highlightStyle'], 'none');
      },
    );

    test('underline adds to existing decorations and handles painted text', () {
      final base = TextStyle(
        foreground: Paint()..color = Colors.white,
        background: Paint()..color = Colors.white,
        decoration: TextDecoration.lineThrough,
      );
      final colors = const ReaderPreferences()
          .theme(Brightness.light)
          .colorScheme;
      final underline = const ReaderPreferences(
        highlightStyle: HighlightStyle.underline,
      ).applyHighlight(base, colors);
      expect(
        underline.decoration!.contains(TextDecoration.lineThrough),
        isTrue,
      );
      expect(underline.decoration!.contains(TextDecoration.underline), isTrue);
      expect(
        contrast(underline.foreground!.color, colors.surface),
        greaterThanOrEqualTo(4.5),
      );
      final background = const ReaderPreferences().applyHighlight(base, colors);
      expect(
        contrast(background.foreground!.color, background.background!.color),
        greaterThanOrEqualTo(4.5),
      );
    });
  });

  group('Appearance persistence', () {
    late Directory directory;
    late File file;
    setUp(() async {
      directory = await Directory.systemTemp.createTemp('reader-appearance-');
      file = File('${directory.path}/settings/appearance.json');
    });
    tearDown(() async => directory.delete(recursive: true));

    test(
      'new settings notify immediately and coalesce rapid updates',
      () async {
        final controller = await AppearanceController.load(file);
        addTearDown(controller.dispose);
        expect(await file.exists(), isFalse);
        final observedSizes = <double>[];
        controller.addListener(
          () => observedSizes.add(controller.value.fontSize),
        );
        final saves = <Future<void>>[];
        for (var size = 14; size <= 40; size++) {
          saves.add(
            controller.update(
              controller.value.copyWith(fontSize: size.toDouble()),
            ),
          );
        }
        expect(controller.value.fontSize, 40);
        expect(observedSizes, [
          for (var size = 14; size <= 40; size++) size.toDouble(),
        ]);
        await Future.wait(saves);
        await controller.flush();
        final restored = await AppearanceController.load(file);
        addTearDown(restored.dispose);
        expect(restored.value.fontSize, 40);
        expect(await File('${file.path}.tmp').exists(), isFalse);
        expect(
          jsonDecode(await file.readAsString()),
          controller.value.toJson(),
        );
      },
    );

    test(
      'reading width survives reopening and unrelated appearance edits',
      () async {
        await file.parent.create(recursive: true);
        await file.writeAsString(
          jsonEncode({'schemaVersion': 1, 'font': 'serif', 'fontSize': 24}),
        );
        final controller = await AppearanceController.load(file);
        addTearDown(controller.dispose);
        expect(controller.value.readingWidth, ReadingWidth.standard);
        expect(controller.value.font, ReaderFont.serif);
        for (final width in [
          ReadingWidth.wide,
          ReadingWidth.full,
          ReadingWidth.standard,
        ]) {
          await controller.update(
            controller.value.copyWith(readingWidth: width),
          );
          await controller.update(controller.value.copyWith(fontSize: 26));
          final restored = await AppearanceController.load(file);
          expect(restored.value.readingWidth, width);
          expect(restored.value.font, ReaderFont.serif);
          expect(restored.value.fontSize, 26);
          restored.dispose();
        }
      },
    );

    test('saved bold selection is applied after reopening', () async {
      final controller = await AppearanceController.load(file);
      addTearDown(controller.dispose);
      await controller.update(
        controller.value.copyWith(
          highlightStyle: HighlightStyle.background,
          boldHighlight: true,
          readingWidth: ReadingWidth.full,
        ),
      );
      final restored = await AppearanceController.load(file);
      addTearDown(restored.dispose);
      expect(restored.value.readingWidth, ReadingWidth.full);
      final style = restored.value.applyHighlight(
        const TextStyle(fontWeight: FontWeight.normal),
        restored.value.theme(Brightness.light).colorScheme,
      );
      expect(style.fontWeight, FontWeight.bold);
      expect(style.backgroundColor, isNotNull);
    });

    test(
      'failed atomic saves preserve old data, surface errors and recover',
      () async {
        final controller = await AppearanceController.load(file);
        addTearDown(controller.dispose);
        await controller.update(
          controller.value.copyWith(themeMode: ThemeMode.dark),
        );
        final original = await file.readAsString();
        final obstruction = Directory('${file.path}.tmp');
        await obstruction.create();
        await expectLater(
          controller.update(controller.value.copyWith(font: ReaderFont.serif)),
          throwsA(isA<FileSystemException>()),
        );
        expect(controller.value.font, ReaderFont.serif);
        expect(await file.readAsString(), original);
        await expectLater(
          controller.flush(),
          throwsA(isA<FileSystemException>()),
        );
        await obstruction.delete();
        await controller.update(
          controller.value.copyWith(timelineMode: TimelineMode.file),
        );
        await controller.flush();
        final restored = await AppearanceController.load(file);
        addTearDown(restored.dispose);
        expect(restored.value.font, ReaderFont.serif);
        expect(restored.value.themeMode, ThemeMode.dark);
        expect(restored.value.timelineMode, TimelineMode.file);
      },
    );

    test(
      'malformed storage is not silently overwritten with defaults',
      () async {
        await file.parent.create(recursive: true);
        for (final content in ['{broken', '[]', 'null']) {
          await file.writeAsString(content);
          await expectLater(
            AppearanceController.load(file),
            throwsFormatException,
          );
          expect(await file.readAsString(), content);
        }
      },
    );
  });
}
