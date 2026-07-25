import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../api/game_socket.dart';
import '../engine/ludo_engine.dart' as engine;
import '../main.dart';
import '../storage/offline_results_queue.dart';
import '../storage/session_store.dart';
import 'login_screen.dart';
import 'stats_screen.dart';

enum _Phase { onlineLobby, offlineDifficulty, playingOnline, playingOffline }

const Map<String, Color> _playerColors = {
  'R': Color(0xFFEF4444),
  'G': Color(0xFF22C55E),
  'Y': Color(0xFFEAB308),
  'B': Color(0xFF3B82F6),
};

/// Which "kind" of board cell each (row, col) is, built once - mirrors
/// ludo.js's cellLookup construction exactly.
class _CellInfo {
  final String kind; // yard | start | home | safe
  final String? color;
  const _CellInfo(this.kind, this.color);
}

final Map<engine.Cell, _CellInfo> _cellLookup = _buildCellLookup();

Map<engine.Cell, _CellInfo> _buildCellLookup() {
  final map = <engine.Cell, _CellInfo>{};
  for (final color in engine.colors) {
    for (final cell in engine.yardCells[color]!) {
      map[cell] = _CellInfo('yard', color);
    }
  }
  for (final color in engine.colors) {
    final cell = engine.path[engine.startIndex[color]!];
    map[cell] = _CellInfo('start', color);
  }
  for (final idx in engine.starIndices) {
    map[engine.path[idx]] = const _CellInfo('safe', null);
  }
  for (final color in engine.colors) {
    for (final cell in engine.home[color]!) {
      map.putIfAbsent(cell, () => _CellInfo('home', color));
    }
  }
  return map;
}

class LudoScreen extends StatefulWidget {
  final bool guestMode;

  const LudoScreen({super.key, this.guestMode = false});

  @override
  State<LudoScreen> createState() => _LudoScreenState();
}

class _LudoScreenState extends State<LudoScreen> {
  late _Phase _phase;

  // --- Online state ---
  GameSocket? _socket;
  StreamSubscription<Map<String, dynamic>>? _socketSub;
  List<String> _myColors = [];
  String _role = 'player'; // player | spectator
  String? _mode;
  String? _keyLabel;
  Map<String, List<int>> _tokens = engine.newTokens();
  String? _currentColor;
  List<String> _occupied = [];
  int? _dice;
  List<int> _legalTokens = [];
  String? _winner;
  Map<String, dynamic> _scores = {'R': 0, 'G': 0, 'Y': 0, 'B': 0};
  int _playersConnected = 0;
  int _spectatorCount = 0;
  Map<String, dynamic>? _seatRequest; // {color, requesterName}
  String _message = '';
  final _createKeyController = TextEditingController();
  final _joinKeyController = TextEditingController();
  String _onlineBotDifficulty = 'medium';
  int _onlineSeats = 1;

  // --- Offline state ---
  final _offlineQueue = OfflineResultsQueue();
  final _sessionStore = SessionStore();
  static const _humanColor = 'R';
  Map<String, List<int>> _offlineTokens = engine.newTokens();
  String _offlineCurrentColor = _humanColor;
  int? _offlineDice;
  List<int> _offlineLegalTokens = [];
  String? _offlineWinner;
  String _offlineDifficulty = 'medium';
  int _offlineWins = 0, _offlineLosses = 0;
  int _offlineConsecutiveSixes = 0;
  bool _offlineBusy = false; // true while bots are taking their turns

  @override
  void initState() {
    super.initState();
    _phase = widget.guestMode ? _Phase.offlineDifficulty : _Phase.onlineLobby;
  }

  @override
  void dispose() {
    _socketSub?.cancel();
    _socket?.close();
    super.dispose();
  }

  // ---------------- Online ----------------

