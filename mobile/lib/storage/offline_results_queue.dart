import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

/// A single completed offline bot game, queued until connectivity returns.
class PendingResult {
  final int id;
  final String accountEmail;
  final String game;
  final String difficulty;
  final String mySymbol;
  final String winner;
  final String playedAt;

  PendingResult({
    required this.id,
    required this.accountEmail,
    required this.game,
    required this.difficulty,
    required this.mySymbol,
    required this.winner,
    required this.playedAt,
  });

  Map<String, dynamic> toSyncJson() => {
        'difficulty': difficulty,
        'my_symbol': mySymbol,
        'winner': winner,
        'played_at': playedAt,
      };
}

/// SQLite-backed queue of bot game results recorded while offline. Games
/// are appended here immediately on completion, then drained to the server
/// once connectivity is available - never lost if the app closes offline.
///
/// Every row is tagged with both the account email that played it and
/// which game it belongs to (each game syncs to its own backend endpoint
/// with its own symbols/table, so results can never be routed to the
/// wrong one). Account tagging matters because the device may have more
/// than one account log in over time (e.g. testing, or a shared device) -
/// without it, a sync triggered while a *different* account happens to be
/// logged in would credit that other account with games it never played.
/// Sync and count operations are always scoped to one account's email;
/// other accounts' queued rows are left untouched until that account is
/// the one logged in again.
class OfflineResultsQueue {
  /// Sentinel "account" for games played before ever logging in. Never
  /// synced directly - reassignAccount() moves these rows to a real
  /// account's email once the guest chooses (or creates) one, and only
  /// then does a normal sync proceed.
  static const guestEmail = '__guest__';

  static Database? _db;

  Future<Database> _database() async {
    if (_db != null) return _db!;
    final path = join(await getDatabasesPath(), 'gamehub_offline.db');
    _db = await openDatabase(
      path,
      version: 3,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE pending_results (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            account_email TEXT NOT NULL,
            game TEXT NOT NULL,
            difficulty TEXT NOT NULL,
            my_symbol TEXT NOT NULL,
            winner TEXT NOT NULL,
            played_at TEXT NOT NULL
          )
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 3) {
          // Pre-v3 rows predate multi-game support and only ever existed
          // on test devices during development - safe to drop rather than
          // guess which game they belonged to.
          await db.execute('DROP TABLE IF EXISTS pending_results');
          await db.execute('''
            CREATE TABLE pending_results (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              account_email TEXT NOT NULL,
              game TEXT NOT NULL,
              difficulty TEXT NOT NULL,
              my_symbol TEXT NOT NULL,
              winner TEXT NOT NULL,
              played_at TEXT NOT NULL
            )
          ''');
        }
      },
    );
    return _db!;
  }

  Future<void> add(
    String accountEmail,
    String game,
    String difficulty,
    String mySymbol,
    String winner,
  ) async {
    final db = await _database();
    await db.insert('pending_results', {
      'account_email': accountEmail,
      'game': game,
      'difficulty': difficulty,
      'my_symbol': mySymbol,
      'winner': winner,
      'played_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  /// All queued results for an account, optionally narrowed to one game -
  /// narrowing matters when syncing, since each game uploads to its own
  /// endpoint and must not see another game's rows.
  Future<List<PendingResult>> forAccount(String accountEmail, {String? game}) async {
    final db = await _database();
    final rows = await db.query(
      'pending_results',
      where: game == null ? 'account_email = ?' : 'account_email = ? AND game = ?',
      whereArgs: game == null ? [accountEmail] : [accountEmail, game],
      orderBy: 'id ASC',
    );
    return rows
        .map((r) => PendingResult(
              id: r['id'] as int,
              accountEmail: r['account_email'] as String,
              game: r['game'] as String,
              difficulty: r['difficulty'] as String,
              mySymbol: r['my_symbol'] as String,
              winner: r['winner'] as String,
              playedAt: r['played_at'] as String,
            ))
        .toList();
  }

  /// Distinct games this account has queued results for - lets the sync
  /// logic iterate once per game rather than needing to know in advance
  /// which games might have offline data.
  Future<List<String>> gamesForAccount(String accountEmail) async {
    final db = await _database();
    final rows = await db.query(
      'pending_results',
      distinct: true,
      columns: ['game'],
      where: 'account_email = ?',
      whereArgs: [accountEmail],
    );
    return rows.map((r) => r['game'] as String).toList();
  }

  Future<int> countForAccount(String accountEmail) async {
    final db = await _database();
    final result = await db.rawQuery(
      'SELECT COUNT(*) as c FROM pending_results WHERE account_email = ?',
      [accountEmail],
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  /// Same as [countForAccount] but narrowed to one game - used by each
  /// game's own Stats screen so it only reports its own pending count,
  /// not a combined total across every game.
  Future<int> countForAccountAndGame(String accountEmail, String game) async {
    final db = await _database();
    final result = await db.rawQuery(
      'SELECT COUNT(*) as c FROM pending_results WHERE account_email = ? AND game = ?',
      [accountEmail, game],
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  /// Removes entries only after the server has confirmed they were synced -
  /// never clear speculatively, or a dropped response could lose results.
  Future<void> removeByIds(List<int> ids) async {
    if (ids.isEmpty) return;
    final db = await _database();
    await db.delete('pending_results', where: 'id IN (${ids.join(',')})');
  }

  /// Moves every queued row from one account tag to another - used when a
  /// guest (no account yet) logs in or signs up and chooses which account
  /// their offline games should count for.
  Future<void> reassignAccount(String fromEmail, String toEmail) async {
    final db = await _database();
    await db.update(
      'pending_results',
      {'account_email': toEmail},
      where: 'account_email = ?',
      whereArgs: [fromEmail],
    );
  }
}
