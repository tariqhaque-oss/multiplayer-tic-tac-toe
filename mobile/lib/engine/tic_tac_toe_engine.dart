// Pure Dart port of backend/game.py's rules and bot AI, so bot games can be
// played fully offline. Mirrors the Python version's behavior exactly,
// including the three difficulty tiers.
import 'dart:math';

const List<List<int>> winningCombinations = [
  [0, 1, 2], [3, 4, 5], [6, 7, 8],
  [0, 3, 6], [1, 4, 7], [2, 5, 8],
  [0, 4, 8], [2, 4, 6],
];

/// Returns "X", "O", "Draw", or null (game still in progress).
String? checkWinner(List<String> board) {
  for (final combo in winningCombinations) {
    final a = board[combo[0]], b = board[combo[1]], c = board[combo[2]];
    if (a.isNotEmpty && a == b && b == c) {
      return a;
    }
  }
  if (!board.contains("")) {
    return "Draw";
  }
  return null;
}

List<int> emptyCells(List<String> board) {
  final cells = <int>[];
  for (var i = 0; i < board.length; i++) {
    if (board[i].isEmpty) cells.add(i);
  }
  return cells;
}

int? winningMoveFor(List<String> board, String symbol) {
  for (final i in emptyCells(board)) {
    board[i] = symbol;
    final isWinner = checkWinner(board) == symbol;
    board[i] = "";
    if (isWinner) return i;
  }
  return null;
}

int minimax(List<String> board, String player, String botSymbol, String humanSymbol) {
  final winner = checkWinner(board);
  if (winner == botSymbol) return 1;
  if (winner == humanSymbol) return -1;
  if (winner == "Draw") return 0;

  final nextPlayer = player == botSymbol ? humanSymbol : botSymbol;
  final scores = <int>[];
  for (final i in emptyCells(board)) {
    board[i] = player;
    scores.add(minimax(board, nextPlayer, botSymbol, humanSymbol));
    board[i] = "";
  }

  return player == botSymbol
      ? scores.reduce(max)
      : scores.reduce(min);
}

int bestMove(List<String> board, String botSymbol, String humanSymbol) {
  int? bestScore;
  int bestIndex = emptyCells(board).first;
  for (final i in emptyCells(board)) {
    board[i] = botSymbol;
    final score = minimax(board, humanSymbol, botSymbol, humanSymbol);
    board[i] = "";
    if (bestScore == null || score > bestScore) {
      bestScore = score;
      bestIndex = i;
    }
  }
  return bestIndex;
}

final _random = Random();

int chooseBotMove(List<String> board, String botSymbol, String humanSymbol, String difficulty) {
  if (difficulty == "easy") {
    final cells = emptyCells(board);
    return cells[_random.nextInt(cells.length)];
  }

  if (difficulty == "medium") {
    int? move = winningMoveFor(board, botSymbol);
    move ??= winningMoveFor(board, humanSymbol);
    if (move == null) {
      final cells = emptyCells(board);
      move = cells[_random.nextInt(cells.length)];
    }
    return move;
  }

  return bestMove(board, botSymbol, humanSymbol);
}
