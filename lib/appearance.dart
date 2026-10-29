import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

enum ReaderFont { system, serif, sans, mono }

enum ReadingWidth {
  standard(BoxConstraints(maxWidth: 820)),
  wide(BoxConstraints(maxWidth: 1200)),
  full(BoxConstraints());

  const ReadingWidth(this.constraints);
  final BoxConstraints constraints;
}

enum HighlightStyle { background, underline, text, bold }

enum HighlightRangeMode { word, phrase, sentence }

enum TimelineMode { book, file }

@immutable
class ReaderPreferences {
  final ThemeMode themeMode;
  final ReaderFont font;
  final double fontSize;
  final ReadingWidth readingWidth;
  final HighlightStyle highlightStyle;
  final int highlightArgb;
  final HighlightRangeMode highlightRange;
  final TimelineMode timelineMode;

  const ReaderPreferences({
    this.themeMode = ThemeMode.system,
    this.font = ReaderFont.system,
    this.fontSize = 19,
    this.readingWidth = ReadingWidth.standard,
    this.highlightStyle = HighlightStyle.background,
    this.highlightArgb = 0xff80cbc4,
    this.highlightRange = HighlightRangeMode.word,
    this.timelineMode = TimelineMode.book,
  });

  ReaderPreferences copyWith({
    ThemeMode? themeMode,
    ReaderFont? font,
    double? fontSize,
    ReadingWidth? readingWidth,
    HighlightStyle? highlightStyle,
    int? highlightArgb,
    HighlightRangeMode? highlightRange,
    TimelineMode? timelineMode,
  }) => ReaderPreferences(
    themeMode: themeMode ?? this.themeMode,
    font: font ?? this.font,
    fontSize: _safeFontSize(fontSize ?? this.fontSize),
    readingWidth: readingWidth ?? this.readingWidth,
    highlightStyle: highlightStyle ?? this.highlightStyle,
    highlightArgb: _opaque(highlightArgb ?? this.highlightArgb),
    highlightRange: highlightRange ?? this.highlightRange,
    timelineMode: timelineMode ?? this.timelineMode,
  );

  factory ReaderPreferences.fromJson(Map<String, dynamic> json) {
    if (json['schemaVersion'] != 1) return const ReaderPreferences();
    return ReaderPreferences(
      themeMode: _enumValue(
        ThemeMode.values,
        json['themeMode'],
        ThemeMode.system,
      ),
      font: _enumValue(ReaderFont.values, json['font'], ReaderFont.system),
      fontSize: _safeFontSize(json['fontSize']),
      readingWidth: _enumValue(
        ReadingWidth.values,
        json['readingWidth'],
        ReadingWidth.standard,
      ),
      highlightStyle: _enumValue(
        HighlightStyle.values,
        json['highlightStyle'],
        HighlightStyle.background,
      ),
      highlightArgb: _opaque(json['highlightArgb']),
      highlightRange: _enumValue(
        HighlightRangeMode.values,
        json['highlightRange'],
        HighlightRangeMode.word,
      ),
      timelineMode: _enumValue(
        TimelineMode.values,
        json['timelineMode'],
        TimelineMode.book,
      ),
    );
  }

  Map<String, dynamic> toJson() => {
    'schemaVersion': 1,
    'themeMode': themeMode.name,
    'font': font.name,
    'fontSize': _safeFontSize(fontSize),
    'readingWidth': readingWidth.name,
    'highlightStyle': highlightStyle.name,
    'highlightArgb': _opaque(highlightArgb),
    'highlightRange': highlightRange.name,
    'timelineMode': timelineMode.name,
  };

  String? get fontFamily => switch (font) {
    ReaderFont.system => null,
    ReaderFont.serif => 'ReaderSerif',
    ReaderFont.sans => 'ReaderSans',
    ReaderFont.mono => 'ReaderMono',
  };

  TextStyle applyHighlight(TextStyle base, ColorScheme colors) {
    if (highlightStyle == HighlightStyle.bold) {
      final weight = base.fontWeight ?? FontWeight.normal;
      return base.copyWith(
        fontWeight: weight.value > FontWeight.bold.value
            ? weight
            : FontWeight.bold,
      );
    }
    final selected = Color(_opaque(highlightArgb));
    final background = highlightStyle == HighlightStyle.background
        ? selected
        : colors.surface;
    final ink = switch (highlightStyle) {
      HighlightStyle.background => _contrastingInk(selected),
      HighlightStyle.text => _readableColor(selected, background),
      _ => _readableColor(
        base.foreground?.color ?? base.color ?? colors.onSurface,
        background,
      ),
    };
    final decoration = highlightStyle == HighlightStyle.underline
        ? TextDecoration.combine([
            if (base.decoration != null) base.decoration!,
            TextDecoration.underline,
          ])
        : base.decoration;
    return base.copyWith(
      color: base.foreground == null ? ink : null,
      foreground: base.foreground == null ? null : (Paint()..color = ink),
      backgroundColor:
          highlightStyle == HighlightStyle.background && base.background == null
          ? selected
          : null,
      background:
          highlightStyle == HighlightStyle.background && base.background != null
          ? (Paint()..color = selected)
          : null,
      decoration: decoration,
      decorationColor: highlightStyle == HighlightStyle.underline
          ? _readableColor(selected, colors.surface)
          : ink,
      decorationThickness: highlightStyle == HighlightStyle.underline
          ? 2
          : base.decorationThickness,
    );
  }

