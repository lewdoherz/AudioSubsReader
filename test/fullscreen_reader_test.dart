import 'dart:io';

import 'package:audiosubs_reader/appearance.dart';
import 'package:audiosubs_reader/book.dart';
import 'package:audiosubs_reader/reader.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;
  final playerEvents = <MethodChannel>[];
  var rejectFullscreen = false;

  setUpAll(() {
    // These tests exercise reader UI transitions, not native audio/window APIs.
    // Real platform fullscreen and audio are covered by native smoke runs.
    messenger.setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers.global'),
      (_) async => null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers.global/events'),
      (_) async => null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers'),
      (call) async {
        if (call.method == 'create') {
          final id = (call.arguments as Map)['playerId'];
          final events = MethodChannel('xyz.luan/audioplayers/events/$id');
          playerEvents.add(events);
          messenger.setMockMethodCallHandler(events, (_) async => null);
        }
        return null;
      },
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('audiosubs_reader/display'),
      (_) async {
        if (rejectFullscreen) {
          throw PlatformException(
            code: 'fullscreen_failed',
            message: 'Window transition refused',
          );
        }
        return null;
      },
    );
  });

  tearDownAll(() {
    for (final name in [
      'xyz.luan/audioplayers.global',
      'xyz.luan/audioplayers.global/events',
      'xyz.luan/audioplayers',
      'audiosubs_reader/display',
    ]) {
      messenger.setMockMethodCallHandler(MethodChannel(name), null);
    }
    for (final events in playerEvents) {
      messenger.setMockMethodCallHandler(events, null);
    }
  });

  Future<void> withReader(
    WidgetTester tester,
    Future<void> Function() exercise, {
    bool accessibleNavigation = false,
  }) async {
    rejectFullscreen = false;
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('reader-fullscreen-test-'),
    ))!;
    final appearance = (await tester.runAsync(
      () =>
          AppearanceController.load(File('${directory.path}/appearance.json')),
    ))!;
    final book = ReaderBook(
      id: 'fullscreen-reader',
      title: 'Fullscreen reading',
      author: '',
      directory: directory.path,
      blocks: [
        for (var index = 0; index < 30; index++)
          BookBlock(
            id: 'paragraph-$index',
            chapter: 'Chapter',
            kind: 'p',
            runs: [
              BookRun(
                text:
                    'Paragraph $index. The page remains readable while its controls come and go.',
              ),
            ],
          ),
      ],
      tracks: const [],
      cues: const [],
      alignment: const {},
    );
    try {
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(accessibleNavigation: accessibleNavigation),
            child: child!,
          ),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (_) => ReaderScreen(
                      book: book,
                      progress: const ReadingProgress(),
                      appearance: appearance,
                      onProgress: (_) async {},
                    ),
                  ),
                ),
                child: const Text('Open fixture'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open fixture'));
      await tester.pumpAndSettle();
      await exercise();
    } finally {
      rejectFullscreen = false;
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      appearance.dispose();
      await tester.runAsync(() => directory.delete(recursive: true));
    }
  }

  testWidgets('reading width expands desktop text and fits narrow screens', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1600, 1000);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await withReader(tester, () async {
      final appearance = tester
          .widget<ReaderScreen>(find.byType(ReaderScreen))
          .appearance;
      final paragraph = find
          .byWidgetPredicate(
            (widget) =>
                widget is Text &&
                (widget.textSpan?.toPlainText().startsWith('Paragraph 0.') ??
                    false),
          )
          .first;
      Future<void> choose(ReadingWidth width) async {
        await tester.runAsync(
          () =>
              appearance.update(appearance.value.copyWith(readingWidth: width)),
        );
        await tester.pumpAndSettle();
      }

      final standard = tester.getSize(paragraph);
      await choose(ReadingWidth.wide);
      final wide = tester.getSize(paragraph);
      expect(wide.width, greaterThan(standard.width));
      expect(wide.height, lessThan(standard.height));
      await choose(ReadingWidth.full);
      final full = tester.getSize(paragraph);
      expect(full.width, greaterThan(wide.width));
      expect(full.width, 1520);
      await tester.sendKeyEvent(LogicalKeyboardKey.f11);
      await tester.pumpAndSettle();
      expect(tester.getSize(paragraph).width, full.width);
      await choose(ReadingWidth.standard);
      expect(tester.getSize(paragraph).width, standard.width);

      tester.view.physicalSize = const Size(360, 800);
      await tester.pumpAndSettle();
      for (final width in ReadingWidth.values) {
        await choose(width);
        expect(tester.getSize(paragraph).width, 320);
      }
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets(
    'temporary controls leave the fullscreen book viewport unchanged',
    (tester) async {
      await withReader(tester, () async {
        await tester.sendKeyEvent(LogicalKeyboardKey.f11);
        await tester.pumpAndSettle();
        expect(find.byType(AppBar), findsNothing);
        final viewport = tester.getRect(find.byType(SelectionArea));
        await tester.tapAt(Offset(viewport.center.dx, viewport.top + 100));
        await tester.pumpAndSettle();
        expect(find.byType(AppBar), findsOneWidget);
        expect(tester.getRect(find.byType(SelectionArea)), viewport);
        await tester.pump(const Duration(seconds: 6));
        await tester.pumpAndSettle();
        expect(find.byType(AppBar), findsNothing);
        expect(tester.getRect(find.byType(SelectionArea)), viewport);
      });
    },
  );

  testWidgets('Back leaves fullscreen before it closes the book', (
    tester,
  ) async {
    await withReader(tester, () async {
      await tester.sendKeyEvent(LogicalKeyboardKey.f11);
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(ReaderScreen), findsOneWidget);
      expect(find.byType(AppBar), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(ReaderScreen), findsNothing);
      expect(find.text('Open fixture'), findsOneWidget);
    });
  });

  testWidgets('native fullscreen failure leaves navigation available', (
    tester,
  ) async {
    await withReader(tester, () async {
      rejectFullscreen = true;
      await tester.sendKeyEvent(LogicalKeyboardKey.f11);
      await tester.pumpAndSettle();
      expect(find.byType(ReaderScreen), findsOneWidget);
      expect(find.byType(AppBar), findsOneWidget);
      expect(find.textContaining('Window transition refused'), findsOneWidget);
      rejectFullscreen = false;
      await tester.sendKeyEvent(LogicalKeyboardKey.f11);
      await tester.pumpAndSettle();
      expect(find.byType(AppBar), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(ReaderScreen), findsOneWidget);
      expect(find.byType(AppBar), findsOneWidget);
    });
  });
  testWidgets('accessible fullscreen keeps navigation controls operable', (
    tester,
  ) async {
    await withReader(tester, () async {
      final normalViewport = tester.getRect(find.byType(SelectionArea));
      await tester.sendKeyEvent(LogicalKeyboardKey.f11);
      await tester.pumpAndSettle();
      expect(find.byType(AppBar), findsOneWidget);
      expect(
        tester.getRect(find.byType(SelectionArea)).height,
        greaterThan(normalViewport.height),
      );
      await tester.pump(const Duration(seconds: 6));
      expect(find.byType(AppBar), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(ReaderScreen), findsOneWidget);
      expect(find.byType(AppBar), findsOneWidget);
      expect(tester.getRect(find.byType(SelectionArea)), normalViewport);
    }, accessibleNavigation: true);
  });
}
