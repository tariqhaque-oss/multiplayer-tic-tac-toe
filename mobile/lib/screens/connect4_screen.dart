import 'dart:async';
import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../api/game_socket.dart';
import '../engine/connect4_engine.dart' as engine;
import '../main.dart';
import '../storage/offline_results_queue.dart';
import '../storage/session_store.dart';
import 'login_screen.dart';
import 'stats_screen.dart';

enum _Phase { onlineLobby, offlineDifficulty, playingOnline, playingOffline }

const _redColor = Color(0xFFDC2626);
const _yellowColor = Color(0xFFEAB308);

class Connect4Screen extends StatefulWidget {
  /// See TicTacToeScreen.guestMode - same guest/offline model, offline
  /// play only exists for guests.
  final bool guestMode;

  const Connect4Screen({super.key, this.guestMode = false});

  @override
  State<Connect4Screen> createState() => _Connect4ScreenState();
}

class _Connect4ScreenState extends State<Connect4Screen> {
  late _Phase _phase;

  // --- Online state ---
  GameSocket? _socket;
  StreamSubscription<Map<String, dynamic>>? _socketSub;
  String? _myPlayer;
  String? _mode;
  String? _keyLabel;
  List<String> _board = engine.newBoard();
  String? _currentPlayer;
  String? _winner;
  Map<String, dynamic> _scores = {'R': 0, 'Y': 0, 'Draw': 0};
  String _message = '';
  final _createKeyController = TextEditingController();
  final _joinKeyController = TextEditingController();
  String _onlineBotDifficulty = 'medium';

  // --- Offline state ---
  final _offlineQueue = OfflineResultsQueue();
  final _sessionStore = SessionStore();
  List<String> _offlineBoard = engine.newBoard();
  String _offlineHumanSymbol = 'R';
  String _offlineCurrentPlayer = 'R';
  String? _offlineWinner;
  String _offlineDifficulty = 'medium';
  int _offlineWins = 0, _offlineLosses = 0, _offlineDraws = 0;

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

  void _connectOnline({required String intent, String key = '', String difficulty = 'medium'}) {
    setState(() => _phase = _Phase.playingOnline);
    _socket = GameSocket();
    _socketSub = null;

    _socket!.connect(wsPath: '/ws/connect4', intent: intent, key: key, difficulty: difficulty).then((_) {
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
        _myPlayer = data['player'] as String;
        _mode = data['mode'] as String?;
        if (_mode == 'private' && data['key'] != null) {
          _keyLabel = 'Share this code: ${data['key']}';
        } else if (_mode == 'bot' && data['difficulty'] != null) {
          _keyLabel = 'Playing vs Bot (${_capitalize(data['difficulty'] as String)})';
        } else {
          _keyLabel = null;
        }
      });
    }

