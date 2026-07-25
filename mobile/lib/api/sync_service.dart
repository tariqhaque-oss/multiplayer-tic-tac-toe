import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';

import 'api_client.dart';

/// Watches connectivity and automatically drains the offline results queue
/// the moment a connection becomes available - the user never has to
/// remember to "sync" manually.
class SyncService {
  final ApiClient _api;
  StreamSubscription<List<ConnectivityResult>>? _subscription;
  final _syncedController = StreamController<int>.broadcast();

  /// Emits the number of results synced, each time a sync completes.
  Stream<int> get onSynced => _syncedController.stream;

  SyncService(this._api);

  void start() {
    _subscription = Connectivity().onConnectivityChanged.listen((results) async {
      final hasConnection = results.any((r) => r != ConnectivityResult.none);
      if (hasConnection) {
        await trySyncNow();
      }
    });
    // Also try once at startup, in case connectivity was already there.
    trySyncNow();
  }

  Future<void> trySyncNow() async {
    try {
      final synced = await _api.syncOfflineResults();
      if (synced > 0) {
        _syncedController.add(synced);
      }
    } catch (_) {
      // No connectivity or server unreachable - stay queued, try again
      // next time connectivity changes.
    }
  }

  void dispose() {
    _subscription?.cancel();
    _syncedController.close();
  }
}
