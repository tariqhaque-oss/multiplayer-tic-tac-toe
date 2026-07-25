import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../storage/session_store.dart';
import '../storage/offline_results_queue.dart';

class StatsScreen extends StatefulWidget {
  final String game;
  final String title;
  final String allGamesLabel;

  const StatsScreen({
    super.key,
    required this.game,
    required this.title,
    required this.allGamesLabel,
  });

  @override
  State<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends State<StatsScreen> {
  final _api = ApiClient();
  final _sessionStore = SessionStore();
  final _offlineQueue = OfflineResultsQueue();

  Map<String, dynamic>? _stats;
  DateTime? _syncedAt;
  int _pendingCount = 0;
  bool _loading = true;
  bool _isLive = false;
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);

    final email = await _sessionStore.getEmail();
    final ownCount = email == null ? 0 : await _offlineQueue.countForAccountAndGame(email, widget.game);
    final guestCount = await _offlineQueue.countForAccountAndGame(OfflineResultsQueue.guestEmail, widget.game);
    // Guest-mode games are unclaimed by definition, but they still need to
    // be visible here - otherwise they're invisible until someone thinks
    // to tap Sync Now, even though real games are sitting queued. Scoped
    // to this game only, so Connect Four's pending count doesn't bleed
    // into Tic Tac Toe's screen or vice versa.
    _pendingCount = ownCount + guestCount;

    try {
      final fresh = await _api.fetchStats(widget.game);
      setState(() {
        _stats = fresh;
        _isLive = true;
        _syncedAt = DateTime.now();
      });
    } catch (_) {
      final cached = email == null ? null : await _sessionStore.getCachedStats(email, widget.game);
      final cachedAt = email == null ? null : await _sessionStore.getStatsSyncedAt(email, widget.game);
      setState(() {
        _stats = cached;
        _isLive = false;
        _syncedAt = cachedAt;
      });
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _syncNow() async {
    setState(() => _syncing = true);
    final withPending = await _api.getAccountsWithPendingSync();
    final guestPending = await _api.getGuestPendingCount();
    final allAccounts = await _api.getAllKnownAccounts();
    setState(() => _syncing = false);

    if (!mounted) return;

    if (withPending.isEmpty && guestPending == 0) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Nothing to sync.')));
      return;
    }

    // Only skip asking when there's genuinely no choice to make: at most
    // one account has ever used this device, so nothing queued - guest
    // games included - could possibly belong to anyone else.
    if (allAccounts.length <= 1) {
      if (guestPending > 0 && allAccounts.isNotEmpty) {
        await _claimGuest(allAccounts.first);
      }
      if (withPending.isNotEmpty) {
        await _syncAccount(withPending.first.account);
      }
      return;
    }

    // Two or more accounts have ever used this device - always ask, every
    // time, rather than guessing which one anything queued belongs to.
    await showDialog<void>(
      context: context,
      builder: (_) => _SyncPickerDialog(
        api: _api,
        accounts: withPending,
        guestPendingCount: guestPending,
        allAccounts: allAccounts,
        onChanged: _load,
      ),
    );
    await _load();
  }

  Future<void> _syncAccount(AccountSession account) async {
    setState(() => _syncing = true);
    String message;
    try {
      final synced = await _api.syncOfflineResultsForAccount(account);
      message = synced > 0
          ? 'Synced $synced offline game${synced == 1 ? '' : 's'} for ${account.nickname}.'
          : 'Nothing to sync.';
    } catch (_) {
      message = 'Sync failed - check your connection.';
    }
    setState(() => _syncing = false);

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    await _load();
  }

  Future<void> _claimGuest(AccountSession account) async {
    setState(() => _syncing = true);
    String message;
    try {
      final synced = await _api.claimGuestResults(account);
      message = synced > 0
          ? 'Synced $synced guest game${synced == 1 ? '' : 's'} to ${account.nickname}.'
          : 'Nothing to sync.';
    } catch (_) {
      message = 'Sync failed - check your connection.';
    }
    setState(() => _syncing = false);

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _stats == null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('No stats yet - play a game first!'),
                      if (_pendingCount > 0) ...[
                        const SizedBox(height: 12),
                        Text('$_pendingCount offline game${_pendingCount == 1 ? '' : 's'} waiting to sync'),
                        const SizedBox(height: 8),
                        _syncButton(),
                      ],
                    ],
                  ),
                )
              : _buildStats(),
    );
  }

  Widget _syncButton() {
    return ElevatedButton.icon(
      onPressed: _syncing ? null : _syncNow,
      icon: _syncing
          ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.sync),
      label: Text(_syncing ? 'Syncing...' : 'Sync Now'),
    );
  }

  Widget _buildStats() {
    final overall = _stats!['overall'] as Map<String, dynamic>;
    final random = _stats!['random'] as Map<String, dynamic>;
    final opponents = _stats!['opponents'] as List<dynamic>;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (!_isLive)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.orange.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              _syncedAt != null
                  ? 'Offline - showing stats as of ${_syncedAt!.toLocal()}'
                  : 'Offline - no cached stats available',
            ),
          ),
        if (_pendingCount > 0)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '$_pendingCount offline game${_pendingCount == 1 ? '' : 's'} waiting to sync',
                    style: const TextStyle(color: Colors.grey),
                  ),
                ),
                _syncButton(),
              ],
            ),
          ),
        const SizedBox(height: 16),
        _bucketCard(widget.allGamesLabel, overall),
        _bucketCard('Random Games', random),
        for (final opp in opponents) _bucketCard(opp['nickname'] as String, opp as Map<String, dynamic>),
      ],
    );
  }

  Widget _bucketCard(String title, Map<String, dynamic> bucket) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 6),
            Text('Games: ${bucket['games']}   Wins: ${bucket['wins']}   '
                'Losses: ${bucket['losses']}   Draws: ${bucket['draws']}'),
          ],
        ),
      ),
    );
  }
}