    if (data['type'] == 'state') {
      setState(() {
        _board = List<String>.from(data['board'] as List);
        _currentPlayer = data['currentPlayer'] as String?;
        _winner = data['winner'] as String?;
        _scores = data['scores'] as Map<String, dynamic>;
        if (data['message'] != null && (data['message'] as String).isNotEmpty) {
          _message = data['message'] as String;
        }
      });
    }
  }

  String _capitalize(String s) => s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

  void _makeOnlineMove(int column) {
    if (_myPlayer != _currentPlayer || _winner != null) return;
    if (engine.dropRow(_board, column) == null) return;
    _socket!.sendMove({'column': column});
  }

  void _leaveOnline() {
    _socketSub?.cancel();
    _socket?.close();
    setState(() {
      _phase = _Phase.onlineLobby;
      _board = engine.newBoard();
      _myPlayer = null;
      _keyLabel = null;
      _message = '';
    });
  }

  // ---------------- Offline ----------------

  void _startOffline(String difficulty) {
    setState(() {
      _offlineDifficulty = difficulty;
      _offlineBoard = engine.newBoard();
      _offlineCurrentPlayer = 'R';
      _offlineWinner = null;
      _offlineHumanSymbol = 'R';
      _offlineWins = 0;
      _offlineLosses = 0;
      _offlineDraws = 0;
      _phase = _Phase.playingOffline;
    });
  }

  Future<void> _makeOfflineMove(int column) async {
    if (_offlineCurrentPlayer != _offlineHumanSymbol || _offlineWinner != null) return;
    final row = engine.dropRow(_offlineBoard, column);
    if (row == null) return;

    setState(() {
      _offlineBoard[engine.cellIndex(row, column)] = _offlineHumanSymbol;
    });

    final winner = engine.checkWinner(_offlineBoard);
    if (winner != null) {
      await _finishOfflineRound(winner);
      return;
    }

    final botSymbol = _offlineHumanSymbol == 'R' ? 'Y' : 'R';
    setState(() => _offlineCurrentPlayer = botSymbol);

    await Future.delayed(const Duration(milliseconds: 500));
    if (!mounted) return;

    final botColumn = engine.chooseBotMove(_offlineBoard, botSymbol, _offlineHumanSymbol, _offlineDifficulty);
    final botRow = engine.dropRow(_offlineBoard, botColumn)!;
    setState(() => _offlineBoard[engine.cellIndex(botRow, botColumn)] = botSymbol);

    final botWinner = engine.checkWinner(_offlineBoard);
    if (botWinner != null) {
      await _finishOfflineRound(botWinner);
    } else {
      setState(() => _offlineCurrentPlayer = _offlineHumanSymbol);
    }
  }

  Future<void> _finishOfflineRound(String winner) async {
    final email = widget.guestMode ? OfflineResultsQueue.guestEmail : await _sessionStore.getEmail();
    if (email != null) {
      await _offlineQueue.add(email, gameConnect4, _offlineDifficulty, _offlineHumanSymbol, winner);
    }

    setState(() {
      _offlineWinner = winner;
      if (winner == 'Draw') {
        _offlineDraws++;
      } else if (winner == _offlineHumanSymbol) {
        _offlineWins++;
      } else {
        _offlineLosses++;
      }
    });
  }

  void _nextOfflineRound() {
    setState(() {
      _offlineBoard = engine.newBoard();
      _offlineCurrentPlayer = 'R';
      _offlineWinner = null;
    });
  }

  void _leaveOffline() {
    Navigator.of(context).pop();
  }

  void _goToLoginToSave() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
    );
  }

  // ---------------- UI ----------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Connect Four'),
        actions: [
          if (!widget.guestMode)
            IconButton(
              icon: const Icon(Icons.bar_chart),
              tooltip: 'Stats',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const StatsScreen(
                    game: gameConnect4,
                    title: 'Connect Four Stats',
                    allGamesLabel: 'All Connect Four Games',
                  ),
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
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ElevatedButton(
            onPressed: () => _connectOnline(intent: 'random'),
            child: const Text('Join Random Game'),
          ),
          const SizedBox(height: 20),
          const Text('Play vs Bot (online)'),
          DropdownButton<String>(
            value: _onlineBotDifficulty,
            items: const [
              DropdownMenuItem(value: 'easy', child: Text('Easy')),
              DropdownMenuItem(value: 'medium', child: Text('Medium')),
              DropdownMenuItem(value: 'hard', child: Text('Hard')),
            ],
            onChanged: (v) => setState(() => _onlineBotDifficulty = v!),
          ),
          ElevatedButton(
            onPressed: () => _connectOnline(intent: 'bot', difficulty: _onlineBotDifficulty),
            child: const Text('Play vs Bot'),
          ),
          const SizedBox(height: 20),
          const Divider(),
          const Text('Private game'),
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
    if (_myPlayer == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final canPlay = _myPlayer == _currentPlayer && _winner == null;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Text('You are: ${_symbolName(_myPlayer!)}'),
          if (_keyLabel != null) Text(_keyLabel!),
          const SizedBox(height: 8),
          Text(
            _winner != null
                ? (_winner == 'Draw' ? 'Round draw!' : '${_symbolName(_winner!)} wins round!')
                : 'Current turn: ${_symbolName(_currentPlayer!)}',
            style: TextStyle(fontWeight: FontWeight.bold, color: canPlay ? context.successColor : null),
          ),
          if (_message.isNotEmpty) Text(_message, style: const TextStyle(color: Colors.grey)),
          const SizedBox(height: 16),
          _buildBoard(_board, canPlay, _makeOnlineMove),
          const SizedBox(height: 16),
          Text('Red: ${_scores['R']}   Yellow: ${_scores['Y']}   Draws: ${_scores['Draw']}'),
          const SizedBox(height: 16),
          ElevatedButton(onPressed: _leaveOnline, child: const Text('Leave Game')),
        ],
      ),
    );
  }

  Widget _buildOfflineGame() {
    final canPlay = _offlineCurrentPlayer == _offlineHumanSymbol && _offlineWinner == null;

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
                  OutlinedButton(
                    onPressed: _goToLoginToSave,
                    child: const Text('Log In / Sign Up to Save'),
                  ),
                ],
              ),
            ),
          Text('Offline vs Bot (${_capitalize(_offlineDifficulty)})'),
          const SizedBox(height: 8),
          Text(
            _offlineWinner != null
                ? (_offlineWinner == 'Draw' ? 'Round draw!' : '${_symbolName(_offlineWinner!)} wins round!')
                : 'Current turn: ${_symbolName(_offlineCurrentPlayer)}',
            style: TextStyle(fontWeight: FontWeight.bold, color: canPlay ? context.successColor : null),
          ),
          const SizedBox(height: 16),
          _buildBoard(_offlineBoard, canPlay, _makeOfflineMove),
          const SizedBox(height: 16),
          Text('Wins: $_offlineWins   Losses: $_offlineLosses   Draws: $_offlineDraws'),
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

  String _symbolName(String s) => s == 'R' ? 'Red' : 'Yellow';

  /// Tapping any cell in a column drops into that column's lowest empty
  /// slot - matching physical Connect Four, not exact-cell placement.
  Widget _buildBoard(List<String> board, bool canPlay, void Function(int) onTapColumn) {
    return AspectRatio(
      aspectRatio: engine.cols / engine.rows,
      child: Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: const Color(0xFF1D4ED8),
          borderRadius: BorderRadius.circular(8),
        ),
        child: GridView.count(
          crossAxisCount: engine.cols,
          mainAxisSpacing: 4,
          crossAxisSpacing: 4,
          physics: const NeverScrollableScrollPhysics(),
          children: List.generate(engine.rows * engine.cols, (i) {
            final column = i % engine.cols;
            final cell = board[i];
            final columnPlayable = canPlay && engine.dropRow(board, column) != null;
            return GestureDetector(
              onTap: columnPlayable ? () => onTapColumn(column) : null,
              child: Container(
                margin: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: cell == 'R'
                      ? _redColor
                      : cell == 'Y'
                          ? _yellowColor
                          : Colors.white.withValues(alpha: 0.85),
                ),
              ),
            );
          }),
        ),
      ),
    );
  }
}
