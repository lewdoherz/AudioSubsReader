import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'
    show ScrollDirection, RenderParagraph, RenderAbstractViewport;
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import 'appearance.dart';
import 'appearance_panel.dart';
import 'book.dart';
import 'timeline.dart';

/// Expands only the visual range. The package's word timing remains unchanged.
TextRange readerHighlightRange(
  String text,
  int start,
  int end,
  HighlightRangeMode mode,
) {
  start = start.clamp(0, text.length);
  end = end.clamp(start, text.length);
  if (start == end || mode == HighlightRangeMode.word) {
    return TextRange(start: start, end: end);
  }
  bool boundary(int index) {
    final character = text[index];
    return '.!?。！？\n\r'.contains(character) ||
        (mode == HighlightRangeMode.phrase && ',;:，；：—'.contains(character));
  }

  var left = start;
  while (left > 0 && !boundary(left - 1)) {
    left--;
  }
  var right = end;
  // A cue can itself include terminal punctuation. Do not then include the
  // following sentence merely because the cue's end is exclusive.
  if (!boundary(end - 1)) {
    while (right < text.length && !boundary(right)) {
      right++;
    }
    if (right < text.length) right++;
  }
  while (right < text.length && '”’»"\')]}'.contains(text[right])) {
    right++;
  }
  final whitespace = RegExp(r'\s', unicode: true);
  while (left < right && whitespace.hasMatch(text[left])) {
    left++;
  }
  while (right > left && whitespace.hasMatch(text[right - 1])) {
    right--;
  }
  return TextRange(start: left, end: right);
}

class ReaderScreen extends StatefulWidget {
  const ReaderScreen({
    super.key,
    required this.book,
    required this.progress,
    required this.onProgress,
    required this.appearance,
  });

  final ReaderBook book;
  final ReadingProgress progress;
  final Future<void> Function(ReadingProgress) onProgress;
  final AppearanceController appearance;

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _Chapter {
  const _Chapter(this.title, this.block);
  final String title;
  final int block;
}

class _ReaderScreenState extends State<ReaderScreen>
    with WidgetsBindingObserver {
  final AudioPlayer _player = AudioPlayer();
  final ItemScrollController _scrollController = ItemScrollController();
  final ItemPositionsListener _positions = ItemPositionsListener.create();
  final GlobalKey _activeTextKey = GlobalKey();
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  final Map<String, int> _blockIndices = {};
  final Map<int, int> _durations = {};
  final List<_Chapter> _chapters = [];
  final List<BookCue?> _chapterCues = [];
  Future<void> _audioQueue = Future<void>.value();
  Future<void> _saveQueue = Future<void>.value();
  Timer? _saveTimer;
  int _track = 0;
  int _positionMs = 0;
  int? _dragMs;
  int _loadedTrack = -1;
  double _speed = 1;
  bool _playing = false;
  bool _loading = false;
  bool _acceptEvents = false;
  bool _trackComplete = false;
  bool _ready = false;
  bool _follow = true;
  bool _closing = false;
  bool _allowPop = false;
  bool _disposed = false;
  int _scrollRequest = 0;
  BookCue? _cue;
  String? _error;
  ReadingProgress? _lastSaved;
  late ReaderPreferences _preferences;
  late BookTimeline _timeline;

  ReaderBook get _book => widget.book;
  bool get _hasAudio => _book.tracks.isNotEmpty;
  int get _durationMs =>
      !_hasAudio ? 0 : _durations[_track] ?? _book.tracks[_track].durationMs;

  void _rebuildTimeline() {
    _timeline = BookTimeline([
      for (var i = 0; i < _book.tracks.length; i++)
        _durations[i] ?? _book.tracks[i].durationMs,
    ]);
  }

  void _appearanceChanged() {
    final next = widget.appearance.value;
    final layoutChanged =
        next.font != _preferences.font ||
        next.fontSize != _preferences.fontSize;
    setState(() {
      if (next.timelineMode != _preferences.timelineMode) _dragMs = null;
      _preferences = next;
    });
    if (layoutChanged && _follow) _followCue(jump: true);
  }

  @override
  void didUpdateWidget(covariant ReaderScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.appearance != widget.appearance) {
      oldWidget.appearance.removeListener(_appearanceChanged);
      widget.appearance.addListener(_appearanceChanged);
      _appearanceChanged();
    }
  }

