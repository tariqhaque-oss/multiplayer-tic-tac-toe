// Pure Dart port of backend/ludo.py's rules and bot AI, so bot practice
// games can be played fully offline. Mirrors the Python version exactly.
import 'dart:math';

const List<String> colors = ['R', 'G', 'Y', 'B'];
const Map<String, String> colorNames = {'R': 'Red', 'G': 'Green', 'Y': 'Yellow', 'B': 'Blue'};
const Map<String, int> entryOffset = {'R': 0, 'G': 13, 'Y': 26, 'B': 39};
// Safe cells ("rest stops"): the 4 start squares plus the 4 star cells 8
// steps into each arm (standard board layout) - no capturing on any of these.
const Set<int> safeCells = {0, 13, 26, 39, 8, 21, 34, 47};
const int trackFinish = 56; // per token: -1 (yard), 0-50 (shared path), 51-56 (home stretch, 56 = home)

// ---------------------------------------------------------------------
// Board geometry - ported 1:1 from frontend/static/js/ludo.js so the
// mobile board matches the website's layout exactly. All coordinates
// are (row, col) on a 15x15 grid.
// ---------------------------------------------------------------------

typedef Cell = (int row, int col);

const List<Cell> path = [
  (6, 1), (6, 2), (6, 3), (6, 4), (6, 5),
  (5, 6), (4, 6), (3, 6), (2, 6), (1, 6), (0, 6),
  (0, 7),
  (0, 8), (1, 8), (2, 8), (3, 8), (4, 8), (5, 8),
  (6, 9), (6, 10), (6, 11), (6, 12), (6, 13), (6, 14),
  (7, 14),
  (8, 14), (8, 13), (8, 12), (8, 11), (8, 10), (8, 9),
  (9, 8), (10, 8), (11, 8), (12, 8), (13, 8), (14, 8),
  (14, 7),
  (14, 6), (13, 6), (12, 6), (11, 6), (10, 6), (9, 6),
  (8, 5), (8, 4), (8, 3), (8, 2), (8, 1), (8, 0),
  (7, 0),
  (6, 0),
];

const Map<String, int> startIndex = {'R': 0, 'G': 13, 'Y': 26, 'B': 39};
const List<int> starIndices = [8, 21, 34, 47];

const Map<String, List<Cell>> home = {
  'R': [(7, 1), (7, 2), (7, 3), (7, 4), (7, 5), (7, 6)],
  'G': [(1, 7), (2, 7), (3, 7), (4, 7), (5, 7), (6, 7)],
  'Y': [(7, 13), (7, 12), (7, 11), (7, 10), (7, 9), (7, 8)],
  'B': [(13, 7), (12, 7), (11, 7), (10, 7), (9, 7), (8, 7)],
};

const Map<String, List<Cell>> yardSlots = {
  'R': [(1, 1), (1, 4), (4, 1), (4, 4)],
  'G': [(1, 10), (1, 13), (4, 10), (4, 13)],
  'Y': [(10, 10), (10, 13), (13, 10), (13, 13)],
  'B': [(10, 1), (10, 4), (13, 1), (13, 4)],
};

List<Cell> _cellsInRect(int r0, int r1, int c0, int c1) {
  final out = <Cell>[];
  for (var r = r0; r <= r1; r++) {
    for (var c = c0; c <= c1; c++) {
      out.add((r, c));
    }
  }
  return out;
}

final Map<String, List<Cell>> yardCells = {
  'R': _cellsInRect(0, 5, 0, 5),
  'G': _cellsInRect(0, 5, 9, 14),
  'Y': _cellsInRect(9, 14, 9, 14),
  'B': _cellsInRect(9, 14, 0, 5),
};

/// The board cell a token sits on, given its logical position (-1 = yard
/// slot, 0-50 = shared path, 51-56 = home stretch).
Cell globalCellFor(String color, int pos, int tokenIndex) {
  if (pos == -1) return yardSlots[color]![tokenIndex];
  if (pos <= 50) return path[(startIndex[color]! + pos) % 52];
  return home[color]![pos - 51];
}

Map<String, List<int>> newTokens() => {for (final c in colors) c: [-1, -1, -1, -1]};

String? nextColor(List<String> occupied, String after) {
  if (occupied.isEmpty) return null;
  if (!occupied.contains(after)) return occupied.first;
  final i = occupied.indexOf(after);
  return occupied[(i + 1) % occupied.length];
}

int globalCell(String color, int pos) => (entryOffset[color]! + pos) % 52;

List<int> legalMoves(List<int> tokens, int roll) {
  final moves = <int>[];
  for (var i = 0; i < tokens.length; i++) {
    final pos = tokens[i];
    if (pos == -1) {
      if (roll == 6) moves.add(i);
    } else if (pos + roll <= trackFinish) {
      moves.add(i);
    }
  }
  return moves;
}

bool wouldCapture(Map<String, List<int>> tokens, String color, int newPos) {
  if (newPos > 50) return false;
  final cell = globalCell(color, newPos);
  if (safeCells.contains(cell)) return false;
  for (final other in colors) {
    if (other == color) continue;
    for (final p in tokens[other]!) {
      if (p >= 0 && p <= 50 && globalCell(other, p) == cell) return true;
    }
  }
  return false;
}

/// Returns (finished, captured).
({bool finished, bool captured}) applyMove(
  Map<String, List<int>> tokens,
  String color,
  int tokenIndex,
  int roll,
) {
  final list = tokens[color]!;
  final pos = list[tokenIndex];
  final newPos = pos == -1 ? 0 : pos + roll;
  list[tokenIndex] = newPos;

  var captured = false;
  if (newPos <= 50) {
    final cell = globalCell(color, newPos);
    if (!safeCells.contains(cell)) {
      for (final other in colors) {
        if (other == color) continue;
        final otherList = tokens[other]!;
        for (var i = 0; i < otherList.length; i++) {
          final p = otherList[i];
          if (p >= 0 && p <= 50 && globalCell(other, p) == cell) {
            otherList[i] = -1;
            captured = true;
          }
        }
      }
    }
  }

  final finished = list.every((p) => p == trackFinish);
  return (finished: finished, captured: captured);
}

final _random = Random();

int? chooseBotMove(Map<String, List<int>> tokens, String color, int roll, String difficulty) {
  final moves = legalMoves(tokens[color]!, roll);
  if (moves.isEmpty) return null;

  if (difficulty == 'easy') {
    return moves[_random.nextInt(moves.length)];
  }

  int newPosFor(int i) {
    final pos = tokens[color]![i];
    return pos == -1 ? 0 : pos + roll;
  }

  num score(int i) {
    final pos = tokens[color]![i];
    final newPos = newPosFor(i);
    num value = newPos;
    if (wouldCapture(tokens, color, newPos)) value += 50;
    if (pos == -1) value += 10;
    if (newPos == trackFinish) value += 40;
    if (difficulty == 'hard' && newPos <= 50 && !safeCells.contains(globalCell(color, newPos))) {
      value -= 5;
    }
    return value;
  }

  int best = moves.first;
  num bestScore = score(best);
  for (final m in moves.skip(1)) {
    final s = score(m);
    if (s > bestScore) {
      bestScore = s;
      best = m;
    }
  }
  return best;
}
