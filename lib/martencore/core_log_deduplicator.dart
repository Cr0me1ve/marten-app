import 'dart:collection';

import 'package:marten/martencore/generated/v2/hcore/hcore.pb.dart';

typedef _CoreLogFingerprint = ({int seconds, int nanos, int level, int type, String message});

/// Drops a native log event when the same protobuf message is delivered by
/// more than one gRPC listener.
///
/// On mobile, foreground and background core servers share one process-wide
/// log observer. Listening to both is still useful for lifecycle recovery, but
/// it means the same observer event can reach Flutter twice. Keep a small FIFO
/// of exact event identities so that duplicate delivery does not duplicate the
/// rolling buffers, file writes, Sentry breadcrumbs, or TURNcoat log scanning.
class CoreLogDeduplicator {
  CoreLogDeduplicator({this.capacity = 256}) : assert(capacity > 0);

  final int capacity;
  final LinkedHashSet<_CoreLogFingerprint> _recent = LinkedHashSet<_CoreLogFingerprint>();

  bool shouldAccept(LogMessage event) {
    // A timestamp is assigned by marten-core before the observer broadcasts
    // the event. Without it, identical text could be two legitimate messages,
    // so prefer keeping both rather than hiding diagnostics.
    if (!event.hasTime()) return true;

    final fingerprint = (
      seconds: event.time.seconds.toInt(),
      nanos: event.time.nanos,
      level: event.level.value,
      type: event.type.value,
      message: event.message,
    );
    if (!_recent.add(fingerprint)) return false;

    if (_recent.length > capacity) {
      _recent.remove(_recent.first);
    }
    return true;
  }

  void clear() => _recent.clear();
}