/// Sentinel key for tracking the guest row's busy/failed state alongside
/// real accounts' email-keyed state, since guest games have no email.
const _guestKey = 'guest';

/// Lists every account on this device that has offline games queued, plus
/// a row for guest-mode games (if any) with its own "which account owns
/// these?" chooser - shown whenever 2+ accounts have ever used this
/// device, so syncing never has to guess who anything belongs to.
class _SyncPickerDialog extends StatefulWidget {
  final ApiClient api;
  final List<({AccountSession account, int pendingCount})> accounts;
  final int guestPendingCount;
  final List<AccountSession> allAccounts;
  final VoidCallback onChanged;

  const _SyncPickerDialog({
    required this.api,
    required this.accounts,
    required this.guestPendingCount,
    required this.allAccounts,
    required this.onChanged,
  });

  @override
  State<_SyncPickerDialog> createState() => _SyncPickerDialogState();
}

class _SyncPickerDialogState extends State<_SyncPickerDialog> {
  late List<({AccountSession account, int pendingCount})> _remaining;
  late int _guestRemaining;
  String? _busyKey;
  String? _failedKey;

  @override
  void initState() {
    super.initState();
    _remaining = List.of(widget.accounts);
    _guestRemaining = widget.guestPendingCount;
  }

  Future<void> _syncOne(AccountSession account) async {
    setState(() {
      _busyKey = account.email;
      _failedKey = null;
    });

    bool succeeded = false;
    try {
      await widget.api.syncOfflineResultsForAccount(account);
      succeeded = true;
    } catch (_) {
      succeeded = false;
    }

    if (!mounted) return;
    setState(() {
      _busyKey = null;
      if (succeeded) {
        _remaining.removeWhere((e) => e.account.email == account.email);
      } else {
        // Stays in the list - the sync genuinely failed (e.g. no
        // connection), nothing was uploaded or removed locally, so showing
        // it as done here would be a lie the user can't recover from.
        _failedKey = account.email;
      }
    });
    widget.onChanged();
  }

  Future<void> _claimGuestFor(AccountSession account) async {
    setState(() {
      _busyKey = _guestKey;
      _failedKey = null;
    });

    bool succeeded = false;
    try {
      await widget.api.claimGuestResults(account);
      succeeded = true;
    } catch (_) {
      succeeded = false;
    }

    if (!mounted) return;
    setState(() {
      _busyKey = null;
      if (succeeded) {
        _guestRemaining = 0;
      } else {
        _failedKey = _guestKey;
      }
    });
    widget.onChanged();
  }

  Future<void> _pickGuestOwner() async {
    final chosen = await showDialog<AccountSession>(
      context: context,
      builder: (_) => SimpleDialog(
        title: const Text('Which account played these?'),
        children: [
          for (final account in widget.allAccounts)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(account),
              child: Text(account.nickname),
            ),
        ],
      ),
    );
    if (chosen != null) {
      await _claimGuestFor(chosen);
    }
  }

  @override
  Widget build(BuildContext context) {
    final showGuestRow = _guestRemaining > 0;
    final guestBusy = _busyKey == _guestKey;
    final guestFailed = _failedKey == _guestKey;

    return AlertDialog(
      title: const Text('Offline games need an account'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Choose which account each batch of offline games belongs to.'),
            const SizedBox(height: 12),
            if (showGuestRow)
              ListTile(
                title: const Text('Played as guest'),
                subtitle: Text(
                  guestFailed
                      ? 'Sync failed - check your connection and retry'
                      : '$_guestRemaining game${_guestRemaining == 1 ? '' : 's'} waiting - not yet assigned',
                  style: guestFailed ? const TextStyle(color: Colors.red) : null,
                ),
                trailing: guestBusy
                    ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : TextButton(
                        onPressed: _pickGuestOwner,
                        child: Text(guestFailed ? 'Retry' : 'Choose account'),
                      ),
              ),
            ..._remaining.map((entry) {
              final busy = _busyKey == entry.account.email;
              final failed = _failedKey == entry.account.email;
              return ListTile(
                title: Text(entry.account.nickname),
                subtitle: Text(
                  failed
                      ? 'Sync failed - check your connection and retry'
                      : '${entry.pendingCount} game${entry.pendingCount == 1 ? '' : 's'} waiting',
                  style: failed ? const TextStyle(color: Colors.red) : null,
                ),
                trailing: busy
                    ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : TextButton(
                        onPressed: () => _syncOne(entry.account),
                        child: Text(failed ? 'Retry' : 'Sync'),
                      ),
              );
            }),
            if (_remaining.isEmpty && !showGuestRow) const Text('All synced.'),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Done')),
      ],
    );
  }
}
