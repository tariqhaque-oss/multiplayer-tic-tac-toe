import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../storage/session_store.dart';
import '../storage/offline_results_queue.dart';

const String apiBaseUrl = 'https://alaab.ai';
const String wsBaseUrl = 'wss://alaab.ai';

/// Game identifiers used throughout the offline queue and API - each maps
/// to its own stats/sync endpoints, since every game has its own results
/// table and symbol set server-side.
const String gameTicTacToe = 'tic_tac_toe';
const String gameConnect4 = 'connect4';
const String gameLudo = 'ludo';
const String gameCourtPiece = 'court_piece';

const Map<String, String> _statsPath = {
  gameTicTacToe: '/api/stats',
  gameConnect4: '/api/connect4/stats',
  gameLudo: '/api/ludo/stats',
  gameCourtPiece: '/api/court-piece/stats',
};

const Map<String, String> _syncPath = {
  gameTicTacToe: '/api/stats/sync-offline-results',
  gameConnect4: '/api/connect4/stats/sync-offline-results',
  gameLudo: '/api/ludo/stats/sync-offline-results',
  gameCourtPiece: '/api/court-piece/stats/sync-offline-results',
};

/// Talks to the existing FastAPI backend. The session cookie is httponly,
/// which only restricts browser JS from reading it - a native HTTP client
/// can read Set-Cookie directly, so we capture and resend it manually
/// (there's no browser here to do it for us).
class ApiClient {
  final SessionStore _sessionStore = SessionStore();
  final OfflineResultsQueue _offlineQueue = OfflineResultsQueue();

  Future<Map<String, String>> _headers() async {
    final cookie = await _sessionStore.getCookie();
    return {
      'Content-Type': 'application/json',
      if (cookie != null) 'Cookie': cookie,
    };
  }

  String? _extractSessionCookie(http.Response response) {
    final setCookie = response.headers['set-cookie'];
    if (setCookie == null) return null;
    // Only the "session=...;" pair is needed for subsequent requests -
    // attributes like Path/HttpOnly/SameSite are for browsers, not us.
    return setCookie.split(';').first;
  }

  Future<({bool ok, String? error, String? nickname})> login(String email, String password) async {
    final response = await http.post(
      Uri.parse('$apiBaseUrl/api/auth/login'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'email': email, 'password': password}),
    );

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    if (body['ok'] != true) {
      return (ok: false, error: body['error'] as String?, nickname: null);
    }

