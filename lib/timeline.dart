/// A file-local source position within a recording timeline.
class TimelinePosition {
  const TimelinePosition(this.track, this.positionMs);

  final int track;
  final int positionMs;
}

/// Recording time, independent of playback speed or listening history.
///
/// Construct again only when effective track durations change. Nonpositive
/// durations are unknown; offsets after an unknown duration are unknown too.
class BookTimeline {
  BookTimeline(Iterable<int> durations)
    : durationsMs = List<int>.unmodifiable(durations) {
    int? offset = 0;
    for (final duration in durationsMs) {
      _offsets.add(offset);
      offset = offset == null || duration <= 0 ? null : offset + duration;
    }
    totalMs = durationsMs.isEmpty ? null : offset;
  }

  final List<int> durationsMs;
  final List<int?> _offsets = [];
  late final int? totalMs;

  int? positionMs(int track, int localMs) {
    if (track < 0 || track >= durationsMs.length) return null;
    final offset = _offsets[track];
    if (offset == null) return null;
    final duration = durationsMs[track];
    final local = duration > 0
        ? localMs.clamp(0, duration)
        : (localMs < 0 ? 0 : localMs);
    return offset + local;
  }

  int? remainingMs(int track, int localMs) {
    final total = totalMs;
    final position = positionMs(track, localMs);
    return total == null || position == null ? null : total - position;
  }

  /// Exact joins belong to the next track, except the final endpoint.
  /// A complete duration map is required to seek globally.
  TimelinePosition? seek(int positionMs) {
    final total = totalMs;
    if (total == null) return null;
    final target = positionMs.clamp(0, total);
    if (target == total) {
      return TimelinePosition(durationsMs.length - 1, durationsMs.last);
    }
    var low = 0;
    var high = durationsMs.length;
    while (low + 1 < high) {
      final middle = (low + high) ~/ 2;
      if (_offsets[middle]! <= target) {
        low = middle;
      } else {
        high = middle;
      }
    }
    return TimelinePosition(low, target - _offsets[low]!);
  }
}