  Future<void> _updatePreferences(ReaderPreferences preferences) async {
    try {
      await widget.appearance.update(preferences);
    } catch (error) {
      _reportError('Saving appearance', error);
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _preferences = widget.appearance.value;
    widget.appearance.addListener(_appearanceChanged);
    _rebuildTimeline();
    for (var i = 0; i < _book.blocks.length; i++) {
      final block = _book.blocks[i];
      _blockIndices[block.id] = i;
      if (i == 0 || block.chapter != _book.blocks[i - 1].chapter) {
        final chapter = block.chapter.trim();
        _chapters.add(_Chapter(chapter.isEmpty ? 'Beginning' : chapter, i));
        _chapterCues.add(null);
      }
    }
    for (final cue in _book.cues) {
      final block = _blockIndices[cue.blockId];
      if (block == null) continue;
      // Index once, rather than rescanning every cue when opening chapters.
      var low = 0;
      var high = _chapters.length;
      while (low + 1 < high) {
        final middle = (low + high) ~/ 2;
        if (_chapters[middle].block <= block) {
          low = middle;
        } else {
          high = middle;
        }
      }
      _chapterCues[low] ??= cue;
    }
    _track = _hasAudio
        ? widget.progress.track.clamp(0, _book.tracks.length - 1)
        : 0;
    _positionMs = math.max(0, widget.progress.positionMs);
    _speed = widget.progress.speed.isFinite
        ? widget.progress.speed.clamp(0.5, 3.0)
        : 1.0;
    _cue = _hasAudio ? _book.cueAt(_track, _positionMs) : null;
    _subscriptions.addAll([
      _player.onPositionChanged.listen((position) {
        if (!_acceptEvents || _trackComplete || !mounted) return;
        _setPosition(position.inMilliseconds);
      }, onError: (Object error) => _reportError('Audio position', error)),
      _player.onDurationChanged.listen((duration) {
        if (!_acceptEvents || !mounted || duration.inMilliseconds <= 0) return;
        if (_durations[_track] == duration.inMilliseconds) return;
        setState(() {
          _durations[_track] = duration.inMilliseconds;
          _rebuildTimeline();
        });
      }, onError: (Object error) => _reportError('Audio duration', error)),
      _player.onPlayerStateChanged.listen((state) {
        if (!_acceptEvents || !mounted) return;
        setState(() => _playing = state == PlayerState.playing);
      }, onError: (Object error) => _reportError('Audio playback', error)),
      _player.onPlayerComplete.listen((_) {
        if (!_acceptEvents || !mounted) return;
        final completedTrack = _track;
        unawaited(
          _runAudio(() async {
            if (!mounted || _track != completedTrack) return;
            if (_track + 1 < _book.tracks.length) {
              await _loadTrack(_track + 1, play: true);
            } else {
              setState(() {
                _playing = false;
                // Native decoders may report zero after their completion event.
                // Keep the finished clock until an explicit seek or replay.
                _trackComplete = true;
              });
              if (_durationMs > 0) _setPosition(_durationMs);
              await _saveProgress();
            }
          }),
        );
      }, onError: (Object error) => _reportError('Audio completion', error)),
    ]);
    _saveTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_playing) unawaited(_saveProgress());
    });
    if (_hasAudio) {
      unawaited(
        _runAudio(() async {
          await _player.setReleaseMode(ReleaseMode.stop);
          await _loadTrack(_track, positionMs: _positionMs);
        }),
      );
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _followCue(jump: true));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      unawaited(
        _runAudio(() async {
          if (Platform.isAndroid &&
              (state == AppLifecycleState.paused ||
                  state == AppLifecycleState.hidden)) {
            if (_ready) await _player.pause();
            if (mounted) setState(() => _playing = false);
          }
          await _saveProgress();
        }),
      );
    }
  }

  Future<void> _runAudio(Future<void> Function() action) {
    final next = _audioQueue.then((_) async {
      if (_disposed) return;
      try {
        await action();
      } catch (error) {
        _acceptEvents = false;
        _ready = false;
        try {
          await _player.pause();
        } catch (_) {
          // Preserve the original native failure, rather than the cleanup error.
        }
        if (mounted) {
          setState(() {
            _loading = false;
            _playing = false;
          });
        }
        _reportError('Audio playback', error);
      }
    });
    _audioQueue = next;
    return next;
  }

  Future<void> _loadTrack(
    int index, {
    int positionMs = 0,
    bool play = false,
  }) async {
    if (!_hasAudio || !mounted) return;
    _acceptEvents = false;
    _trackComplete = false;
    setState(() {
      _loading = true;
      _ready = false;
      _playing = false;
      _track = index;
      _positionMs = math.max(0, positionMs);
      _dragMs = null;
      _error = null;
      _cue = _book.cueAt(_track, _positionMs);
    });
    await _player.stop();
    await _player.setSource(
      DeviceFileSource(_book.resolve(_book.tracks[index].path)),
    );
    await _player.setPlaybackRate(_speed);
    final duration = await _player.getDuration();
    if (_disposed) return;
    if (duration != null &&
        duration.inMilliseconds > 0 &&
        _durations[index] != duration.inMilliseconds) {
      _durations[index] = duration.inMilliseconds;
      _rebuildTimeline();
    }
    final target = _durationMs > 0
        ? positionMs.clamp(0, _durationMs)
        : math.max(0, positionMs);
    await _player.seek(Duration(milliseconds: target));
    if (_disposed) return;
    _loadedTrack = index;
    _acceptEvents = true;
    _setPosition(target);
    if (play) await _player.resume();
    if (!mounted) return;
    setState(() {
      _ready = true;
      _loading = false;
      _playing = play;
    });
    _followCue(jump: true);
    await _saveProgress();
  }

  void _setPosition(int positionMs) {
    if (!mounted) return;
    final position = _durationMs > 0
        ? positionMs.clamp(0, _durationMs)
        : math.max(0, positionMs);
    final cue = _book.cueAt(_track, position);
    final changedCue = !identical(cue, _cue);
    setState(() {
      _positionMs = position;
      _cue = cue;
    });
    if (changedCue) _followCue();
  }

  Future<void> _saveProgress() {
    final progress = ReadingProgress(
      track: _track,
      positionMs: _positionMs,
      speed: _speed,
    );
    final next = _saveQueue.then((_) async {
      final last = _lastSaved;
      if (last != null &&
          last.track == progress.track &&
          last.positionMs == progress.positionMs &&
          last.speed == progress.speed) {
        return;
      }
      try {
        await widget.onProgress(progress);
        _lastSaved = progress;
      } catch (error) {
        _reportError('Saving reading progress', error);
      }
    });
    _saveQueue = next;
    return next;
  }

  void _reportError(String action, Object error) {
    if (mounted && !_disposed) {
      setState(() => _error = '$action: $error');
    } else {
      debugPrint('$action: $error');
    }
  }

  Future<void> _togglePlayback() => _runAudio(() async {
    if (!_ready || _loadedTrack != _track) {
      await _loadTrack(_track, positionMs: _positionMs, play: true);
      return;
    }
    if (_playing) {
      await _player.pause();
      if (mounted) setState(() => _playing = false);
      await _saveProgress();
    } else {
      if (_trackComplete || (_durationMs > 0 && _positionMs >= _durationMs)) {
        await _seekWithinTrack(0);
      }
      await _player.resume();
      if (mounted) setState(() => _playing = true);
    }
  });

  Future<void> _seekWithinTrack(int positionMs) async {
    final target = _durationMs > 0
        ? positionMs.clamp(0, _durationMs)
        : math.max(0, positionMs);
    if (!_ready || _loadedTrack != _track) {
      await _loadTrack(_track, positionMs: target, play: _playing);
      return;
    }
    _acceptEvents = false;
    await _player.seek(Duration(milliseconds: target));
    if (_disposed) return;
    _trackComplete = false;
    _acceptEvents = true;
    _setPosition(target);
    await _saveProgress();
  }

  Future<void> _seek(int positionMs) => _runAudio(() async {
    if (_preferences.timelineMode == TimelineMode.file) {
      await _seekWithinTrack(positionMs);
      return;
    }
    final target = _timeline.seek(positionMs);
    if (target == null) return;
    if (target.track == _track) {
      await _seekWithinTrack(target.positionMs);
    } else {
      final play = _playing;
      await _saveProgress();
      await _loadTrack(target.track, positionMs: target.positionMs, play: play);
    }
  });

  int? get _timelinePositionMs => _preferences.timelineMode == TimelineMode.book
      ? _timeline.positionMs(_track, _positionMs)
      : _positionMs;

  int? get _timelineDurationMs => _preferences.timelineMode == TimelineMode.book
      ? _timeline.totalMs
      : (_durationMs > 0 ? _durationMs : null);

  Future<void> _skip(int deltaMs) {
    if (_preferences.timelineMode == TimelineMode.file) {
      return _seek(_positionMs + deltaMs);
    }
    final position = _timelinePositionMs;
    if (position == null || _timelineDurationMs == null) {
      return Future<void>.value();
    }
    return _seek(position + deltaMs);
  }

  Future<void> _changeTrack(int track) => _runAudio(() async {
    await _saveProgress();
    await _loadTrack(track, play: _playing);
  });

  Future<void> _changeSpeed(double speed) => _runAudio(() async {
    if (_ready) await _player.setPlaybackRate(speed);
    if (!mounted) return;
    setState(() => _speed = speed);
    await _saveProgress();
  });

  Future<void> _close() async {
    if (_closing) return;
    setState(() => _closing = true);
    await _runAudio(() async {
      if (_ready) await _player.pause();
      if (mounted) setState(() => _playing = false);
    });
    await _saveProgress();
    try {
      await widget.appearance.flush();
    } catch (error) {
      _reportError('Saving appearance', error);
      if (mounted) setState(() => _closing = false);
      return;
    }
    if (!mounted) return;
    final saved = _lastSaved;
    if (saved == null ||
        saved.track != _track ||
        saved.positionMs != _positionMs ||
        saved.speed != _speed) {
      // Keep the error visible and permit another exit attempt if storage failed.
      setState(() => _closing = false);
      return;
    }
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

  void _pauseFollow() {
    if (!_follow) return;
    _scrollRequest++;
    setState(() => _follow = false);
  }

  RenderParagraph? _textParagraph(RenderObject? object) {
    if (object is RenderParagraph) return object;
    RenderParagraph? paragraph;
    object?.visitChildren((child) {
      paragraph ??= _textParagraph(child);
    });
    return paragraph;
  }

  void _followCue({bool jump = false}) {
    if (!_follow || _cue == null || !mounted) return;
    final cue = _cue!;
    final block = _blockIndices[cue.blockId];
    if (block == null) return;
    final request = ++_scrollRequest;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_follow || request != _scrollRequest) return;
      final textContext = _activeTextKey.currentContext;
      final paragraph = _textParagraph(textContext?.findRenderObject());
      if (textContext == null || paragraph == null || !paragraph.attached) {
        // Materialize a distant virtualized block before revealing a word in it.
        _scrollToBlock(block, jump: true);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _follow && identical(_cue, cue)) {
            _followCue(jump: jump);
          }
        });
        return;
      }
      final boxes = paragraph.getBoxesForSelection(
        TextSelection(baseOffset: cue.start, extentOffset: cue.end),
      );
      if (boxes.isEmpty) return;
      final viewport = RenderAbstractViewport.of(paragraph);
      final scrollable = Scrollable.maybeOf(textContext);
      if (viewport is! RenderBox || scrollable == null) return;
      final word = boxes.first.toRect();
      final top = paragraph.localToGlobal(word.topLeft, ancestor: viewport).dy;
      final bottom = top + word.height;
      final height = (viewport as RenderBox).size.height;
      if (!jump && top >= height * 0.08 && bottom <= height * 0.85) return;
      final position = scrollable.position;
      final target = viewport
          .getOffsetToReveal(paragraph, 0.3, rect: word)
          .offset
          .clamp(position.minScrollExtent, position.maxScrollExtent);
      if (jump) {
        position.jumpTo(target);
      } else {
        unawaited(
          position.animateTo(
            target,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
          ),
        );
      }
    });
  }

  void _scrollToBlock(int block, {bool jump = false}) {
    final request = ++_scrollRequest;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          request != _scrollRequest ||
          !_scrollController.isAttached) {
        return;
      }
      final visible = _positions.itemPositions.value.where(
        (p) => p.index == block,
      );
      if (!jump &&
          visible.any(
            (p) => p.itemLeadingEdge >= 0.04 && p.itemTrailingEdge <= 0.92,
          )) {
        return;
      }
      if (jump) {
        _scrollController.jumpTo(index: block, alignment: 0.12);
      } else {
        unawaited(
          _scrollController.scrollTo(
            index: block,
            alignment: 0.12,
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOutCubic,
          ),
        );
      }
    });
  }

  Future<void> _showChapters() async {
    if (_chapters.isEmpty) return;
    final selected = await showModalBottomSheet<_Chapter>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        top: false,
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.65,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'Chapters',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: _chapters.length,
                  itemBuilder: (context, index) {
                    final chapter = _chapters[index];
                    final hasTiming = _chapterCues[index] != null;
                    return ListTile(
                      leading: Text('${index + 1}'),
                      title: Text(chapter.title),
                      subtitle: hasTiming
                          ? null
                          : const Text('Text only · no aligned audio'),
                      onTap: () => Navigator.pop(context, chapter),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (selected == null || !mounted) return;
    final chapterIndex = _chapters.indexOf(selected);
    final firstCue = _chapterCues[chapterIndex];
    if (firstCue == null) {
      _pauseFollow();
      _scrollToBlock(selected.block, jump: true);
    } else {
      final cue = firstCue;
      setState(() => _follow = true);
      await _runAudio(() async {
        if (cue.track != _track || !_ready) {
          await _saveProgress();
          await _loadTrack(cue.track, positionMs: cue.startMs, play: _playing);
        } else {
          await _seekWithinTrack(cue.startMs);
          _followCue(jump: true);
        }
      });
    }
  }

  Future<void> _showTracks() async {
    if (!_hasAudio) return;
    final selected = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        top: false,
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.65,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'Audio tracks',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: _book.tracks.length,
                  itemBuilder: (context, index) => ListTile(
                    selected: index == _track,
                    leading: Text('${index + 1}'),
                    title: Text(_book.tracks[index].title),
                    subtitle: Text(
                      _time(
                        _durations[index] ?? _book.tracks[index].durationMs,
                      ),
                    ),
                    trailing: index == _track
                        ? const Icon(Icons.graphic_eq)
                        : null,
                    onTap: () => Navigator.pop(context, index),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (selected != null && mounted && selected != _track) {
      await _changeTrack(selected);
    }
  }

  Future<void> _showAlignment() => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Ebook alignment'),
      scrollable: true,
      content: Text(
        [
          '${_book.alignment['matchedWords'] ?? _book.cues.length} of '
              '${_book.alignment['recognizedWords'] ?? 'unknown'} recognized words have ebook timing.',
          'This is matching coverage, not an accuracy score. Unmatched passages remain readable without highlights.',
          ...(_book.alignment['warnings'] is List
              ? (_book.alignment['warnings'] as List).whereType<String>()
              : <String>[]),
        ].join('\n\n'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    ),
  );

  @override
  void dispose() {
    _disposed = true;
    _acceptEvents = false;
    WidgetsBinding.instance.removeObserver(this);
    widget.appearance.removeListener(_appearanceChanged);
    _saveTimer?.cancel();
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(_saveProgress());
    // Finish any native operation already in flight before disposing its player.
    unawaited(
      _audioQueue.then((_) => _player.dispose()).catchError((Object error) {
        debugPrint('Disposing audio player: $error');
      }),
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope<void>(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_close());
      },
      child: Scaffold(
        appBar: AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_book.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              if (_book.author.isNotEmpty)
                Text(
                  _book.author,
                  style: theme.textTheme.bodySmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
            ],
          ),
          actions: [
            IconButton(
              tooltip: 'Chapters',
              onPressed: _chapters.isEmpty ? null : _showChapters,
              icon: const Icon(Icons.toc),
            ),
            IconButton(
              tooltip: 'Appearance',
              onPressed: () => showAppearancePanel(context, widget.appearance),
              icon: const Icon(Icons.text_fields),
            ),
            PopupMenuButton<String>(
              tooltip: 'More reader options',
              onSelected: (value) {
                if (value == 'tracks') {
                  unawaited(_showTracks());
                } else {
                  unawaited(_showAlignment());
                }
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'tracks',
                  enabled: _hasAudio && !_loading,
                  child: const Text('Audio tracks'),
                ),
                const PopupMenuItem(
                  value: 'alignment',
                  child: Text('Alignment details'),
                ),
              ],
            ),
          ],
        ),
        body: Column(
          children: [
            if (_error != null)
              Material(
                color: theme.colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          _error!,
                          style: TextStyle(
                            color: theme.colorScheme.onErrorContainer,
                          ),
                        ),
                      ),
                      if (_hasAudio && !_loading && !_ready)
                        TextButton(
                          onPressed: () => _runAudio(
                            () => _loadTrack(_track, positionMs: _positionMs),
                          ),
                          child: const Text('Retry'),
                        ),
                      IconButton(
                        tooltip: 'Dismiss error',
                        onPressed: () => setState(() => _error = null),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
              ),
            Expanded(
              child: _book.blocks.isEmpty
                  ? const Center(
                      child: Text('This book contains no readable text.'),
                    )
                  : NotificationListener<ScrollNotification>(
                      onNotification: (notification) {
                        if ((notification is UserScrollNotification &&
                                notification.direction !=
                                    ScrollDirection.idle) ||
                            (notification is ScrollStartNotification &&
                                notification.dragDetails != null)) {
                          _pauseFollow();
                        }
                        return false;
                      },
                      child: SelectionArea(
                        child: ScrollablePositionedList.builder(
                          itemScrollController: _scrollController,
                          itemPositionsListener: _positions,
                          itemCount: _book.blocks.length,
                          padding: const EdgeInsets.symmetric(vertical: 28),
                          itemBuilder: (context, index) => Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 820),
                              child: Padding(
                                padding: EdgeInsets.symmetric(
                                  horizontal:
                                      MediaQuery.sizeOf(context).width < 600
                                      ? 20
                                      : 40,
                                  vertical: 7,
                                ),
                                child: _buildBlock(_book.blocks[index]),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
            ),
            _buildControls(context),
          ],
        ),
      ),
    );
  }

  Widget _buildBlock(BookBlock block) {
    final theme = Theme.of(context);
    final heading =
        block.kind == 'h1' || block.kind == 'h2' || block.kind == 'h3';
    final original = switch (block.kind) {
      'h1' => theme.textTheme.headlineMedium!,
      'h2' => theme.textTheme.headlineSmall!,
      'h3' => theme.textTheme.titleLarge!,
      _ => theme.textTheme.bodyLarge!.copyWith(fontSize: 19, height: 1.65),
    };
    final base = original.copyWith(
      fontFamily: _preferences.fontFamily,
      fontFamilyFallback: const [],
      fontSize: (original.fontSize ?? 19) * _preferences.fontSize / 19,
    );
    final range = _cue?.blockId == block.id
        ? readerHighlightRange(
            block.text,
            _cue!.start,
            _cue!.end,
            _preferences.highlightRange,
          )
        : null;
    final spans = <InlineSpan>[];
    var offset = 0;
    for (final run in block.runs) {
      final style = base.copyWith(
        fontWeight: run.bold ? FontWeight.bold : base.fontWeight,
        fontStyle: run.italic ? FontStyle.italic : base.fontStyle,
        decoration: run.underline ? TextDecoration.underline : base.decoration,
      );
      final from = range == null
          ? 0
          : (range.start - offset).clamp(0, run.text.length);
      final to = range == null
          ? 0
          : (range.end - offset).clamp(0, run.text.length);
      if (from >= to) {
        spans.add(TextSpan(text: run.text, style: style));
      } else {
        if (from > 0) {
          spans.add(TextSpan(text: run.text.substring(0, from), style: style));
        }
        spans.add(
          TextSpan(
            text: run.text.substring(from, to),
            style: _preferences.applyHighlight(style, theme.colorScheme),
          ),
        );
        if (to < run.text.length) {
          spans.add(TextSpan(text: run.text.substring(to), style: style));
        }
      }
      offset += run.text.length;
    }
    Widget text = Text.rich(
      TextSpan(children: spans),
      style: base,
      key: block.id == _cue?.blockId ? _activeTextKey : null,
    );
    if (heading) text = Semantics(header: true, child: text);
    if (block.kind == 'blockquote') {
      text = Container(
        decoration: BoxDecoration(
          border: BorderDirectional(
            start: BorderSide(
              color: theme.colorScheme.outlineVariant,
              width: 3,
            ),
          ),
        ),
        padding: const EdgeInsetsDirectional.only(start: 18),
        child: text,
      );
    } else if (block.kind == 'li') {
      text = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ExcludeSemantics(
            child: Padding(
              padding: const EdgeInsetsDirectional.only(end: 12),
              child: Text('•', style: base),
            ),
          ),
          Expanded(child: text),
        ],
      );
    } else if (block.kind == 'image') {
      final image = block.image;
      text = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (image != null)
            Semantics(
              image: true,
              label: block.text.isEmpty ? 'Book illustration' : block.text,
              child: ExcludeSemantics(
                child: Image.file(
                  File(_book.resolve(image)),
                  fit: BoxFit.contain,
                  height: 360,
                  errorBuilder: (context, error, stackTrace) => Container(
                    padding: const EdgeInsets.all(16),
                    color: theme.colorScheme.errorContainer,
                    child: Text('Cannot display illustration: $error'),
                  ),
                ),
              ),
            ),
          if (block.text.isNotEmpty)
            Padding(padding: const EdgeInsets.only(top: 8), child: text),
        ],
      );
    }
    return SizedBox(width: double.infinity, child: text);
  }

  Widget _buildControls(BuildContext context) {
    final enabled = _hasAudio && !_loading && !_closing;
    final duration = _timelineDurationMs;
    final position = _timelinePositionMs;
    final displayed = _dragMs ?? position;
    final seekEnabled = enabled && duration != null && duration > 0;
    final skipEnabled =
        enabled &&
        (_preferences.timelineMode == TimelineMode.file || seekEnabled);
    final modeLabel = switch (_preferences.highlightRange) {
      HighlightRangeMode.word => 'Word',
      HighlightRangeMode.phrase => 'Phrase',
      HighlightRangeMode.sentence => 'Sentence',
    };
    return Material(
      elevation: 8,
      color: Theme.of(context).colorScheme.surfaceContainer,
      child: SafeArea(
        top: false,
        minimum: const EdgeInsets.fromLTRB(12, 6, 12, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_hasAudio) ...[
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${_track + 1}/${_book.tracks.length} · ${_book.tracks[_track].title}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                  ),
                ],
              ),
              Row(
                children: [
                  PopupMenuButton<TimelineMode>(
                    tooltip: 'Timeline mode',
                    initialValue: _preferences.timelineMode,
                    onSelected: (mode) => _updatePreferences(
                      _preferences.copyWith(timelineMode: mode),
                    ),
                    itemBuilder: (context) => const [
                      PopupMenuItem(
                        value: TimelineMode.book,
                        child: Text('Whole book'),
                      ),
                      PopupMenuItem(
                        value: TimelineMode.file,
                        child: Text('Current file'),
                      ),
                    ],
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _preferences.timelineMode == TimelineMode.book
                                ? 'Book'
                                : 'File',
                          ),
                          const Icon(Icons.arrow_drop_down, size: 18),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      duration == null
                          ? (_preferences.timelineMode == TimelineMode.book
                                ? 'Whole-book duration unavailable'
                                : 'File duration unavailable')
                          : 'Recording time',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
              Row(
                children: [
                  Expanded(child: _clock('Played', displayed)),
                  Expanded(
                    child: _clock(
                      'Remaining',
                      duration == null || displayed == null
                          ? null
                          : math.max(0, duration - displayed),
                    ),
                  ),
                  Expanded(child: _clock('Total', duration)),
                ],
              ),
              Slider(
                label: displayed == null ? 'Unavailable' : _time(displayed),
                value: (displayed ?? 0)
                    .clamp(0, math.max(1, duration ?? 0))
                    .toDouble(),
                max: math.max(1, duration ?? 0).toDouble(),
                onChanged: seekEnabled
                    ? (value) => setState(() => _dragMs = value.round())
                    : null,
                onChangeEnd: seekEnabled
                    ? (value) {
                        setState(() => _dragMs = null);
                        unawaited(_seek(value.round()));
                      }
                    : null,
                semanticFormatterCallback: (value) => _time(value.round()),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    tooltip: 'Previous track',
                    onPressed: enabled && _track > 0
                        ? () => _changeTrack(_track - 1)
                        : null,
                    icon: const Icon(Icons.skip_previous),
                  ),
                  IconButton(
                    tooltip: 'Back 15 seconds',
                    onPressed: skipEnabled ? () => _skip(-15000) : null,
                    icon: const Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.replay),
                        Text('15s', style: TextStyle(fontSize: 10)),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: IconButton.filled(
                      tooltip: _playing ? 'Pause' : 'Play',
                      onPressed: enabled ? _togglePlayback : null,
                      iconSize: 32,
                      icon: _loading
                          ? const SizedBox(
                              width: 28,
                              height: 28,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(_playing ? Icons.pause : Icons.play_arrow),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Forward 15 seconds',
                    onPressed: skipEnabled ? () => _skip(15000) : null,
                    icon: const Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.fast_forward),
                        Text('15s', style: TextStyle(fontSize: 10)),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Next track',
                    onPressed: enabled && _track + 1 < _book.tracks.length
                        ? () => _changeTrack(_track + 1)
                        : null,
                    icon: const Icon(Icons.skip_next),
                  ),
                ],
              ),
            ] else
              const Padding(
                padding: EdgeInsets.all(8),
                child: Text(
                  'This book has no audio tracks. You can still read every chapter.',
                ),
              ),
            Wrap(
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              children: [
                if (_hasAudio)
                  PopupMenuButton<double>(
                    tooltip: 'Playback speed',
                    initialValue: _speed,
                    enabled: !_loading,
                    onSelected: _changeSpeed,
                    itemBuilder: (context) => [
                      for (final speed in [
                        0.5,
                        0.75,
                        1.0,
                        1.25,
                        1.5,
                        1.75,
                        2.0,
                        2.5,
                        3.0,
                      ])
                        PopupMenuItem(
                          value: speed,
                          child: Text('${_speedLabel(speed)}×'),
                        ),
                    ],
                    child: Padding(
                      padding: const EdgeInsets.all(10),
                      child: Text('${_speedLabel(_speed)}×'),
                    ),
                  ),
                PopupMenuButton<HighlightRangeMode>(
                  tooltip: 'Highlight range',
                  initialValue: _preferences.highlightRange,
                  onSelected: (mode) => _updatePreferences(
                    _preferences.copyWith(highlightRange: mode),
                  ),
                  itemBuilder: (context) => const [
                    PopupMenuItem(
                      value: HighlightRangeMode.word,
                      child: Text('Word'),
                    ),
                    PopupMenuItem(
                      value: HighlightRangeMode.phrase,
                      child: Text('Phrase'),
                    ),
                    PopupMenuItem(
                      value: HighlightRangeMode.sentence,
                      child: Text('Sentence'),
                    ),
                  ],
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Text('Highlight: $modeLabel'),
                  ),
                ),
                TextButton.icon(
                  onPressed: _book.cues.isEmpty
                      ? null
                      : () {
                          setState(() => _follow = !_follow);
                          if (_follow) _followCue(jump: true);
                        },
                  icon: Icon(
                    _follow ? Icons.my_location : Icons.location_searching,
                    size: 18,
                  ),
                  label: Text(_follow ? 'Following audio' : 'Resume following'),
                ),
              ],
            ),
            if (_hasAudio && _cue == null)
              Text(
                'No aligned text at this position',
                style: Theme.of(context).textTheme.bodySmall,
              ),
          ],
        ),
      ),
    );
  }

  Widget _clock(String label, int? milliseconds) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelSmall),
        Text(
          milliseconds == null ? '—' : _time(milliseconds),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    ),
  );

  static String _speedLabel(double speed) =>
      speed.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');

  static String _time(int milliseconds) {
    final seconds = math.max(0, milliseconds) ~/ 1000;
    final minutes = seconds ~/ 60;
    final remainder = (seconds % 60).toString().padLeft(2, '0');
    if (minutes < 60) return '$minutes:$remainder';
    return '${minutes ~/ 60}:${(minutes % 60).toString().padLeft(2, '0')}:$remainder';
  }
}
