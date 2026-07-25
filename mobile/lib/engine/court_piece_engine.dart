import 'dart:math';

/// Pure Dart port of backend/court_piece.py's round state machine and bot
/// AI - used only for offline guest play. Online play never runs this; the
/// server is authoritative there and this file's logic must stay in sync
/// with court_piece.py by hand.
const List<String> suits = ['♠', '♥', '♦', '♣'];
const Set<String> redSuits = {'♥', '♦'};
const List<String> ranks = ['2', '3', '4', '5', '6', '7', '8', '9', '10', 'J', 'Q', 'K', 'A'];
const Map<String, int> rankValue = {
  '2': 2, '3': 3, '4': 4, '5': 5, '6': 6, '7': 7, '8': 8, '9': 9, '10': 10,
  'J': 11, 'Q': 12, 'K': 13, 'A': 14,
};

const List<String> seats = ['P1', 'P2', 'P3', 'P4'];
const Map<String, String> teamOf = {'P1': 'A', 'P3': 'A', 'P2': 'B', 'P4': 'B'};
const Map<String, String> partnerOf = {'P1': 'P3', 'P3': 'P1', 'P2': 'P4', 'P4': 'P2'};

class CardModel {
  final String suit;
  final String rank;
  final int value;
  final String color;

  const CardModel({required this.suit, required this.rank, required this.value, required this.color});

  String get key => '$suit$rank';

  factory CardModel.fromJson(Map<String, dynamic> json) => CardModel(
        suit: json['suit'] as String,
        rank: json['rank'].toString(),
        value: json['value'] as int,
        color: json['color'] as String,
      );

  Map<String, dynamic> toJson() => {'suit': suit, 'rank': rank, 'value': value, 'color': color};
}

bool isRed(String suit) => redSuits.contains(suit);

List<CardModel> buildDeck() {
  final deck = <CardModel>[];
  for (final suit in suits) {
    for (final rank in ranks) {
      deck.add(CardModel(suit: suit, rank: rank, value: rankValue[rank]!, color: isRed(suit) ? 'red' : 'black'));
    }
  }
  return deck;
}

List<CardModel> shuffleDeck() {
  final deck = buildDeck();
  deck.shuffle(Random());
  return deck;
}

String nextSeat(String seat) => seats[(seats.indexOf(seat) + 1) % 4];

typedef TrickPlay = ({String seat, CardModel card});
typedef PlayResult = ({bool trickCompleted, bool roundCompleted, String? trickWinnerSeat, bool collected});

class RoundState {
  String phase;
  List<CardModel> deck;
  Map<String, List<CardModel>> hands;
  String trumpCallerSeat;
  String? trumpSuit;
  String? leader;
  List<TrickPlay> currentTrick;
  String? ledSuit;
  int tricksPlayed;
  Map<String, int> trickWins;
  String? lastTrickWinnerSeat;
  List<TrickPlay> pendingPile;
  Map<String, List<CardModel>> collected;
  ({String winnerSeat, int cardsCount})? lastTrickInfo;
  String? winner;

  RoundState(this.trumpCallerSeat)
      : phase = 'dealing-first-five',
        deck = shuffleDeck(),
        hands = {'P1': [], 'P2': [], 'P3': [], 'P4': []},
        trumpSuit = null,
        leader = null,
        currentTrick = [],
        ledSuit = null,
        tricksPlayed = 0,
        trickWins = {'A': 0, 'B': 0},
        lastTrickWinnerSeat = null,
        pendingPile = [],
        collected = {'A': [], 'B': []},
        lastTrickInfo = null,
        winner = null;
}

void dealFirstFive(RoundState state) {
  for (final seat in seats) {
    state.hands[seat] = state.deck.sublist(0, 5);
    state.deck = state.deck.sublist(5);
  }
  state.phase = 'trump-selection';
}

String chooseBotTrump(List<CardModel> hand) {
  final counts = {for (final s in suits) s: 0};
  for (final card in hand) {
    counts[card.suit] = counts[card.suit]! + 1;
  }
  var best = suits.first;
  for (final s in suits) {
    if (counts[s]! > counts[best]!) best = s;
  }
  return best;
}

void dealRemaining(RoundState state, String trumpSuit) {
  state.trumpSuit = trumpSuit;
  for (final seat in seats) {
    state.hands[seat] = [...state.hands[seat]!, ...state.deck.sublist(0, 8)];
    state.deck = state.deck.sublist(8);
  }
  state.deck = [];
  state.phase = 'playing';
  state.leader = state.trumpCallerSeat;
}

List<CardModel> legalMoves(List<CardModel> hand, String? ledSuit) {
  if (ledSuit == null) return List.of(hand);
  final following = hand.where((c) => c.suit == ledSuit).toList();
  return following.isNotEmpty ? following : List.of(hand);
}

bool isLegalMove(List<CardModel> hand, String? ledSuit, CardModel card) {
  return legalMoves(hand, ledSuit).any((c) => c.key == card.key);
}

String resolveTrick(List<TrickPlay> trick, String? ledSuit, String? trumpSuit) {
  final trumpPlays = trick.where((t) => t.card.suit == trumpSuit).toList();
  final pool = trumpPlays.isNotEmpty ? trumpPlays : trick.where((t) => t.card.suit == ledSuit).toList();
  var best = pool.first;
  for (final play in pool) {
    if (play.card.value > best.card.value) best = play;
  }
  return best.seat;
}