  void _connectOnline({required String intent, String key = '', String difficulty = 'medium', int seats = 1}) {
    setState(() => _phase = _Phase.playingOnline);
    _socket = GameSocket();
    _socketSub = null;

    _socket!
        .connect(wsPath: '/ws/ludo', intent: intent, key: key, difficulty: difficulty, seats: seats)
        .then((_) {
      _socketSub = _socket!.messages.listen(_onSocketMessage);
    });
  }

  void _onSocketMessage(Map<String, dynamic> data) {
    if (!mounted) return;

    if (data['type'] == '_closed') {
      setState(() {
        _message = 'Disconnected.';
        _phase = _Phase.onlineLobby;
      });
      return;
    }

    if (data['type'] == 'player') {
      setState(() {
        _myColors = List<String>.from(data['colors'] as List);
        _role = data['role'] as String;
        _mode = data['mode'] as String?;
        if (_mode == 'private' && data['key'] != null) {
          _keyLabel = 'Share this code: ${data['key']}';
        } else if (_mode == 'bot' && data['difficulty'] != null) {
          _keyLabel = 'Playing vs bots (${_capitalize(data['difficulty'] as String)})';
        } else {
          _keyLabel = null;
        }
      });
    }

    if (data['type'] == 'state') {
      setState(() {
        _tokens = (data['tokens'] as Map<String, dynamic>)
            .map((k, v) => MapEntry(k, List<int>.from(v as List)));
        _currentColor = data['currentColor'] as String?;
        _occupied = List<String>.from(data['occupied'] as List);
        _dice = data['dice'] as int?;
        _legalTokens = List<int>.from(data['legalTokens'] as List);
        _winner = data['winner'] as String?;
        _scores = data['scores'] as Map<String, dynamic>;
        _playersConnected = data['playersConnected'] as int;
        _spectatorCount = data['spectatorCount'] as int;
        _seatRequest = data['seatRequest'] as Map<String, dynamic>?;
        if (data['message'] != null && (data['message'] as String).isNotEmpty) {
          _message = data['message'] as String;
        }
      });
    }
  }

  String _capitalize(String s) => s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

  bool get _myTurnOnline => _role == 'player' && _myColors.contains(_currentColor);

  void _rollOnline() => _socket!.send({'type': 'roll'});

  void _moveOnline(int tokenIndex) {
    if (!_myTurnOnline || _dice == null || !_legalTokens.contains(tokenIndex)) return;
    _socket!.sendMove({'token': tokenIndex});
  }

  void _requestSeat(String color) => _socket!.send({'type': 'request_seat', 'color': color});

  void _respondSeatRequest(bool accept) => _socket!.send({'type': 'respond_seat_request', 'accept': accept});

  void _leaveOnline() {
    _socketSub?.cancel();
    _socket?.close();
    setState(() {
      _phase = _Phase.onlineLobby;
      _tokens = engine.newTokens();
      _myColors = [];
      _keyLabel = null;
      _message = '';
    });
  }

  // ---------------- Offline (guest, vs 3 bots) ----------------

  void _startOffline(String difficulty) {
    setState(() {
      _offlineDifficulty = difficulty;
      _offlineTokens = engine.newTokens();
      _offlineCurrentColor = _humanColor;
      _offlineDice = null;
      _offlineLegalTokens = [];
      _offlineWinner = null;
      _offlineWins = 0;
      _offlineLosses = 0;
      _offlineConsecutiveSixes = 0;
      _phase = _Phase.playingOffline;
    });
  }

  bool get _myTurnOffline => _offlineCurrentColor == _humanColor && _offlineWinner == null;

