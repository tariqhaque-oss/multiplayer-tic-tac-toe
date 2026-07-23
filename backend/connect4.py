import json
import math
import random
import asyncio
import secrets

from fastapi import APIRouter, WebSocket, WebSocketDisconnect

from config import KEY_RE, BOT_DIFFICULTIES, BOT_EMAILS, SESSION_COOKIE
from db import db_execute
from security import read_session_cookie

router = APIRouter()

ROWS = 6
COLS = 7

games = {}  # key -> game state dict, at most 2 connections each, separate from tic-tac-toe's `games`

_bot_user_id_cache = {}


def get_bot_user_id(difficulty):
    if difficulty not in _bot_user_id_cache:
        row = db_execute("SELECT id FROM users WHERE email = %s", (BOT_EMAILS[difficulty],), fetch="one")
        _bot_user_id_cache[difficulty] = row[0]
    return _bot_user_id_cache[difficulty]


def cell_index(row, col):
    return row * COLS + col


def new_board():
    return [""] * (ROWS * COLS)


def valid_columns(board):
    return [c for c in range(COLS) if board[cell_index(0, c)] == ""]


def drop_row(board, col):
    for r in range(ROWS - 1, -1, -1):
        if board[cell_index(r, col)] == "":
            return r
    return None


def new_game_state(mode, difficulty=None, bot_user_id=None):
    return {
        "mode": mode,
        "difficulty": difficulty,
        "bot_user_id": bot_user_id,
        "board": new_board(),
        "current_player": "R",
        "scores": {"R": 0, "Y": 0, "Draw": 0},
        "connections": {},  # websocket -> {"symbol": "R"/"Y", "display_name": str, "user_id": int}
    }


def find_or_create_random_game():
    for key, game in games.items():
        if game["mode"] == "random" and len(game["connections"]) == 1:
            return key

    key = "random-" + secrets.token_urlsafe(6)
    games[key] = new_game_state("random")
    return key


def check_winner(board):
    for r in range(ROWS):
        for c in range(COLS):
            symbol = board[cell_index(r, c)]
            if not symbol:
                continue

            if c + 3 < COLS and all(board[cell_index(r, c + i)] == symbol for i in range(4)):
                return symbol
            if r + 3 < ROWS and all(board[cell_index(r + i, c)] == symbol for i in range(4)):
                return symbol
            if r + 3 < ROWS and c + 3 < COLS and all(board[cell_index(r + i, c + i)] == symbol for i in range(4)):
                return symbol
            if r + 3 < ROWS and c - 3 >= 0 and all(board[cell_index(r + i, c - i)] == symbol for i in range(4)):
                return symbol

    if "" not in board:
        return "Draw"

    return None


def winning_move_for(board, symbol):
    for c in valid_columns(board):
        row = drop_row(board, c)
        board[cell_index(row, c)] = symbol
        is_winner = check_winner(board) == symbol
        board[cell_index(row, c)] = ""
        if is_winner:
            return c
    return None


def score_window(window, symbol, opponent):
    score = 0
    if window.count(symbol) == 4:
        score += 100
    elif window.count(symbol) == 3 and window.count("") == 1:
        score += 5
    elif window.count(symbol) == 2 and window.count("") == 2:
        score += 2

    if window.count(opponent) == 3 and window.count("") == 1:
        score -= 4

    return score


def evaluate(board, symbol, opponent):
    score = 0

    center_col = COLS // 2
    center_cells = [board[cell_index(r, center_col)] for r in range(ROWS)]
    score += center_cells.count(symbol) * 3

    for r in range(ROWS):
        row_cells = [board[cell_index(r, c)] for c in range(COLS)]
        for c in range(COLS - 3):
            score += score_window(row_cells[c:c + 4], symbol, opponent)

    for c in range(COLS):
        col_cells = [board[cell_index(r, c)] for r in range(ROWS)]
        for r in range(ROWS - 3):
            score += score_window(col_cells[r:r + 4], symbol, opponent)

    for r in range(ROWS - 3):
        for c in range(COLS - 3):
            window = [board[cell_index(r + i, c + i)] for i in range(4)]
            score += score_window(window, symbol, opponent)

    for r in range(ROWS - 3):
        for c in range(3, COLS):
            window = [board[cell_index(r + i, c - i)] for i in range(4)]
            score += score_window(window, symbol, opponent)

    return score


def minimax(board, depth, alpha, beta, maximizing, bot_symbol, human_symbol):
    winner = check_winner(board)
    if winner == bot_symbol:
        return None, 10_000_000
    if winner == human_symbol:
        return None, -10_000_000
    if winner == "Draw":
        return None, 0
    if depth == 0:
        return None, evaluate(board, bot_symbol, human_symbol)

    cols = valid_columns(board)
    player = bot_symbol if maximizing else human_symbol
    best_col = random.choice(cols)
    value = -math.inf if maximizing else math.inf

    for c in cols:
        row = drop_row(board, c)
        board[cell_index(row, c)] = player
        _, new_score = minimax(board, depth - 1, alpha, beta, not maximizing, bot_symbol, human_symbol)
        board[cell_index(row, c)] = ""

        if maximizing:
            if new_score > value:
                value, best_col = new_score, c
            alpha = max(alpha, value)
        else:
            if new_score < value:
                value, best_col = new_score, c
            beta = min(beta, value)

        if alpha >= beta:
            break

    return best_col, value


def best_move(board, bot_symbol, human_symbol, depth=5):
    col, _ = minimax(board, depth, -math.inf, math.inf, True, bot_symbol, human_symbol)
    return col


