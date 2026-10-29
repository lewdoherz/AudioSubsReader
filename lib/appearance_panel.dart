import 'package:flutter/material.dart';

import 'appearance.dart';

Future<void> showAppearancePanel(
  BuildContext context,
  AppearanceController controller,
) async {
  if (MediaQuery.sizeOf(context).width < 600) {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.9,
          ),
          child: _AppearancePanel(controller: controller),
        ),
      ),
    );
  } else {
    await showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 560,
            maxHeight: MediaQuery.sizeOf(context).height * 0.9,
          ),
          child: _AppearancePanel(controller: controller),
        ),
      ),
    );
  }
  // Dismissing via back/barrier must also report an outstanding write failure.
  try {
    await controller.flush();
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Cannot save appearance: $error')));
    }
  }
}

class _AppearancePanel extends StatefulWidget {
  final AppearanceController controller;
  const _AppearancePanel({required this.controller});

  @override
  State<_AppearancePanel> createState() => _AppearancePanelState();
}

class _AppearancePanelState extends State<_AppearancePanel> {
  late final TextEditingController _hex;
  late int _lastArgb;
  String? _colorError;
  String? _saveError;
  bool _saving = false;
  int _saveSerial = 0;

  @override
  void initState() {
    super.initState();
    _lastArgb = widget.controller.value.highlightArgb;
    _hex = TextEditingController(text: _colorHex(_lastArgb));
    widget.controller.addListener(_preferencesChanged);
  }