String? currentTurnSeat(RoundState state) {
  if (state.currentTrick.isEmpty) return state.leader;
  return nextSeat(state.currentTrick.last.seat);
}

void removeFromHand(List<CardModel> hand, CardModel card) {
  final idx = hand.indexWhere((c) => c.key == card.key);
  hand.removeAt(idx);
}

int countTens(List<CardModel> cards) => cards.where((c) => c.rank == '10').length;

String? computeRoundWinner(RoundState state) {
  final tensA = countTens(state.collected['A']!);
  final tensB = countTens(state.collected['B']!);
  if (tensA >= 3) return 'A';
  if (tensB >= 3) return 'B';
  if (state.trickWins['A']! > state.trickWins['B']!) return 'A';
  if (state.trickWins['B']! > state.trickWins['A']!) return 'B';
  return null;
}

PlayResult playCard(RoundState state, String seat, CardModel card) {
  final hand = state.hands[seat]!;
  if (!isLegalMove(hand, state.ledSuit, card)) {
    throw StateError('illegal move: must follow suit if possible');
  }

  removeFromHand(hand, card);
  state.currentTrick = [...state.currentTrick, (seat: seat, card: card)];
  if (state.currentTrick.length == 1) {
    state.ledSuit = card.suit;
  }

  var trickCompleted = false, roundCompleted = false, collected = false;
  String? trickWinnerSeat;

  if (state.currentTrick.length == 4) {
    final winnerSeat = resolveTrick(state.currentTrick, state.ledSuit, state.trumpSuit);
    state.tricksPlayed++;
    state.trickWins[teamOf[winnerSeat]!] = state.trickWins[teamOf[winnerSeat]!]! + 1;
    state.pendingPile = [...state.pendingPile, ...state.currentTrick];

    final isFinalTrick = state.tricksPlayed == 13;
    final doubleWin = winnerSeat == state.lastTrickWinnerSeat;

    if (doubleWin || isFinalTrick) {
      final team = teamOf[winnerSeat]!;
      state.collected[team] = [...state.collected[team]!, ...state.pendingPile.map((p) => p.card)];
      state.pendingPile = [];
      collected = true;
    }

    state.lastTrickInfo = (winnerSeat: winnerSeat, cardsCount: state.currentTrick.length);
    state.lastTrickWinnerSeat = winnerSeat;
    state.currentTrick = [];
    state.ledSuit = null;
    state.leader = winnerSeat;

    trickCompleted = true;
    trickWinnerSeat = winnerSeat;

    if (isFinalTrick) {
      state.phase = 'round-over';
      state.winner = computeRoundWinner(state);
      roundCompleted = true;
    }
  }

  return (
    trickCompleted: trickCompleted,
    roundCompleted: roundCompleted,
    trickWinnerSeat: trickWinnerSeat,
    collected: collected,
  );
}

CardModel chooseBotCard(List<CardModel> hand, RoundState state) {
  final ledSuit = state.ledSuit;
  final trumpSuit = state.trumpSuit;
  final moves = legalMoves(hand, ledSuit);

  if (ledSuit != null) {
    final followingSuit = moves.where((c) => c.suit == ledSuit).toList();
    if (followingSuit.isNotEmpty) {
      var best = followingSuit.first;
      for (final c in followingSuit) {
        if (c.value > best.value) best = c;
      }
      return best;
    }
  }

  final seat = state.currentTrick.isEmpty ? state.leader! : nextSeat(state.currentTrick.last.seat);
  final partnerSeat = partnerOf[seat]!;
  final partnerIsWinning =
      state.currentTrick.isNotEmpty && resolveTrick(state.currentTrick, state.ledSuit, trumpSuit) == partnerSeat;

  if (ledSuit == null) {
    final nonTrump = hand.where((c) => c.suit != trumpSuit).toList();
    final pool = nonTrump.isNotEmpty ? nonTrump : hand;
    var best = pool.first;
    for (final c in pool) {
      if (c.value > best.value) best = c;
    }
    return best;
  }

  final trumpsInHand = hand.where((c) => c.suit == trumpSuit).toList();
  final trumpAlreadyPlayed = state.currentTrick.any((t) => t.card.suit == trumpSuit);

  if (trumpsInHand.isNotEmpty && !partnerIsWinning) {
    if (!trumpAlreadyPlayed) {
      var lowest = trumpsInHand.first;
      for (final c in trumpsInHand) {
        if (c.value < lowest.value) lowest = c;
      }
      return lowest;
    }
    final highestTrumpInTrick =
        state.currentTrick.where((t) => t.card.suit == trumpSuit).map((t) => t.card.value).reduce(max);
    final winningTrumps = trumpsInHand.where((c) => c.value > highestTrumpInTrick).toList();
    if (winningTrumps.isNotEmpty) {
      var lowest = winningTrumps.first;
      for (final c in winningTrumps) {
        if (c.value < lowest.value) lowest = c;
      }
      return lowest;
    }
  }

  var lowest = hand.first;
  for (final c in hand) {
    if (c.value < lowest.value) lowest = c;
  }
  return lowest;
}