def choose_bot_move(board, bot_symbol, human_symbol, difficulty):
    cols = valid_columns(board)

    if difficulty == "easy":
        return random.choice(cols)

    if difficulty == "medium":
        move = winning_move_for(board, bot_symbol)
        if move is None:
            move = winning_move_for(board, human_symbol)
        if move is None:
            move = random.choice(cols)
        return move

    return best_move(board, bot_symbol, human_symbol)


def reset_round(game):
    game["board"] = new_board()
    game["current_player"] = "R"


def reset_match(game):
    reset_round(game)
    game["scores"] = {"R": 0, "Y": 0, "Draw": 0}


def get_state(game, message=""):
    return {
        "type": "state",
        "board": game["board"],
        "currentPlayer": game["current_player"],
        "winner": check_winner(game["board"]),
        "scores": game["scores"],
        "playersConnected": len(game["connections"]),
        "message": message,
    }


async def broadcast(game, message=""):
    data = json.dumps(get_state(game, message))
    for ws in list(game["connections"].keys()):
        await ws.send_text(data)


async def reject(websocket, code):
    await websocket.accept()
    await websocket.close(code=code)


def record_result(game, winner):
    game["scores"][winner] += 1

    if game["mode"] == "bot":
        human = next(iter(game["connections"].values()))
        if human["symbol"] == "R":
            red_id, yellow_id = human["user_id"], game["bot_user_id"]
        else:
            red_id, yellow_id = game["bot_user_id"], human["user_id"]
    else:
        red_id = next(c["user_id"] for c in game["connections"].values() if c["symbol"] == "R")
        yellow_id = next(c["user_id"] for c in game["connections"].values() if c["symbol"] == "Y")

    db_execute(
        "INSERT INTO connect4_results (mode, player_red_id, player_yellow_id, winner) VALUES (%s, %s, %s, %s)",
        (game["mode"], red_id, yellow_id, winner),
        commit=True,
    )


@router.websocket("/ws/connect4")
async def websocket_endpoint(websocket: WebSocket, intent: str = "random", key: str = "", difficulty: str = "medium"):
    session = read_session_cookie(websocket.cookies.get(SESSION_COOKIE))
    if not session:
        await reject(websocket, 4401)
        return

    user_id = session["user_id"]
    display_name = session["nickname"]
    key = key.strip().upper()

    if intent == "create":
        if not KEY_RE.match(key):
            await reject(websocket, 4403)
            return
        if key in games:
            await reject(websocket, 4402)
            return
        games[key] = new_game_state("private")
        game_key = key
    elif intent == "join":
        if key not in games:
            await reject(websocket, 4404)
            return
        game_key = key
    elif intent == "bot":
        difficulty = difficulty.strip().lower()
        if difficulty not in BOT_DIFFICULTIES:
            await reject(websocket, 4406)
            return
        game_key = "bot-" + secrets.token_urlsafe(6)
        games[game_key] = new_game_state("bot", difficulty=difficulty, bot_user_id=get_bot_user_id(difficulty))
    else:
        game_key = find_or_create_random_game()

    game = games[game_key]

    if len(game["connections"]) >= 2:
        await reject(websocket, 4405)
        return

    symbols_in_use = {c["symbol"] for c in game["connections"].values()}
    player_symbol = "R" if "R" not in symbols_in_use else "Y"
    game["connections"][websocket] = {"symbol": player_symbol, "display_name": display_name, "user_id": user_id}

    await websocket.accept()

    await websocket.send_text(json.dumps({
        "type": "player",
        "player": player_symbol,
        "mode": game["mode"],
        "key": game_key if game["mode"] == "private" else None,
        "difficulty": game["difficulty"] if game["mode"] == "bot" else None,
    }))

    if game["mode"] == "bot":
        await broadcast(game, f"Playing vs Bot ({game['difficulty'].capitalize()})")
    else:
        await broadcast(game, f"{display_name} joined as {player_symbol}")

    try:
        while True:
            data = await websocket.receive_text()
            message = json.loads(data)

            if message["type"] == "move":
                column = message["column"]
                player = game["connections"][websocket]["symbol"]

                if player != game["current_player"]:
                    continue

                if check_winner(game["board"]):
                    continue

                row = drop_row(game["board"], column)
                if row is None:
                    continue

                game["board"][cell_index(row, column)] = player

                winner = check_winner(game["board"])

                if winner:
                    record_result(game, winner)
                    await broadcast(game, f"{winner} wins this round!")

                    reset_round(game)
                    await broadcast(game, "New round started")

                else:
                    game["current_player"] = "Y" if game["current_player"] == "R" else "R"
                    await broadcast(game)

                    if game["mode"] == "bot" and game["current_player"] != player:
                        bot_symbol = game["current_player"]
                        human_symbol = player

                        await asyncio.sleep(0.5)

                        bot_column = choose_bot_move(game["board"], bot_symbol, human_symbol, game["difficulty"])
                        bot_row = drop_row(game["board"], bot_column)
                        game["board"][cell_index(bot_row, bot_column)] = bot_symbol

                        bot_winner = check_winner(game["board"])

                        if bot_winner:
                            record_result(game, bot_winner)
                            await broadcast(game, f"{bot_winner} wins this round!")

                            reset_round(game)
                            await broadcast(game, "New round started")
                        else:
                            game["current_player"] = human_symbol
                            await broadcast(game)

            elif message["type"] == "reset":
                reset_match(game)
                await broadcast(game, "Match reset")

    except WebSocketDisconnect:
        if websocket in game["connections"]:
            exited_name = game["connections"][websocket]["display_name"]
            del game["connections"][websocket]

            if game["connections"]:
                reset_match(game)
                await broadcast(game, f"{exited_name} exited. Match reset.")
            else:
                games.pop(game_key, None)