  // These are app colors only; reader typography is applied by the book view.
  ThemeData theme(Brightness brightness) => ThemeData(
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xff275b51),
      brightness: brightness,
      surface: brightness == Brightness.light
          ? const Color(0xfffaf8f3)
          : const Color(0xff171c1a),
    ),
    useMaterial3: true,
    appBarTheme: const AppBarTheme(centerTitle: false),
    inputDecorationTheme: const InputDecorationTheme(
      border: OutlineInputBorder(),
    ),
  );
}

T _enumValue<T extends Enum>(List<T> values, Object? stored, T fallback) {
  for (final value in values) {
    if (value.name == stored) return value;
  }
  return fallback;
}

double _safeFontSize(Object? value) =>
    value is num && value.isFinite ? value.toDouble().clamp(14.0, 40.0) : 19;

int _opaque(Object? value) => value is int && value >= 0 && value <= 0xffffffff
    ? 0xff000000 | (value & 0x00ffffff)
    : 0xff80cbc4;

double _contrast(Color first, Color second) {
  final a = first.computeLuminance();
  final b = second.computeLuminance();
  return a >= b ? (a + 0.05) / (b + 0.05) : (b + 0.05) / (a + 0.05);
}

Color _contrastingInk(Color background) =>
    _contrast(Colors.black, background) >= _contrast(Colors.white, background)
    ? Colors.black
    : Colors.white;

Color _readableColor(Color selected, Color background) {
  final opaque = Color.alphaBlend(selected, background);
  if (_contrast(opaque, background) >= 4.5) return opaque;
  final target = _contrastingInk(background);
  var low = 0.0;
  var high = 1.0;
  for (var i = 0; i < 16; i++) {
    final middle = (low + high) / 2;
    if (_contrast(Color.lerp(opaque, target, middle)!, background) >= 4.5) {
      high = middle;
    } else {
      low = middle;
    }
  }
  return Color.lerp(opaque, target, high)!;
}

class AppearanceController extends ChangeNotifier {
  final File _file;
  ReaderPreferences _value;
  ReaderPreferences get value => _value;
  final List<({int revision, Completer<void> completion})> _waiters = [];
  int _revision = 0;
  int _handledRevision = 0;
  Future<void>? _saving;
  Object? _saveError;
  StackTrace? _saveStack;

  AppearanceController._(this._file, this._value);

  static Future<AppearanceController> load(File file) async {
    if (!await file.exists()) {
      return AppearanceController._(file, const ReaderPreferences());
    }
    final json = jsonDecode(await file.readAsString());
    if (json is! Map<String, dynamic>) {
      throw const FormatException('Appearance settings must be a JSON object.');
    }
    return AppearanceController._(file, ReaderPreferences.fromJson(json));
  }

  Future<void> update(ReaderPreferences preferences) {
    _value = preferences.copyWith();
    final completion = Completer<void>();
    _waiters.add((revision: ++_revision, completion: completion));
    // Debounce the first snapshot; edits during a write share the next snapshot.
    _saving ??= Future<void>.delayed(
      const Duration(milliseconds: 120),
      _writePending,
    );
    notifyListeners();
    return completion.future;
  }

  Future<void> _writePending() async {
    while (_handledRevision < _revision) {
      final revision = _revision;
      final preferences = _value;
      Object? error;
      StackTrace? stack;
      try {
        await _file.parent.create(recursive: true);
        final temporary = File('${_file.path}.tmp');
        await temporary.writeAsString(
          jsonEncode(preferences.toJson()),
          flush: true,
        );
        await temporary.rename(_file.path);
      } catch (failure, trace) {
        error = failure;
        stack = trace;
      }
      _saveError = error;
      _saveStack = stack;
      _handledRevision = revision;
      var completed = 0;
      while (completed < _waiters.length &&
          _waiters[completed].revision <= revision) {
        completed++;
      }
      for (var i = 0; i < completed; i++) {
        final waiter = _waiters[i].completion;
        if (error == null) {
          waiter.complete();
        } else {
          waiter.completeError(error, stack);
        }
      }
      _waiters.removeRange(0, completed);
    }
    _saving = null;
  }

  Future<void> flush() async {
    while (_saving != null) {
      await _saving;
    }
    final error = _saveError;
    if (error != null) Error.throwWithStackTrace(error, _saveStack!);
  }
}

bool _fontLicensesRegistered = false;

void registerReaderFontLicenses() {
  if (_fontLicensesRegistered) return;
  _fontLicensesRegistered = true;
  LicenseRegistry.addLicense(() async* {
    for (final font in const [
      ('PT Serif', 'assets/fonts/PT_Serif-Web-OFL.txt'),
      ('PT Sans', 'assets/fonts/PT_Sans-Web-OFL.txt'),
      ('IBM Plex Mono', 'assets/fonts/IBMPlexMono-OFL.txt'),
    ]) {
      yield LicenseEntryWithLineBreaks([
        font.$1,
      ], await rootBundle.loadString(font.$2));
    }
  });
}
