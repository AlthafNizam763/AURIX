import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';

import '../utils/app_logger.dart';

enum NetworkStatus { online, offline }

/// Tracks whether the device has a usable network interface.
///
/// This answers "is there a route out of the device", not "is Spotify
/// reachable" — captive portals and DNS failures still surface as request
/// errors. It exists to let the UI show an offline state immediately rather
/// than after a 15-second timeout, and to auto-retry when the radio comes back.
class ConnectivityService {
  ConnectivityService({Connectivity? connectivity})
    : _connectivity = connectivity ?? Connectivity();

  final Connectivity _connectivity;
  final StreamController<NetworkStatus> _controller =
      StreamController<NetworkStatus>.broadcast();

  StreamSubscription<List<ConnectivityResult>>? _subscription;
  NetworkStatus _status = NetworkStatus.online;

  NetworkStatus get status => _status;
  bool get isOffline => _status == NetworkStatus.offline;
  Stream<NetworkStatus> get onStatusChanged => _controller.stream;

  Future<void> start() async {
    _status = _map(await _safeCheck());
    _subscription = _connectivity.onConnectivityChanged.listen(
      (results) {
        final next = _map(results);
        if (next == _status) return;
        _status = next;
        AppLogger.info('Network -> ${next.name}', scope: 'net');
        if (!_controller.isClosed) _controller.add(next);
      },
      onError: (Object error) {
        // A platform channel failure must not make the app think it is
        // permanently offline — assume online and let requests decide.
        AppLogger.warn('Connectivity stream error', scope: 'net', error: error);
        _status = NetworkStatus.online;
      },
    );
  }

  /// Re-checks on demand, e.g. when the user taps "Retry".
  Future<NetworkStatus> refresh() async {
    _status = _map(await _safeCheck());
    return _status;
  }

  Future<List<ConnectivityResult>> _safeCheck() async {
    try {
      return await _connectivity.checkConnectivity();
    } on Object catch (error) {
      AppLogger.warn('Connectivity check failed', scope: 'net', error: error);
      return const [ConnectivityResult.wifi];
    }
  }

  NetworkStatus _map(List<ConnectivityResult> results) {
    final hasRoute = results.any((r) => r != ConnectivityResult.none);
    return hasRoute ? NetworkStatus.online : NetworkStatus.offline;
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
    await _controller.close();
  }
}