  void _rollOffline() {
    if (!_myTurnOffline || _offlineDice != null || _offlineBusy) return;

    final roll = Random().nextInt(6) + 1;
    setState(() {
      _offlineConsecutiveSixes = roll == 6 ? _offlineConsecutiveSixes + 1 : 0;
    });

    if (_offlineConsecutiveSixes >= 3) {
      setState(() {
        _offlineConsecutiveSixes = 0;
        _message = 'You rolled three 6s in a row - turn forfeited';
        _offlineCurrentColor = engine.nextColor(_activeOfflineColors, _humanColor)!;
      });
      _runOfflineBotTurns();
      return;
    }

    final moves = engine.legalMoves(_offlineTokens[_humanColor]!, roll);
    if (moves.isEmpty) {
      setState(() {
        _offlineDice = null;
        if (roll == 6) {
          _message = 'You rolled a 6 but have no legal move - roll again';
        } else {
          _message = 'You rolled $roll - no legal moves, turn passes';
          _offlineCurrentColor = engine.nextColor(_activeOfflineColors, _humanColor)!;
        }
      });
      if (roll != 6) _runOfflineBotTurns();
      return;
    }

    setState(() {
      _offlineDice = roll;
      _offlineLegalTokens = moves;
      _message = 'You rolled $roll';
    });
  }

  List<String> get _activeOfflineColors => engine.colors; // human + 3 bots always fill all 4 seats

  Future<void> _moveOfflineToken(int tokenIndex) async {
    if (!_myTurnOffline || _offlineDice == null || !_offlineLegalTokens.contains(tokenIndex)) return;

    final roll = _offlineDice!;
    final result = engine.applyMove(_offlineTokens, _humanColor, tokenIndex, roll);
    setState(() {
      _offlineDice = null;
      _offlineLegalTokens = [];
    });

    if (result.finished) {
      await _finishOfflineRound(_humanColor);
      return;
    }

    if (roll == 6) {
      setState(() => _message = 'Rolls again');
    } else {
      setState(() => _offlineCurrentColor = engine.nextColor(_activeOfflineColors, _humanColor)!);
      await _runOfflineBotTurns();
    }
  }

  Future<void> _runOfflineBotTurns() async {
    setState(() => _offlineBusy = true);

    while (mounted && _offlineWinner == null && _offlineCurrentColor != _humanColor) {
      final color = _offlineCurrentColor;
      await Future.delayed(const Duration(milliseconds: 500));
      if (!mounted) return;

      final roll = Random().nextInt(6) + 1;
      _offlineConsecutiveSixes = roll == 6 ? _offlineConsecutiveSixes + 1 : 0;

      if (_offlineConsecutiveSixes >= 3) {
        _offlineConsecutiveSixes = 0;
        setState(() {
          _offlineCurrentColor = engine.nextColor(_activeOfflineColors, color)!;
          _message = '${engine.colorNames[color]} (bot) rolled three 6s in a row - turn forfeited';
        });
        continue;
      }

      final moves = engine.legalMoves(_offlineTokens[color]!, roll);
      if (moves.isEmpty) {
        if (roll == 6) {
          setState(() => _message = '${engine.colorNames[color]} (bot) rolled a 6 but has no legal move - rolls again');
          continue;
        }
        setState(() {
          _offlineCurrentColor = engine.nextColor(_activeOfflineColors, color)!;
          _message = '${engine.colorNames[color]} (bot) rolled $roll - no legal moves, turn passes';
        });
        continue;
      }

      final tokenIndex = engine.chooseBotMove(_offlineTokens, color, roll, _offlineDifficulty)!;
      final result = engine.applyMove(_offlineTokens, color, tokenIndex, roll);
      final note = result.captured ? ' and captured a token!' : '';

      if (result.finished) {
        setState(() {});
        await _finishOfflineRound(color);
        return;
      }

      if (roll == 6) {
        setState(() =>
            _message = '${engine.colorNames[color]} (bot) rolled $roll and moved token ${tokenIndex + 1}$note - rolls again');
        continue;
      }

      setState(() {
        _offlineCurrentColor = engine.nextColor(_activeOfflineColors, color)!;
        _message = '${engine.colorNames[color]} (bot) rolled $roll and moved token ${tokenIndex + 1}$note';
      });
    }

    if (mounted) setState(() => _offlineBusy = false);
  }

