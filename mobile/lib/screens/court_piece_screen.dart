import 'dart:async';
import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../api/game_socket.dart';
import '../engine/court_piece_engine.dart' as engine;
import '../storage/offline_results_queue.dart';
import '../storage/session_store.dart';
import 'login_screen.dart';
import 'stats_screen.dart';

enum _Phase { onlineLobby, playingOnline, playingOffline }

const Map<String, String> _seatPosition = {'P1': 'bottom', 'P2': 'left', 'P3': 'top', 'P4': 'right'};
const Map<String, String> _suitNames = {'♠': 'Spades', '♥': 'Hearts', '♦': 'Diamonds', '♣': 'Clubs'};
final RegExp _keyPattern = RegExp(r'^[A-Za-z0-9]{5}$');

const Map<int, String> _closeErrors = {
  4402: 'That code is already in use by another game. Try a different one.',
  4403: 'Code must be exactly 5 letters/numbers.',
  4404: 'No game found with that code.',
  4405: 'That random game is already full. Try again to join/create another.',
  4407: 'Invalid seat selection.',
};

/// A single view-model shape rendered by the shared table UI, whether the
/// data came from the server (online, fog-of-war already applied) or from
/// the local offline engine.
class _TableView {
  final Map<String, String> seatNames;
  final List<String> occupied;
  final String? currentTurnSeat;
  final List<String> mySeats;
  final Map<String, List<engine.CardModel>> myHands;
  final Map<String, List<engine.CardModel>> legalCardsForMe;
  final Map<String, int> handCounts;
  final List<engine.TrickPlay> currentTrick;
  final int pendingPileTricks;
  final String? trumpSuit;
  final String? lastTrickWinnerSeat;
  final Map<String, int> trickWins;
  final Map<String, int> tensCollected;
  final Map<String, int> matchScore;

  const _TableView({
    required this.seatNames,
    required this.occupied,
    required this.currentTurnSeat,
    required this.mySeats,
    required this.myHands,
    required this.legalCardsForMe,
    required this.handCounts,
    required this.currentTrick,
    required this.pendingPileTricks,
    required this.trumpSuit,
    required this.lastTrickWinnerSeat,
    required this.trickWins,
    required this.tensCollected,
    required this.matchScore,
  });
}

class CourtPieceScreen extends StatefulWidget {
  final bool guestMode;

  const CourtPieceScreen({super.key, this.guestMode = false});

  @override
  State<CourtPieceScreen> createState() => _CourtPieceScreenState();
}

class _CourtPieceScreenState extends State<CourtPieceScreen> {
  late _Phase _phase;

  // --- Online state ---
  GameSocket? _socket;
  StreamSubscription<Map<String, dynamic>>? _socketSub;
  List<String> _mySeats = [];
  String _role = 'player';
  String? _mode;
  String? _keyLabel;
  String? _phaseOnline;
  String? _trumpSuit;
  String _trumpCallerSeat = 'P1';
  String? _currentTurnSeat;
  List<engine.TrickPlay> _currentTrick = [];
  int _pendingPileTricks = 0;
  Map<String, int> _trickWins = {'A': 0, 'B': 0};
  Map<String, int> _tensCollected = {'A': 0, 'B': 0};
  String? _lastTrickWinnerSeat;
  String? _winner;
  Map<String, int> _handCounts = {for (final s in engine.seats) s: 0};
  List<String> _occupied = [];
  Map<String, String> _seatNames = {};
  Map<String, List<engine.CardModel>> _myHands = {};
  Map<String, List<engine.CardModel>> _legalForMeCards = {};
  Set<String> _canChooseTrumpSeats = {};
  Map<String, int> _matchScore = {'A': 0, 'B': 0};
  int _playersConnected = 0;
  int _spectatorCount = 0;
  Map<String, dynamic>? _seatRequest;
  String _message = '';
  String? _lobbyError;
  bool _trumpModalShown = false;
  String? _lastAnnouncedWinner;
  String? _shownSeatRequestKey;

