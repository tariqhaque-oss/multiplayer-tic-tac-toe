// Pure Dart port of backend/connect4.py's rules and bot AI, so bot games
// can be played fully offline. Mirrors the Python version exactly,
// including the minimax+heuristic "hard" bot.
import 'dart:math';

const int rows = 6;
const int cols = 7;

int cellIndex(int row, int col) => row * cols + col;

List<String> newBoard() => List.filled(rows * cols, '');

List<int> validColumns(List<String> board) {
  final result = <int>[];
  for (var c = 0; c < cols; c++) {
    if (board[cellIndex(0, c)].isEmpty) result.add(c);
  }
  return result;
}

/// Returns the row a piece would land on in this column, or null if full.
int? dropRow(List<String> board, int col) {
  for (var r = rows - 1; r >= 0; r--) {
    if (board[cellIndex(r, col)].isEmpty) return r;
  }
  return null;
}

/// Returns "R", "Y", "Draw", or null (game still in progress).
String? checkWinner(List<String> board) {
  for (var r = 0; r < rows; r++) {
    for (var c = 0; c < cols; c++) {
      final symbol = board[cellIndex(r, c)];
      if (symbol.isEmpty) continue;

      if (c + 3 < cols && List.generate(4, (i) => board[cellIndex(r, c + i)]).every((s) => s == symbol)) {
        return symbol;
      }
      if (r + 3 < rows && List.generate(4, (i) => board[cellIndex(r + i, c)]).every((s) => s == symbol)) {
        return symbol;
      }
      if (r + 3 < rows &&
          c + 3 < cols &&
          List.generate(4, (i) => board[cellIndex(r + i, c + i)]).every((s) => s == symbol)) {
        return symbol;
      }
      if (r + 3 < rows &&
          c - 3 >= 0 &&
          List.generate(4, (i) => board[cellIndex(r + i, c - i)]).every((s) => s == symbol)) {
        return symbol;
      }
    }
  }

  if (!board.contains('')) return 'Draw';
  return null;
}

int? winningMoveFor(List<String> board, String symbol) {
  for (final c in validColumns(board)) {
    final row = dropRow(board, c)!;
    board[cellIndex(row, c)] = symbol;
    final isWinner = checkWinner(board) == symbol;
    board[cellIndex(row, c)] = '';
    if (isWinner) return c;
  }
  return null;
}

int _scoreWindow(List<String> window, String symbol, String opponent) {
  var score = 0;
  final symbolCount = window.where((s) => s == symbol).length;
  final emptyCount = window.where((s) => s.isEmpty).length;
  final opponentCount = window.where((s) => s == opponent).length;

  if (symbolCount == 4) {
    score += 100;
  } else if (symbolCount == 3 && emptyCount == 1) {
    score += 5;
  } else if (symbolCount == 2 && emptyCount == 2) {
    score += 2;
  }

  if (opponentCount == 3 && emptyCount == 1) {
    score -= 4;
  }

  return score;
}

int _evaluate(List<String> board, String symbol, String opponent) {
  var score = 0;

  const centerCol = cols ~/ 2;
  final centerCells = List.generate(rows, (r) => board[cellIndex(r, centerCol)]);
  score += centerCells.where((s) => s == symbol).length * 3;

  for (var r = 0; r < rows; r++) {
    final rowCells = List.generate(cols, (c) => board[cellIndex(r, c)]);
    for (var c = 0; c <= cols - 4; c++) {
      score += _scoreWindow(rowCells.sublist(c, c + 4), symbol, opponent);
    }
  }

  for (var c = 0; c < cols; c++) {
    final colCells = List.generate(rows, (r) => board[cellIndex(r, c)]);
    for (var r = 0; r <= rows - 4; r++) {
      score += _scoreWindow(colCells.sublist(r, r + 4), symbol, opponent);
    }
  }

  for (var r = 0; r <= rows - 4; r++) {
    for (var c = 0; c <= cols - 4; c++) {
      final window = List.generate(4, (i) => board[cellIndex(r + i, c + i)]);
      score += _scoreWindow(window, symbol, opponent);
    }
  }

  for (var r = 0; r <= rows - 4; r++) {
    for (var c = 3; c < cols; c++) {
      final window = List.generate(4, (i) => board[cellIndex(r + i, c - i)]);
      score += _scoreWindow(window, symbol, opponent);
    }
  }

  return score;
}

final _random = Random();

class _MinimaxResult {
  final int? col;
  final num score;
  _MinimaxResult(this.col, this.score);
}

_MinimaxResult _minimax(
  List<String> board,
  int depth,
  num alpha,
  num beta,
  bool maximizing,
  String botSymbol,
  String humanSymbol,
) {
  final winner = checkWinner(board);
  if (winner == botSymbol) return _MinimaxResult(null, 10000000);
  if (winner == humanSymbol) return _MinimaxResult(null, -10000000);
  if (winner == 'Draw') return _MinimaxResult(null, 0);
  if (depth == 0) return _MinimaxResult(null, _evaluate(board, botSymbol, humanSymbol));

  final columns = validColumns(board);
  final player = maximizing ? botSymbol : humanSymbol;
  int bestCol = columns[_random.nextInt(columns.length)];
  num value = maximizing ? double.negativeInfinity : double.infinity;

  for (final c in columns) {
    final row = dropRow(board, c)!;
    board[cellIndex(row, c)] = player;
    final result = _minimax(board, depth - 1, alpha, beta, !maximizing, botSymbol, humanSymbol);
    board[cellIndex(row, c)] = '';

    if (maximizing) {
      if (result.score > value) {
        value = result.score;
        bestCol = c;
      }
      alpha = max(alpha, value);
    } else {
      if (result.score < value) {
        value = result.score;
        bestCol = c;
      }
      beta = min(beta, value);
    }

    if (alpha >= beta) break;
  }

  return _MinimaxResult(bestCol, value);
}

int bestMove(List<String> board, String botSymbol, String humanSymbol, {int depth = 5}) {
  final result = _minimax(board, depth, double.negativeInfinity, double.infinity, true, botSymbol, humanSymbol);
  return result.col!;
}

int chooseBotMove(List<String> board, String botSymbol, String humanSymbol, String difficulty) {
  final columns = validColumns(board);

  if (difficulty == 'easy') {
    return columns[_random.nextInt(columns.length)];
  }

  if (difficulty == 'medium') {
    int? move = winningMoveFor(board, botSymbol);
    move ??= winningMoveFor(board, humanSymbol);
    move ??= columns[_random.nextInt(columns.length)];
    return move;
  }

  return bestMove(board, botSymbol, humanSymbol);
}
