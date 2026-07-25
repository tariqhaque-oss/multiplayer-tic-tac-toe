import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class AccountSession {
  final String email;
  final String cookie;
  final String nickname;

  AccountSession({required this.email, required this.cookie, required this.nickname});

  Map<String, dynamic> toJson() => {'email': email, 'cookie': cookie, 'nickname': nickname};

  factory AccountSession.fromJson(Map<String, dynamic> json) => AccountSession(
        email: json['email'] as String,
        cookie: json['cookie'] as String,
        nickname: json['nickname'] as String,
      );
}

/// Persists login sessions and cached stats. Remembers every account that
/// has logged in on this device, not just the current one - logging in as
/// a second account does not forget the first account's credentials.
///
/// This matters for offline sync: if account A played bot games offline,
/// then account B logs in before A ever gets a chance to sync, A's queued
/// games still need a valid session cookie to upload later. Overwriting
/// A's cookie the moment B logs in would make A's queued games permanently
/// unsyncable (no credentials left to authenticate as A). Keeping every
/// account's cookie around (until that account is explicitly forgotten)
/// is what makes the "which account should this sync to?" picker possible.
///
/// Cached stats are namespaced per account email for the same underlying
/// reason as before: no path can show one account's cached numbers under
/// another account's name.
class SessionStore {
  static const _accountsKey = 'accounts';
  static const _activeEmailKey = 'active_email';

  Future<List<AccountSession>> _loadAccounts(SharedPreferences prefs) async {
    final raw = prefs.getString(_accountsKey);
    if (raw == null) return [];
    final list = jsonDecode(raw) as List<dynamic>;
    return list.map((j) => AccountSession.fromJson(j as Map<String, dynamic>)).toList();
  }

  Future<void> _saveAccounts(SharedPreferences prefs, List<AccountSession> accounts) async {
    await prefs.setString(_accountsKey, jsonEncode(accounts.map((a) => a.toJson()).toList()));
  }

  /// Adds or updates this account's stored session and makes it active.
  Future<void> saveSession(String cookie, String email, String nickname) async {
    final prefs = await SharedPreferences.getInstance();
    final accounts = await _loadAccounts(prefs);
    accounts.removeWhere((a) => a.email == email);
    accounts.add(AccountSession(email: email, cookie: cookie, nickname: nickname));
    await _saveAccounts(prefs, accounts);
    await prefs.setString(_activeEmailKey, email);
  }

  /// Ends the active session (returns to the login screen) but keeps this
  /// account's cookie stored, so any offline games it still has queued can
  /// be synced later via the account picker even while logged out.
  Future<void> clearSession() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_activeEmailKey);
  }

  /// Fully forgets an account's stored credentials. Call this only after
  /// its offline queue has been drained (or the user accepts losing the
  /// ability to sync it) - once forgotten, any still-queued games for this
  /// account can never be uploaded, since there's no cookie left to
  /// authenticate as them.
  Future<void> forgetAccount(String email, List<String> games) async {
    final prefs = await SharedPreferences.getInstance();
    final accounts = await _loadAccounts(prefs);
    accounts.removeWhere((a) => a.email == email);
    await _saveAccounts(prefs, accounts);
    for (final game in games) {
      await prefs.remove(_statsCacheKey(email, game));
      await prefs.remove(_statsCacheSyncedAtKey(email, game));
    }
  }

  Future<List<AccountSession>> getAllAccounts() async {
    final prefs = await SharedPreferences.getInstance();
    return _loadAccounts(prefs);
  }

  Future<AccountSession?> _activeAccount() async {
    final prefs = await SharedPreferences.getInstance();
    final activeEmail = prefs.getString(_activeEmailKey);
    if (activeEmail == null) return null;
    final accounts = await _loadAccounts(prefs);
    for (final a in accounts) {
      if (a.email == activeEmail) return a;
    }
    return null;
  }

  Future<String?> getCookie() async => (await _activeAccount())?.cookie;
  Future<String?> getEmail() async => (await _activeAccount())?.email;
  Future<String?> getNickname() async => (await _activeAccount())?.nickname;

  String _statsCacheKey(String email, String game) => 'stats_cache_${game}_$email';
  String _statsCacheSyncedAtKey(String email, String game) => 'stats_cache_synced_at_${game}_$email';

  Future<void> cacheStats(String accountEmail, String game, Map<String, dynamic> stats) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_statsCacheKey(accountEmail, game), jsonEncode(stats));
    await prefs.setString(_statsCacheSyncedAtKey(accountEmail, game), DateTime.now().toIso8601String());
  }

  Future<Map<String, dynamic>?> getCachedStats(String accountEmail, String game) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_statsCacheKey(accountEmail, game));
    if (raw == null) return null;
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  Future<DateTime?> getStatsSyncedAt(String accountEmail, String game) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_statsCacheSyncedAtKey(accountEmail, game));
    if (raw == null) return null;
    return DateTime.parse(raw);
  }
}