    final cookie = _extractSessionCookie(response);
    final nickname = body['nickname'] as String;
    if (cookie != null) {
      await _sessionStore.saveSession(cookie, email, nickname);
    }
    return (ok: true, error: null, nickname: nickname);
  }

  Future<({bool ok, String? error})> signup(
    String email,
    String nickname,
    String password,
    String confirmPassword,
  ) async {
    final response = await http.post(
      Uri.parse('$apiBaseUrl/api/auth/signup'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'email': email,
        'nickname': nickname,
        'password': password,
        'confirm_password': confirmPassword,
      }),
    );

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (ok: body['ok'] == true, error: body['error'] as String?);
  }

  /// Moves any guest-mode offline games to a newly chosen/created account
  /// and immediately attempts to sync them, since we already have a fresh
  /// cookie for that account right after login/signup.
  Future<int> claimGuestResults(AccountSession account) async {
    await _offlineQueue.reassignAccount(OfflineResultsQueue.guestEmail, account.email);
    return syncOfflineResultsForAccount(account);
  }

  /// Returns the number of this account's offline results that were still
  /// unsynced at the time of logout, so the caller can warn the user - they
  /// stay queued under this account's email and will only ever sync once
  /// this same account logs back in and is online (see OfflineResultsQueue).
  Future<int> logout() async {
    final email = await _sessionStore.getEmail();

    try {
      await syncOfflineResults();
    } catch (_) {
      // No connectivity - fall through, we'll report what's left queued.
    }

    try {
      await http.post(Uri.parse('$apiBaseUrl/api/auth/logout'), headers: await _headers());
    } catch (_) {
      // Offline logout is fine - we clear the local session regardless.
    }
    await _sessionStore.clearSession();

    return email == null ? 0 : _offlineQueue.countForAccount(email);
  }

  /// Returns null if there's no cached session at all (never logged in).
  /// If offline, assumes the cached session is still valid rather than
  /// forcing a login screen with no connectivity.
  Future<bool> hasLocalSession() async {
    final cookie = await _sessionStore.getCookie();
    return cookie != null;
  }

  Future<Map<String, dynamic>> fetchStats(String game) async {
    final email = await _sessionStore.getEmail();
    final path = _statsPath[game]!;
    final response = await http.get(Uri.parse('$apiBaseUrl$path'), headers: await _headers());
    if (response.statusCode != 200) {
      throw Exception('Failed to load stats: ${response.statusCode}');
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (email != null) {
      await _sessionStore.cacheStats(email, game, data);
    }
    return data;
  }

  /// Uploads every queued offline bot result belonging to the *currently
  /// logged in* account, across all games. See [syncOfflineResultsForAccount]
  /// for accounts that are stored on this device but not currently active.
  Future<int> syncOfflineResults() async {
    final email = await _sessionStore.getEmail();
    if (email == null) return 0;
    final accounts = await _sessionStore.getAllAccounts();
    AccountSession? account;
    for (final a in accounts) {
      if (a.email == email) {
        account = a;
        break;
      }
    }
    if (account == null) return 0;
    return syncOfflineResultsForAccount(account);
  }

  /// Uploads every queued offline bot result for a specific account, using
  /// that account's own stored cookie (which may not be the currently
  /// active session) - this is what powers the "which account should this
  /// sync to?" picker when more than one account has data queued. Each
  /// game syncs to its own endpoint, since each has its own results table
  /// and symbol set. Removes exactly the rows the server confirmed for
  /// each game - never clears speculatively. If one game's upload fails,
  /// the others still get synced (and removed) rather than all-or-nothing.
  Future<int> syncOfflineResultsForAccount(AccountSession account) async {
    final games = await _offlineQueue.gamesForAccount(account.email);
    if (games.isEmpty) return 0;

    int totalSynced = 0;
    Object? firstError;

    for (final game in games) {
      try {
        totalSynced += await _syncGameForAccount(account, game);
      } catch (e) {
        firstError ??= e;
      }
    }

    if (firstError != null) {
      // Some games synced (and were removed) successfully above even
      // though we're throwing here - that's intentional partial progress,
      // not a rollback. The caller's catch treats this as "not fully
      // synced" and the remaining game(s) stay queued for retry.
      throw firstError;
    }
    return totalSynced;
  }

  Future<int> _syncGameForAccount(AccountSession account, String game) async {
    final pending = await _offlineQueue.forAccount(account.email, game: game);
    if (pending.isEmpty) return 0;

    final path = _syncPath[game]!;
    http.Response response;
    try {
      response = await http.post(
        Uri.parse('$apiBaseUrl$path'),
        headers: {'Content-Type': 'application/json', 'Cookie': account.cookie},
        body: jsonEncode({'results': pending.map((r) => r.toSyncJson()).toList()}),
      );
    } catch (e) {
      debugPrint('GameHub sync: request threw for ${account.email}/$game: $e');
      rethrow;
    }

    if (response.statusCode != 200) {
      debugPrint('GameHub sync: non-200 for ${account.email}/$game: '
          '${response.statusCode} body=${response.body}');
      throw Exception('Sync failed: ${response.statusCode}');
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    if (body['ok'] == true) {
      await _offlineQueue.removeByIds(pending.map((r) => r.id).toList());
      return body['synced'] as int;
    }
    debugPrint('GameHub sync: server returned ok=false for ${account.email}/$game: $body');
    return 0;
  }

  /// Every account stored on this device that still has offline games
  /// queued, paired with how many. Used to build the sync account picker.
  Future<List<({AccountSession account, int pendingCount})>> getAccountsWithPendingSync() async {
    final accounts = await _sessionStore.getAllAccounts();
    final result = <({AccountSession account, int pendingCount})>[];
    for (final account in accounts) {
      final count = await _offlineQueue.countForAccount(account.email);
      if (count > 0) {
        result.add((account: account, pendingCount: count));
      }
    }
    return result;
  }

  /// Games played before ever logging in - these have no inherent owner,
  /// so they're never auto-claimed. The Sync Now flow surfaces them
  /// explicitly and asks which known account they belong to.
  Future<int> getGuestPendingCount() {
    return _offlineQueue.countForAccount(OfflineResultsQueue.guestEmail);
  }

  /// Every account that has ever logged in on this device, regardless of
  /// whether it currently has anything queued - the full list of possible
  /// owners to offer when claiming guest-mode games.
  Future<List<AccountSession>> getAllKnownAccounts() {
    return _sessionStore.getAllAccounts();
  }
}
