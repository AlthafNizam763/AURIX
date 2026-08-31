import 'dart:async';

/// Collapses a burst of calls into a single trailing invocation.
///
/// Used by search so a Dio request is not fired on every keystroke. Callers
/// must invoke [dispose] — the timer holds a closure over widget state and
/// would otherwise fire after the widget is gone.
class Debouncer {
  Debouncer({this.delay = const Duration(milliseconds: 350)});

  final Duration delay;
  Timer? _timer;

  bool get isPending => _timer?.isActive ?? false;

  void run(void Function() action) {
    _timer?.cancel();
    _timer = Timer(delay, action);
  }

  /// Runs [action] immediately and drops any pending invocation. Used when the
  /// user presses "search" explicitly rather than waiting for the debounce.
  void flush(void Function() action) {
    _timer?.cancel();
    _timer = null;
    action();
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
  }

  void dispose() => cancel();
}

/// Guarantees a minimum gap between invocations, keeping the leading call.
///
/// Used for the Spotify Connect poller and for scroll-driven pagination
/// triggers, where dropping intermediate events is correct but the first
/// event must not be delayed.
class Throttler {
  Throttler({this.interval = const Duration(milliseconds: 500)});

  final Duration interval;
  DateTime? _lastRun;

  bool run(void Function() action) {
    final now = DateTime.now();
    final last = _lastRun;
    if (last != null && now.difference(last) < interval) return false;
    _lastRun = now;
    action();
    return true;
  }

  void reset() => _lastRun = null;
}