  String _botTeam = 'A';
  final _createKeyController = TextEditingController();
  final _joinKeyController = TextEditingController();

  // --- Offline state (guest, human always controls the P1+P3 partnership -
  // matching the online "vs bots" mode, which is partnership-only) ---
  static const Set<String> _humanSeats = {'P1', 'P3'};
  static const String _humanTeam = 'A';
  final _offlineQueue = OfflineResultsQueue();
  final _sessionStore = SessionStore();
  engine.RoundState? _offlineRound;
  String _offlineTrumpCallerSeat = 'P1';
  final Map<String, int> _offlineMatchScore = {'A': 0, 'B': 0};
  int _offlineWins = 0, _offlineLosses = 0;
  bool _offlineBusy = false;
  String _offlineMessage = '';

  @override
  void initState() {
    super.initState();
    _phase = widget.guestMode ? _Phase.playingOffline : _Phase.onlineLobby;
    if (widget.guestMode) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _startOfflineRound();
      });
    }
  }

  @override
  void dispose() {
    _socketSub?.cancel();
    _socket?.close();
    _createKeyController.dispose();
    _joinKeyController.dispose();
    super.dispose();
  }

  // ==================================================================
  // Online
  // ==================================================================

  void _connectOnline({required String intent, String key = '', String team = 'A'}) {
    setState(() {
      _phase = _Phase.playingOnline;
      _trumpModalShown = false;
      _lastAnnouncedWinner = null;
      _shownSeatRequestKey = null;
      _lobbyError = null;
    });
    _socket = GameSocket();
    _socket!
        .connect(
          wsPath: '/ws/court-piece',
          intent: intent,
          key: key,
          includeDifficulty: false,
          extraQuery: intent == 'bot' ? {'team': team} : null,
        )
        .then((_) {
      _socketSub = _socket!.messages.listen(_onSocketMessage);
    });
  }

  void _onSocketMessage(Map<String, dynamic> data) {
    if (!mounted) return;

    if (data['type'] == '_closed') {
      final code = data['code'] as int?;
      if (code == 4401) {
        Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => const LoginScreen()), (r) => false);
        return;
      }
      setState(() {
        _lobbyError = _closeErrors[code];
        _phase = _Phase.onlineLobby;
      });
      return;
    }

    if (data['type'] == 'player') {
      setState(() {
        _mySeats = List<String>.from(data['seats'] as List);
        _role = data['role'] as String;
        _mode = data['mode'] as String?;
        _keyLabel = (_mode == 'private' && data['key'] != null) ? 'Share this code: ${data['key']}' : null;
      });
    }

    if (data['type'] == 'state') {
      setState(() {
        _phaseOnline = data['phase'] as String?;
        _trumpSuit = data['trumpSuit'] as String?;
        _trumpCallerSeat = data['trumpCallerSeat'] as String? ?? _trumpCallerSeat;
        _currentTurnSeat = data['currentTurnSeat'] as String?;
        _currentTrick = (data['currentTrick'] as List)
            .map((e) => (
                  seat: e['seat'] as String,
                  card: engine.CardModel.fromJson(e['card'] as Map<String, dynamic>),
                ))
            .toList();
        _pendingPileTricks = data['pendingPileTricks'] as int;
        _trickWins = Map<String, int>.from(data['trickWins'] as Map);
        _tensCollected = Map<String, int>.from(data['tensCollected'] as Map);
        _lastTrickWinnerSeat = data['lastTrickWinnerSeat'] as String?;
        _winner = data['winner'] as String?;
        _handCounts = Map<String, int>.from(data['handCounts'] as Map);
        _occupied = List<String>.from(data['occupied'] as List);
        _seatNames = Map<String, String>.from(data['seatNames'] as Map);
        _myHands = (data['myHands'] as Map<String, dynamic>).map(
          (seat, cards) => MapEntry(
            seat,
            (cards as List).map((c) => engine.CardModel.fromJson(c as Map<String, dynamic>)).toList(),
          ),
        );
        final legalRaw = data['legalForMe'] as Map<String, dynamic>;
        _legalForMeCards = {
          for (final entry in legalRaw.entries)
            if (entry.value is List)
              entry.key: (entry.value as List).map((c) => engine.CardModel.fromJson(c as Map<String, dynamic>)).toList(),
        };
        _canChooseTrumpSeats = {
          for (final entry in legalRaw.entries)
            if (entry.value == 'choose_trump') entry.key,
        };
        _matchScore = Map<String, int>.from(data['matchScore'] as Map);
        _playersConnected = data['playersConnected'] as int;
        _spectatorCount = data['spectatorCount'] as int;
        _seatRequest = data['seatRequest'] as Map<String, dynamic>?;
        if (data['message'] != null && (data['message'] as String).isNotEmpty) {
          _message = data['message'] as String;
        }
      });

      _maybeShowTrumpModal();
      _maybeShowRoundOverModal();
      _maybeShowSeatRequestModal();
    }
  }

  void _maybeShowTrumpModal() {
    final iCanCallTrump = _phaseOnline == 'trump-selection' && _mySeats.any((s) => _canChooseTrumpSeats.contains(s));
    if (iCanCallTrump && !_trumpModalShown) {
      _trumpModalShown = true;
      _showTrumpModal(online: true);
    } else if (!iCanCallTrump) {
      _trumpModalShown = false;
    }
  }

  void _maybeShowRoundOverModal() {
    if (_winner != null && _winner != _lastAnnouncedWinner) {
      _lastAnnouncedWinner = _winner;
      _showRoundOverModal(online: true);
    } else if (_winner == null) {
      _lastAnnouncedWinner = null;
    }
  }

  void _maybeShowSeatRequestModal() {
    final req = _seatRequest;
    if (req == null) {
      _shownSeatRequestKey = null;
      return;
    }
    if (_role != 'player' || !_mySeats.contains(req['seat'])) return;
    final key = '${req['seat']}:${req['requesterName']}';
    if (_shownSeatRequestKey == key) return;
    _shownSeatRequestKey = key;
    _showSeatRequestModal(req);
  }

  void _leaveOnline() {
    _socketSub?.cancel();
    _socket?.close();
    setState(() {
      _phase = _Phase.onlineLobby;
      _mySeats = [];
      _keyLabel = null;
      _message = '';
      _lobbyError = null;
    });
  }

  _TableView get _onlineView => _TableView(
        seatNames: _seatNames,
        occupied: _occupied,
        currentTurnSeat: _currentTurnSeat,
        mySeats: _mySeats,
        myHands: _myHands,
        legalCardsForMe: _legalForMeCards,
        handCounts: _handCounts,
        currentTrick: _currentTrick,
        pendingPileTricks: _pendingPileTricks,
        trumpSuit: _trumpSuit,
        lastTrickWinnerSeat: _lastTrickWinnerSeat,
        trickWins: _trickWins,
        tensCollected: _tensCollected,
        matchScore: _matchScore,
      );

  // ==================================================================
  // Offline (guest, controls the P1+P3 partnership vs 2 bots - matching
  // the online "vs bots" mode, which is partnership-only)
  // ==================================================================

  void _startOfflineRound() {
    setState(() {
      _offlineRound = engine.RoundState(_offlineTrumpCallerSeat);
      engine.dealFirstFive(_offlineRound!);
      _offlineMessage = 'New round dealt. ${_offlineRound!.trumpCallerSeat} is Eldest Hand and must call trump.';
    });
    if (_humanSeats.contains(_offlineRound!.trumpCallerSeat)) {
      _showTrumpModal(online: false);
    } else {
      _maybeBotCallTrumpOffline();
    }
  }

  Future<void> _maybeBotCallTrumpOffline() async {
    final round = _offlineRound;
    if (round == null || _humanSeats.contains(round.trumpCallerSeat)) return;
    setState(() => _offlineBusy = true);
    await Future.delayed(const Duration(milliseconds: 800));
    if (!mounted) return;

    final suit = engine.chooseBotTrump(round.hands[round.trumpCallerSeat]!);
    engine.dealRemaining(round, suit);
    setState(() => _offlineMessage = 'Bot (${round.trumpCallerSeat}) called $suit as trump. Remaining cards dealt.');
    await _runOfflineBotTurns();
  }

  void _chooseTrumpOffline(String suit) {
    final round = _offlineRound!;
    engine.dealRemaining(round, suit);
    setState(() => _offlineMessage = 'You called $suit as trump. Remaining cards dealt - 13 each.');
    _runOfflineBotTurns();
  }

  Future<void> _runOfflineBotTurns() async {
    final round = _offlineRound!;
    setState(() => _offlineBusy = true);

    while (mounted && round.phase == 'playing' && !_humanSeats.contains(engine.currentTurnSeat(round))) {
      final seat = engine.currentTurnSeat(round)!;
      await Future.delayed(const Duration(milliseconds: 700));
      if (!mounted) return;

      final card = engine.chooseBotCard(round.hands[seat]!, round);
      final result = engine.playCard(round, seat, card);
      var note = 'Bot ($seat) played ${card.rank} of ${card.suit}.';

      if (result.trickCompleted) {
        final winnerSeat = result.trickWinnerSeat!;
        note += ' ${_humanSeats.contains(winnerSeat) ? "You ($winnerSeat)" : "Bot ($winnerSeat)"} won the trick.';
        if (result.collected) note += ' Team collects the pile!';
      }

      setState(() => _offlineMessage = note);

      if (result.roundCompleted) {
        await _finishOfflineRound(round.winner);
        return;
      }
    }

    if (mounted) setState(() => _offlineBusy = false);
  }

  Future<void> _playCardOffline(String seat, engine.CardModel card) async {
    final round = _offlineRound!;
    if (_offlineBusy || !_humanSeats.contains(seat) || round.phase != 'playing' || engine.currentTurnSeat(round) != seat) {
      return;
    }
    if (!engine.isLegalMove(round.hands[seat]!, round.ledSuit, card)) return;

    final result = engine.playCard(round, seat, card);
    var note = 'You ($seat) played ${card.rank} of ${card.suit}.';
    if (result.trickCompleted) {
      final winnerSeat = result.trickWinnerSeat!;
      note += ' ${_humanSeats.contains(winnerSeat) ? "You ($winnerSeat)" : "Bot ($winnerSeat)"} won the trick.';
      if (result.collected) note += ' Team collects the pile!';
    }
    setState(() => _offlineMessage = note);

    if (result.roundCompleted) {
      await _finishOfflineRound(round.winner);
      return;
    }
    await _runOfflineBotTurns();
  }

  Future<void> _finishOfflineRound(String? winnerTeam) async {
    final team = winnerTeam ?? _humanTeam;

    final email = widget.guestMode ? OfflineResultsQueue.guestEmail : await _sessionStore.getEmail();
    if (email != null) {
      await _offlineQueue.add(email, gameCourtPiece, 'medium', 'P1', team);
    }

    if (!mounted) return;
    setState(() {
      _offlineMatchScore[team] = (_offlineMatchScore[team] ?? 0) + 1;
      _offlineBusy = false;
      if (team == _humanTeam) {
        _offlineWins++;
      } else {
        _offlineLosses++;
      }
    });

    _showRoundOverModal(online: false);
  }

  void _nextOfflineRound() {
    _offlineTrumpCallerSeat = engine.nextSeat(_offlineTrumpCallerSeat);
    _startOfflineRound();
  }

  void _leaveOffline() {
    Navigator.of(context).pop();
  }

  void _goToLoginToSave() {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const LoginScreen()));
  }

  _TableView get _offlineView {
    final round = _offlineRound!;
    final turn = round.phase == 'playing' ? engine.currentTurnSeat(round) : null;
    return _TableView(
      seatNames: {for (final s in engine.seats) s: _humanSeats.contains(s) ? 'You' : 'Bot'},
      occupied: engine.seats,
      currentTurnSeat: turn,
      mySeats: _humanSeats.toList(),
      myHands: {for (final s in _humanSeats) s: round.hands[s]!},
      legalCardsForMe: {
        for (final s in _humanSeats) s: (turn == s) ? engine.legalMoves(round.hands[s]!, round.ledSuit) : [],
      },
      handCounts: {for (final s in engine.seats) s: round.hands[s]!.length},
      currentTrick: round.currentTrick,
      pendingPileTricks: round.pendingPile.length ~/ 4,
      trumpSuit: round.trumpSuit,
      lastTrickWinnerSeat: round.lastTrickInfo?.winnerSeat,
      trickWins: round.trickWins,
      tensCollected: {
        'A': engine.countTens(round.collected['A']!),
        'B': engine.countTens(round.collected['B']!),
      },
      matchScore: _offlineMatchScore,
    );
  }

  // ==================================================================
  // Shared modals
  // ==================================================================

  void _showTrumpModal({required bool online}) {
    final caller = online ? _trumpCallerSeat : _offlineRound!.trumpCallerSeat;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: Text('$caller: Choose Trump Suit'),
        content: Wrap(
          spacing: 8,
          runSpacing: 8,
          alignment: WrapAlignment.center,
          children: engine.suits.map((suit) {
            final isRedSuit = engine.redSuits.contains(suit);
            return ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: isRedSuit ? Colors.red.shade50 : null,
                foregroundColor: isRedSuit ? Colors.red.shade700 : null,
              ),
              onPressed: () {
                Navigator.of(context).pop();
                if (online) {
                  _socket!.send({'type': 'choose_trump', 'suit': suit});
                } else {
                  _chooseTrumpOffline(suit);
                }
              },
              child: Text('$suit\n${_suitNames[suit]}', textAlign: TextAlign.center),
            );
          }).toList(),
        ),
      ),
    );
  }

  void _showRoundOverModal({required bool online}) {
    final winner = online ? _winner! : _offlineRound!.winner!;
    final tensA = online ? _tensCollected['A'] : engine.countTens(_offlineRound!.collected['A']!);
    final tensB = online ? _tensCollected['B'] : engine.countTens(_offlineRound!.collected['B']!);
    final tricksA = online ? _trickWins['A'] : _offlineRound!.trickWins['A'];
    final tricksB = online ? _trickWins['B'] : _offlineRound!.trickWins['B'];
    final matchA = online ? _matchScore['A'] : _offlineMatchScore['A'];
    final matchB = online ? _matchScore['B'] : _offlineMatchScore['B'];

    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Team $winner Wins the Round!'),
        content: Text(
          '10s captured - Team A: $tensA, Team B: $tensB.\n'
          'Tricks won - Team A: $tricksA, Team B: $tricksB.\n'
          'Match score - Team A: $matchA, Team B: $matchB.',
        ),
        actions: [
          if ((online && _role == 'player') || !online)
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                if (online) {
                  _socket!.send({'type': 'next_round'});
                } else {
                  _nextOfflineRound();
                }
              },
              child: const Text('New Round'),
            ),
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Continue')),
        ],
      ),
    );
  }

  void _showSeatRequestModal(Map<String, dynamic> req) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text('Seat Request'),
        content: Text("${req['requesterName']} is requesting your seat (${req['seat']}). Give it up?"),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              _socket!.send({'type': 'respond_seat_request', 'accept': true});
            },
            child: const Text('Give up seat'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              _socket!.send({'type': 'respond_seat_request', 'accept': false});
            },
            child: const Text('Keep playing'),
          ),
        ],
      ),
    );
  }

  // ==================================================================
  // UI
  // ==================================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Court Piece'),
        actions: [
          if (!widget.guestMode)
            IconButton(
              icon: const Icon(Icons.bar_chart),
              tooltip: 'Stats',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const StatsScreen(
                    game: gameCourtPiece,
                    title: 'Court Piece Stats',
                    allGamesLabel: 'All Court Piece Games',
                  ),
                ),
              ),
            ),
        ],
      ),
      body: switch (_phase) {
        _Phase.onlineLobby => _buildOnlineLobby(),
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
          const Text('Play vs Bots', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const Text(
            'You control your partnership (2 seats) vs 2 bots.',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const SizedBox(height: 8),
          DropdownButton<String>(
            value: _botTeam,
            items: const [
              DropdownMenuItem(value: 'A', child: Text('Team A - Player 1 & Player 3')),
              DropdownMenuItem(value: 'B', child: Text('Team B - Player 2 & Player 4')),
            ],
            onChanged: (v) => setState(() => _botTeam = v!),
          ),
          const SizedBox(height: 8),
          ElevatedButton(
            onPressed: () => _connectOnline(intent: 'bot', team: _botTeam),
            child: const Text('Play vs Bots'),
          ),
          const SizedBox(height: 20),
          const Divider(),
          const Text('Join Random Game', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const Text(
            'Matched with up to 3 other players. Starts as soon as the table fills.',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const SizedBox(height: 8),
          ElevatedButton(onPressed: () => _connectOnline(intent: 'random'), child: const Text('Join Random Game')),
          const SizedBox(height: 20),
          const Divider(),
          const Text('Create a Private Game', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          TextField(
            controller: _createKeyController,
            maxLength: 5,
            decoration: const InputDecoration(labelText: 'Secret code (5 letters/numbers)'),
          ),
          ElevatedButton(
            onPressed: () {
              final key = _createKeyController.text.trim();
              if (!_keyPattern.hasMatch(key)) {
                setState(() => _lobbyError = 'Code must be exactly 5 letters/numbers.');
                return;
              }
              _connectOnline(intent: 'create', key: key);
            },
            child: const Text('Create Game'),
          ),
          const SizedBox(height: 20),
          const Divider(),
          const Text('Join a Private Game', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          TextField(
            controller: _joinKeyController,
            maxLength: 5,
            decoration: const InputDecoration(labelText: "Code your friend gave you"),
          ),
          const Text(
            'First 4 joiners play. Anyone after that spectates and can request a seat.',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const SizedBox(height: 8),
          ElevatedButton(
            onPressed: () {
              final key = _joinKeyController.text.trim();
              if (!_keyPattern.hasMatch(key)) {
                setState(() => _lobbyError = "Enter the 5-character code your friend gave you.");
                return;
              }
              _connectOnline(intent: 'join', key: key);
            },
            child: const Text('Join Game'),
          ),
          if (_lobbyError != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_lobbyError!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
        ],
      ),
    );
  }

  Widget _buildOnlineGame() {
    if (_mySeats.isEmpty && _role != 'spectator') {
      return const Center(child: CircularProgressIndicator());
    }
    final view = _onlineView;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Text(
            _role == 'spectator' ? 'You are spectating' : 'You are: ${_mySeats.join(' & ')}',
            style: const TextStyle(fontSize: 12),
          ),
          if (_keyLabel != null) Text(_keyLabel!, style: const TextStyle(fontSize: 12)),
          if (_message.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 6),
              child: Text(_message, style: const TextStyle(fontSize: 12, color: Colors.grey), textAlign: TextAlign.center),
            ),
          _buildInfoPanel(view),
          const SizedBox(height: 8),
          if (_seatRequest != null && !(_role == 'player' && _mySeats.contains(_seatRequest!['seat'])))
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                "${_seatRequest!['requesterName']} is requesting ${_seatRequest!['seat']}'s seat...",
                style: const TextStyle(fontStyle: FontStyle.italic, fontSize: 12),
              ),
            ),
          if (_role == 'spectator') _buildSpectatorPanel(),
          _buildTable(view, (seat, card) {
            if (!_mySeats.contains(seat) || _currentTurnSeat != seat) return;
            _socket!.send({'type': 'play_card', 'card': card.toJson()});
          }),
          const SizedBox(height: 8),
          Text('Players: $_playersConnected   Spectators: $_spectatorCount', style: const TextStyle(fontSize: 11)),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (_role == 'player')
                OutlinedButton(
                  onPressed: () => _socket!.send({'type': 'leave_table'}),
                  child: const Text('Leave Table'),
                ),
              const SizedBox(width: 12),
              ElevatedButton(onPressed: _leaveOnline, child: const Text('Leave Game')),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSpectatorPanel() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(border: Border.all(color: Theme.of(context).dividerColor), borderRadius: BorderRadius.circular(10)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Spectator count: $_spectatorCount', style: const TextStyle(fontSize: 12)),
          const SizedBox(height: 8),
          const Text('Request a seat:', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _occupied.map((seat) {
              final already = _seatRequest != null && _seatRequest!['seat'] == seat;
              return ElevatedButton(
                onPressed: _seatRequest != null ? null : () => _socket!.send({'type': 'request_seat', 'seat': seat}),
                child: Text(already ? '$seat (requested...)' : 'Request $seat'),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildOfflineGame() {
    if (_offlineRound == null) return const Center(child: CircularProgressIndicator());
    final view = _offlineView;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          if (widget.guestMode)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text('Guest mode', style: TextStyle(fontSize: 12, color: Colors.grey)),
                  const SizedBox(width: 6),
                  TextButton(
                    onPressed: _goToLoginToSave,
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text('Log In to Save', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ),
          if (_offlineMessage.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(_offlineMessage, style: const TextStyle(fontSize: 12, color: Colors.grey), textAlign: TextAlign.center),
            ),
          _buildInfoPanel(view),
          const SizedBox(height: 8),
          _buildTable(view, (seat, card) => _playCardOffline(seat, card)),
          const SizedBox(height: 12),
          Text('Wins: $_offlineWins   Losses: $_offlineLosses', style: const TextStyle(fontSize: 12)),
          const SizedBox(height: 8),
          ElevatedButton(onPressed: _leaveOffline, child: const Text('Leave Game')),
        ],
      ),
    );
  }

  Widget _buildInfoPanel(_TableView v) {
    final trumpLabel = v.trumpSuit != null ? '${v.trumpSuit} Trump' : 'Trump: -';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            flex: 2,
            child: Text(trumpLabel, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
          ),
          Text('A: ${v.tensCollected['A']}t/${v.trickWins['A']}trk', style: const TextStyle(fontSize: 11)),
          const SizedBox(width: 6),
          Text('B: ${v.tensCollected['B']}t/${v.trickWins['B']}trk', style: const TextStyle(fontSize: 11)),
          const SizedBox(width: 6),
          Text(
            '${v.matchScore['A']}-${v.matchScore['B']}',
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildTable(_TableView v, void Function(String seat, engine.CardModel card) onPlayCard) {
    return Column(
      children: [
        _buildSeatColumn('P3', v, onPlayCard, CrossAxisAlignment.center),
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(child: _buildSeatColumn('P2', v, onPlayCard, CrossAxisAlignment.start)),
            _buildCenterPile(v),
            Expanded(child: _buildSeatColumn('P4', v, onPlayCard, CrossAxisAlignment.end)),
          ],
        ),
        const SizedBox(height: 8),
        _buildSeatColumn('P1', v, onPlayCard, CrossAxisAlignment.center),
      ],
    );
  }

  Widget _buildSeatColumn(
    String seat,
    _TableView v,
    void Function(String, engine.CardModel) onPlayCard,
    CrossAxisAlignment alignment,
  ) {
    final isMine = v.mySeats.contains(seat);
    final isMyTurn = v.currentTurnSeat == seat;
    final label = v.occupied.contains(seat) ? (v.seatNames[seat] ?? seat) : 'Waiting...';
    final roleTag = v.occupied.contains(seat) ? (isMine ? '[YOU]' : '[PLAYER]') : '';

    return Column(
      crossAxisAlignment: alignment,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: isMyTurn
              ? BoxDecoration(
                  color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                )
              : null,
          child: Text(
            '$label $roleTag\n$seat (${_seatPosition[seat]}) - Team ${engine.teamOf[seat]}',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, fontWeight: isMyTurn ? FontWeight.bold : FontWeight.normal),
          ),
        ),
        const SizedBox(height: 4),
        _buildHand(seat, v, onPlayCard),
      ],
    );
  }

  Widget _buildHand(String seat, _TableView v, void Function(String, engine.CardModel) onPlayCard) {
    if (v.mySeats.contains(seat) && v.myHands[seat] != null) {
      final hand = v.myHands[seat]!;
      final legal = v.legalCardsForMe[seat] ?? [];
      return SizedBox(
        height: 64,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: hand.map((card) {
              final isLegal = legal.any((c) => c.key == card.key);
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: _buildCard(card, faceUp: true, clickable: isLegal ? () => onPlayCard(seat, card) : null),
              );
            }).toList(),
          ),
        ),
      );
    }
    final count = v.handCounts[seat] ?? 0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text('🂠 x$count', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
    );
  }

  /// Each seat's played card sits in a fixed compass slot (P3 top, P2 left,
  /// P4 right, P1 bottom) matching that seat's position at the table -
  /// never reordered by play order, so the pile doesn't visibly "jump"
  /// depending on who happened to lead the trick.
  Widget _buildCenterPile(_TableView v) {
    if (v.currentTrick.isEmpty) {
      final n = v.pendingPileTricks.clamp(0, 6);
      return SizedBox(
        width: 74,
        child: Wrap(
          alignment: WrapAlignment.center,
          children: List.generate(n, (i) => const Padding(padding: EdgeInsets.all(1), child: _CardBack(mini: true))),
        ),
      );
    }

    final bySeat = {for (final p in v.currentTrick) p.seat: p.card};
    Widget slot(String seat) {
      final card = bySeat[seat];
      return SizedBox(
        width: 26,
        height: 34,
        child: card != null ? _buildCard(card, faceUp: true, mini: true) : null,
      );
    }

    return SizedBox(
      width: 74,
      height: 96,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned(top: 0, child: slot('P3')),
          Positioned(left: 0, child: slot('P2')),
          Positioned(right: 0, child: slot('P4')),
          Positioned(bottom: 0, child: slot('P1')),
        ],
      ),
    );
  }

  Widget _buildCard(engine.CardModel card, {required bool faceUp, VoidCallback? clickable, bool mini = false}) {
    if (!faceUp) return _CardBack(mini: mini);

    final w = mini ? 24.0 : 42.0;
    final h = mini ? 32.0 : 58.0;
    final color = card.color == 'red' ? Colors.red.shade700 : Colors.black87;

    return GestureDetector(
      onTap: clickable,
      child: Container(
        width: w,
        height: h,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color: clickable != null ? Theme.of(context).colorScheme.primary : Colors.black26,
            width: clickable != null ? 2 : 1,
          ),
          boxShadow: clickable != null
              ? [BoxShadow(color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.4), blurRadius: 4)]
              : null,
        ),
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(card.rank, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: mini ? 9 : 13)),
            Text(card.suit, style: TextStyle(color: color, fontSize: mini ? 10 : 16)),
          ],
        ),
      ),
    );
  }
}

class _CardBack extends StatelessWidget {
  final bool mini;
  const _CardBack({this.mini = false});

  @override
  Widget build(BuildContext context) {
    final w = mini ? 24.0 : 42.0;
    final h = mini ? 32.0 : 58.0;
    return Container(
      width: w,
      height: h,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primary,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Colors.black26),
      ),
    );
  }
}