  void _preferencesChanged() {
    final argb = widget.controller.value.highlightArgb;
    if (argb != _lastArgb) {
      _lastArgb = argb;
      _hex.text = _colorHex(argb);
      _colorError = null;
    }
    setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_preferencesChanged);
    _hex.dispose();
    super.dispose();
  }

  String _colorHex(int argb) =>
      '#${(argb & 0x00ffffff).toRadixString(16).padLeft(6, '0').toUpperCase()}';

  Future<void> _change(ReaderPreferences preferences) async {
    final serial = ++_saveSerial;
    setState(() {
      _saveError = null;
      _saving = true;
    });
    try {
      await widget.controller.update(preferences);
    } catch (error) {
      if (mounted && serial == _saveSerial) {
        setState(() => _saveError = 'Cannot save appearance: $error');
      }
    } finally {
      if (mounted && serial == _saveSerial) {
        setState(() => _saving = false);
      }
    }
  }

  void _applyCustomColor() {
    final text = _hex.text.trim();
    if (!RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(text)) {
      setState(() => _colorError = 'Enter a color as #RRGGBB.');
      return;
    }
    setState(() => _colorError = null);
    _change(
      widget.controller.value.copyWith(
        highlightArgb: 0xff000000 | int.parse(text.substring(1), radix: 16),
      ),
    );
  }

  Future<void> _close() async {
    try {
      await widget.controller.flush();
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        setState(() => _saveError = 'Cannot save appearance: $error');
      }
    }
  }

  Widget _choices<T>(
    String label,
    T selected,
    Map<T, String> choices,
    ValueChanged<T> onSelected,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: 18),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final choice in choices.entries)
              ChoiceChip(
                label: Text(choice.value),
                selected: selected == choice.key,
                onSelected: (_) => onSelected(choice.key),
              ),
          ],
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final preferences = widget.controller.value;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final preview = TextStyle(
      fontFamily: preferences.fontFamily,
      fontSize: preferences.fontSize,
      height: 1.6,
      color: colors.onSurface,
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: Text('Appearance', style: theme.textTheme.titleLarge),
              ),
              IconButton(
                tooltip: 'Close appearance',
                onPressed: _close,
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _choices('Theme', preferences.themeMode, const {
                  ThemeMode.system: 'System',
                  ThemeMode.light: 'Light',
                  ThemeMode.dark: 'Dark',
                }, (value) => _change(preferences.copyWith(themeMode: value))),
                _choices('Book font', preferences.font, const {
                  ReaderFont.system: 'System',
                  ReaderFont.serif: 'Serif',
                  ReaderFont.sans: 'Sans',
                  ReaderFont.mono: 'Mono',
                }, (value) => _change(preferences.copyWith(font: value))),
                Text(
                  'Book size · ${preferences.fontSize.round()} px',
                  style: theme.textTheme.titleSmall,
                ),
                Slider(
                  value: preferences.fontSize,
                  min: 14,
                  max: 40,
                  divisions: 26,
                  label: '${preferences.fontSize.round()} px',
                  onChanged: (value) =>
                      _change(preferences.copyWith(fontSize: value)),
                ),
                _choices(
                  'Reading width',
                  preferences.readingWidth,
                  const {
                    ReadingWidth.standard: 'Standard',
                    ReadingWidth.wide: 'Wide',
                    ReadingWidth.full: 'Full width',
                  },
                  (value) => _change(preferences.copyWith(readingWidth: value)),
                ),
                _choices(
                  'Highlight style',
                  preferences.highlightStyle,
                  const {
                    HighlightStyle.background: 'Background',
                    HighlightStyle.underline: 'Underline',
                    HighlightStyle.text: 'Text',
                    HighlightStyle.none: 'No color',
                  },
                  (value) =>
                      _change(preferences.copyWith(highlightStyle: value)),
                ),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Bold spoken text'),
                  value: preferences.boldHighlight,
                  onChanged: (value) =>
                      _change(preferences.copyWith(boldHighlight: value)),
                ),
                _choices(
                  'Highlight range',
                  preferences.highlightRange,
                  const {
                    HighlightRangeMode.word: 'Word',
                    HighlightRangeMode.phrase: 'Phrase',
                    HighlightRangeMode.sentence: 'Sentence',
                  },
                  (value) =>
                      _change(preferences.copyWith(highlightRange: value)),
                ),
                if (preferences.highlightStyle != HighlightStyle.none) ...[
                  Text('Highlight color', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final entry in const {
                        0xff80cbc4: 'Teal',
                        0xffffd54f: 'Gold',
                        0xff90caf9: 'Blue',
                        0xffce93d8: 'Purple',
                        0xffef9a9a: 'Rose',
                        0xffa5d6a7: 'Green',
                      }.entries)
                        Semantics(
                          label: '${entry.value} highlight',
                          selected: preferences.highlightArgb == entry.key,
                          button: true,
                          child: Tooltip(
                            message: entry.value,
                            child: InkWell(
                              onTap: () => _change(
                                preferences.copyWith(highlightArgb: entry.key),
                              ),
                              borderRadius: BorderRadius.circular(24),
                              child: Container(
                                width: 48,
                                height: 48,
                                decoration: BoxDecoration(
                                  color: Color(entry.key),
                                  shape: BoxShape.circle,
                                  border: Border.all(color: colors.onSurface),
                                ),
                                child: preferences.highlightArgb == entry.key
                                    ? const Icon(
                                        Icons.check,
                                        color: Colors.black,
                                      )
                                    : null,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _hex,
                    autocorrect: false,
                    enableSuggestions: false,
                    textCapitalization: TextCapitalization.characters,
                    maxLength: 7,
                    decoration: InputDecoration(
                      labelText: 'Custom #RRGGBB',
                      errorText: _colorError,
                      counterText: '',
                      suffixIcon: IconButton(
                        tooltip: 'Apply custom color',
                        onPressed: _applyCustomColor,
                        icon: const Icon(Icons.check),
                      ),
                    ),
                    onSubmitted: (_) => _applyCustomColor(),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Text and underline colors adjust for readable contrast.',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
                const SizedBox(height: 18),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: colors.surface,
                    border: Border.all(color: colors.outline),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text.rich(
                    TextSpan(
                      style: preview,
                      children: [
                        const TextSpan(text: 'The story continues. '),
                        TextSpan(
                          text: 'Follow every word',
                          style: preferences.applyHighlight(
                            preview.copyWith(fontStyle: FontStyle.italic),
                            colors,
                          ),
                        ),
                        const TextSpan(text: ' at your own pace.'),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                _choices(
                  'Audio timeline',
                  preferences.timelineMode,
                  const {
                    TimelineMode.book: 'Whole book',
                    TimelineMode.file: 'Current file',
                  },
                  (value) => _change(preferences.copyWith(timelineMode: value)),
                ),
                if (_saveError != null)
                  Semantics(
                    liveRegion: true,
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      color: colors.errorContainer,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _saveError!,
                            style: TextStyle(color: colors.onErrorContainer),
                          ),
                          TextButton(
                            onPressed: () => _change(widget.controller.value),
                            child: const Text('Retry save'),
                          ),
                        ],
                      ),
                    ),
                  )
                else
                  Text(
                    _saving
                        ? 'Saving…'
                        : 'Changes apply live and save automatically.',
                    style: theme.textTheme.bodySmall,
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