  Future<void> _finishOfflineRound(String winnerColor) async {
    final email = widget.guestMode ? OfflineResultsQueue.guestEmail : await _sessionStore.getEmail();
    if (email != null) {
      await _offlineQueue.add(email, gameLudo, _offlineDifficulty, _humanColor, winnerColor);
    }

    setState(() {
      _offlineWinner = winnerColor;
      _offlineBusy = false;
      if (winnerColor == _humanColor) {
        _offlineWins++;
      } else {
        _offlineLosses++;
      }
    });
  }

  void _nextOfflineRound() {
    setState(() {
      _offlineTokens = engine.newTokens();
      _offlineCurrentColor = _humanColor;
      _offlineDice = null;
      _offlineLegalTokens = [];
      _offlineWinner = null;
      _offlineConsecutiveSixes = 0;
    });
  }

  void _leaveOffline() {
    Navigator.of(context).pop();
  }

  void _goToLoginToSave() {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const LoginScreen()));
  }

  // ---------------- UI ----------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Ludo'),
        actions: [
          if (!widget.guestMode)
            IconButton(
              icon: const Icon(Icons.bar_chart),
              tooltip: 'Stats',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const StatsScreen(game: gameLudo, title: 'Ludo Stats', allGamesLabel: 'All Ludo Games'),
                ),
              ),
            ),
        ],
      ),
      body: switch (_phase) {
        _Phase.onlineLobby => _buildOnlineLobby(),
        _Phase.offlineDifficulty => _buildOfflineDifficultySelect(),
        _Phase.playingOnline => _buildOnlineGame(),
        _Phase.playingOffline => _buildOfflineGame(),
      },
    );
  }

  Widget _buildOnlineLobby() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ElevatedButton(
            onPressed: () => _connectOnline(intent: 'random'),
            child: const Text('Join Random Game'),
          ),
          const SizedBox(height: 20),
          const Text('Play vs Bots (online)'),
          DropdownButton<String>(
            value: _onlineBotDifficulty,
            items: const [
              DropdownMenuItem(value: 'easy', child: Text('Easy')),
              DropdownMenuItem(value: 'medium', child: Text('Medium')),
              DropdownMenuItem(value: 'hard', child: Text('Hard')),
            ],
            onChanged: (v) => setState(() => _onlineBotDifficulty = v!),
          ),
          const SizedBox(height: 8),
          const Text('Seats you control'),
          DropdownButton<int>(
            value: _onlineSeats,
            items: const [
              DropdownMenuItem(value: 1, child: Text('1 (vs 3 bots)')),
              DropdownMenuItem(value: 2, child: Text('2 (vs 2 bots)')),
              DropdownMenuItem(value: 3, child: Text('3 (vs 1 bot)')),
              DropdownMenuItem(value: 4, child: Text('4 (solo practice)')),
            ],
            onChanged: (v) => setState(() => _onlineSeats = v!),
          ),
          ElevatedButton(
            onPressed: () => _connectOnline(intent: 'bot', difficulty: _onlineBotDifficulty, seats: _onlineSeats),
            child: const Text('Play vs Bots'),
          ),
          const SizedBox(height: 20),
          const Divider(),
          const Text('Private game (up to 4 players, extra join as spectators)'),
          TextField(
            controller: _createKeyController,
            decoration: const InputDecoration(labelText: '5-character code to create'),
          ),
          ElevatedButton(
            onPressed: () => _connectOnline(intent: 'create', key: _createKeyController.text.trim()),
            child: const Text('Create Private Game'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _joinKeyController,
            decoration: const InputDecoration(labelText: 'Code to join'),
          ),
          ElevatedButton(
            onPressed: () => _connectOnline(intent: 'join', key: _joinKeyController.text.trim()),
            child: const Text('Join Private Game'),
          ),
        ],
      ),
    );
  }

  Widget _buildOfflineDifficultySelect() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Choose bot difficulty', style: TextStyle(fontSize: 18)),
          const Text('You play Red - 3 bots fill the other colors', style: TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 16),
          for (final d in ['easy', 'medium', 'hard'])
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: ElevatedButton(
                onPressed: () => _startOffline(d),
                child: Text(_capitalize(d)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildOnlineGame() {
    if (_currentColor == null && _role != 'spectator' && _myColors.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    final canAct = _myTurnOnline && _dice != null;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Text(_role == 'spectator'
              ? 'You are spectating'
              : 'You are: ${_myColors.map((c) => engine.colorNames[c]).join(' & ')}'),
          if (_keyLabel != null) Text(_keyLabel!),
          const SizedBox(height: 8),
          Text(
            _winner != null
                ? '${engine.colorNames[_winner!]} wins the round!'
                : _currentColor == null
                    ? 'Waiting for players...'
                    : _myTurnOnline
                        ? (_dice == null ? 'Your turn - roll the dice' : 'Your turn - pick a token to move')
                        : 'Current turn: ${engine.colorNames[_currentColor!]}',
            style: TextStyle(fontWeight: FontWeight.bold, color: _myTurnOnline ? context.successColor : null),
          ),
          if (_message.isNotEmpty) Text(_message, style: const TextStyle(color: Colors.grey)),
          const SizedBox(height: 12),
          if (_seatRequest != null) _buildSeatRequestBanner(),
          if (_role == 'spectator') _buildSpectatorPanel(),
          const SizedBox(height: 12),
          _buildDiceRow(_dice, _myTurnOnline && _dice == null && _role != 'spectator', _rollOnline),
          const SizedBox(height: 12),
          _buildBoard(_tokens, canAct, _currentColor, _legalTokens, _moveOnline),
          const SizedBox(height: 16),
          _buildScoreRow(_scores),
          const SizedBox(height: 8),
          Text('Players: $_playersConnected   Spectators: $_spectatorCount', style: const TextStyle(fontSize: 12)),
          const SizedBox(height: 16),
          ElevatedButton(onPressed: _leaveOnline, child: const Text('Leave Game')),
        ],
      ),
    );
  }

  Widget _buildSeatRequestBanner() {
    final req = _seatRequest!;
    final color = req['color'] as String;
    final requesterName = req['requesterName'] as String;
    final iHoldThisSeat = _role == 'player' && _myColors.contains(color);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.primary, width: 2),
        borderRadius: BorderRadius.circular(10),
      ),
      child: iHoldThisSeat
          ? Column(
              children: [
                Text('$requesterName is requesting your ${engine.colorNames[color]} seat.'),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    ElevatedButton(onPressed: () => _respondSeatRequest(true), child: const Text('Give up seat')),
                    const SizedBox(width: 8),
                    OutlinedButton(onPressed: () => _respondSeatRequest(false), child: const Text('Keep playing')),
                  ],
                ),
              ],
            )
          : Text('$requesterName is requesting ${engine.colorNames[color]}\'s seat...'),
    );
  }

  Widget _buildSpectatorPanel() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Request a seat:', style: TextStyle(fontWeight: FontWeight.bold)),
          for (final color in _occupied)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(engine.colorNames[color]!),
                  ElevatedButton(
                    onPressed: _seatRequest != null ? null : () => _requestSeat(color),
                    child: Text(_seatRequest?['color'] == color ? 'Requested...' : 'Request to Play'),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildOfflineGame() {
    final canAct = _myTurnOffline && _offlineDice != null;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          if (widget.guestMode)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: Colors.blue.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                children: [
                  const Text('Playing as guest - results are saved on this device only.'),
                  const SizedBox(height: 8),
                  OutlinedButton(onPressed: _goToLoginToSave, child: const Text('Log In / Sign Up to Save')),
                ],
              ),
            ),
          Text('vs 3 Bots (${_capitalize(_offlineDifficulty)}) - You are Red'),
          const SizedBox(height: 8),
          Text(
            _offlineWinner != null
                ? '${engine.colorNames[_offlineWinner!]} wins the round!'
                : _myTurnOffline
                    ? (_offlineDice == null ? 'Your turn - roll the dice' : 'Your turn - pick a token to move')
                    : 'Current turn: ${engine.colorNames[_offlineCurrentColor]}',
            style: TextStyle(fontWeight: FontWeight.bold, color: _myTurnOffline ? context.successColor : null),
          ),
          if (_message.isNotEmpty) Text(_message, style: const TextStyle(color: Colors.grey)),
          const SizedBox(height: 12),
          _buildDiceRow(_offlineDice, _myTurnOffline && _offlineDice == null && !_offlineBusy, _rollOffline),
          const SizedBox(height: 12),
          _buildBoard(_offlineTokens, canAct, _offlineCurrentColor, _offlineLegalTokens, _moveOfflineToken),
          const SizedBox(height: 16),
          Text('Wins: $_offlineWins   Losses: $_offlineLosses'),
          const SizedBox(height: 8),
          const Text('Results save on this device and sync automatically once you\'re online.',
              style: TextStyle(fontSize: 12, color: Colors.grey), textAlign: TextAlign.center),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (_offlineWinner != null)
                ElevatedButton(onPressed: _nextOfflineRound, child: const Text('Next Round')),
              const SizedBox(width: 12),
              ElevatedButton(onPressed: _leaveOffline, child: const Text('Leave Game')),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDiceRow(int? dice, bool canRoll, VoidCallback onRoll) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: 46,
          height: 46,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: Border.all(color: Theme.of(context).dividerColor, width: 2),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(dice?.toString() ?? '-', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
        ),
        const SizedBox(width: 16),
        ElevatedButton(onPressed: canRoll ? onRoll : null, child: const Text('Roll')),
      ],
    );
  }

  Widget _buildScoreRow(Map<String, dynamic> scores) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        for (final color in engine.colors)
          Column(
            children: [
              CircleAvatar(radius: 8, backgroundColor: _playerColors[color]),
              const SizedBox(height: 4),
              Text('${scores[color]}'),
            ],
          ),
      ],
    );
  }

  /// Renders the full 15x15 board matching the website's layout exactly -
  /// a Stack of absolutely-positioned cell backgrounds and tokens, sized
  /// off the available square width divided into 15 equal cells.
  Widget _buildBoard(
    Map<String, List<int>> tokens,
    bool canAct,
    String? activeColor,
    List<int> legalTokenIndices,
    void Function(int) onMoveToken,
  ) {
    return AspectRatio(
      aspectRatio: 1,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = constraints.maxWidth;
          final cellSize = size / 15;

          final children = <Widget>[];

          // Board background frame.
          children.add(Container(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(14),
            ),
          ));

          // Cell backgrounds.
          for (var r = 0; r < 15; r++) {
            for (var c = 0; c < 15; c++) {
              if (r >= 6 && r <= 8 && c >= 6 && c <= 8) continue; // center piece covers this
              final info = _cellLookup[(r, c)];
              children.add(Positioned(
                left: c * cellSize,
                top: r * cellSize,
                width: cellSize,
                height: cellSize,
                child: _buildCell(info, r, c, cellSize),
              ));
            }
          }

          // Center trophy piece (rows/cols 6-8), four-color quadrant.
          children.add(Positioned(
            left: 6 * cellSize,
            top: 6 * cellSize,
            width: cellSize * 3,
            height: cellSize * 3,
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                gradient: const SweepGradient(
                  colors: [
                    Color(0xFF3B82F6), // B
                    Color(0xFF3B82F6),
                    Color(0xFF22C55E), // G
                    Color(0xFF22C55E),
                    Color(0xFFEF4444), // R
                    Color(0xFFEF4444),
                    Color(0xFFEAB308), // Y
                    Color(0xFFEAB308),
                    Color(0xFF3B82F6),
                  ],
                  stops: [0, 0.25, 0.25, 0.5, 0.5, 0.75, 0.75, 1.0, 1.0],
                ),
              ),
              alignment: Alignment.center,
              child: Text('🏆', style: TextStyle(fontSize: cellSize)),
            ),
          ));

          // Tokens, stacked with an offset if multiple share a cell.
          final seenAtCell = <engine.Cell, int>{};
          for (final color in engine.colors) {
            final positions = tokens[color]!;
            for (var i = 0; i < positions.length; i++) {
              final pos = positions[i];
              final cell = engine.globalCellFor(color, pos, i);
              final stackIndex = seenAtCell[cell] ?? 0;
              seenAtCell[cell] = stackIndex + 1;

              final clickable = canAct && color == activeColor && legalTokenIndices.contains(i);

              double dx = 0, dy = 0;
              if (stackIndex == 1) {
                dx = -cellSize * 0.15;
                dy = -cellSize * 0.15;
              } else if (stackIndex == 2) {
                dx = cellSize * 0.15;
                dy = -cellSize * 0.15;
              } else if (stackIndex == 3) {
                dx = 0;
                dy = cellSize * 0.15;
              }

              children.add(Positioned(
                left: cell.$2 * cellSize + dx,
                top: cell.$1 * cellSize + dy,
                width: cellSize,
                height: cellSize,
                child: GestureDetector(
                  onTap: clickable ? () => onMoveToken(i) : null,
                  child: Padding(
                    padding: EdgeInsets.all(cellSize * (stackIndex > 0 ? 0.2 : 0.14)),
                    child: Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _playerColors[color],
                        border: Border.all(color: Colors.black26, width: 2),
                        boxShadow: clickable
                            ? [BoxShadow(color: Colors.amber.withValues(alpha: 0.9), blurRadius: 8, spreadRadius: 2)]
                            : const [BoxShadow(color: Colors.black38, blurRadius: 3, offset: Offset(0, 2))],
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        '${i + 1}',
                        style: TextStyle(
                          fontSize: cellSize * 0.4,
                          fontWeight: FontWeight.w800,
                          color: Colors.black.withValues(alpha: 0.55),
                        ),
                      ),
                    ),
                  ),
                ),
              ));
            }
          }

          return Stack(children: children);
        },
      ),
    );
  }

  Widget _buildCell(_CellInfo? info, int r, int c, double cellSize) {
    if (info == null) {
      return Container(
        decoration: BoxDecoration(border: Border.all(color: const Color(0x22808080), width: 0.5)),
      );
    }

    if (info.kind == 'safe') {
      return Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          border: Border.all(color: const Color(0x22808080), width: 0.5),
        ),
        alignment: Alignment.center,
        child: Text('⭐', style: TextStyle(fontSize: cellSize * 0.5)),
      );
    }

    if (info.kind == 'start') {
      return Container(
        decoration: BoxDecoration(
          color: _playerColors[info.color],
          border: Border.all(color: const Color(0x22808080), width: 0.5),
        ),
      );
    }

    if (info.kind == 'home') {
      return Container(
        decoration: BoxDecoration(
          color: _playerColors[info.color]!.withValues(alpha: 0.45),
          border: Border.all(color: const Color(0x22808080), width: 0.5),
        ),
      );
    }

    // yard
    final insideNest = r % 6 >= 1 && r % 6 <= 4 && c % 6 >= 1 && c % 6 <= 4;
    if (insideNest) {
      return Container(
        margin: EdgeInsets.all(cellSize * 0.06),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          border: Border.all(color: Theme.of(context).dividerColor, width: 2),
          borderRadius: BorderRadius.circular(6),
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: _playerColors[info.color]!.withValues(alpha: 0.3),
        border: Border.all(color: const Color(0x22808080), width: 0.5),
      ),
    );
  }
}
