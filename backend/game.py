import json
import random
import asyncio
import secrets

from fastapi import APIRouter, WebSocket, WebSocketDisconnect

from config import KEY_RE, BOT_DIFFICULTIES, BOT_EMAILS, SESSION_COOKIE
from db import db_execute
from security import read_session_cookie

router = APIRouter()

winning_combinations = [
    [0,1,2], [3,4,5], [6,7,8],
    [0,3,6], [1,4,7], [2,5,8],
    [0,4,8], [2,4,6]
]

games = {}  # key -> game state dict, at most 2 connections each

_bot_user_id_cache = {}


def get_bot_user_id(difficulty):
    if difficulty not in _bot_user_id_cache:
        row = db_execute("SELECT id FROM users WHERE email = %s", (BOT_EMAILS[difficulty],), fetch="one")
        _bot_user_id_cache[difficulty] = row[0]
    return _bot_user_id_cache[difficulty]


def new_game_state(mode, difficulty=None, bot_user_id=None):
    return {
        "mode": mode,
        "difficulty": difficulty,
        "bot_user_id": bot_user_id,
        "board": [""] * 9,
        "current_player": "X",
        "scores": {"X": 0, "O": 0, "Draw": 0},
        "connections": {},  # websocket -> {"symbol": "X"/"O", "display_name": str, "user_id": int}
    }


def find_or_create_random_game():
    for key, game in games.items():
        if game["mode"] == "random" and len(game["connections"]) == 1:
            return key

    key = "random-" + secrets.token_urlsafe(6)
    games[key] = new_game_state("random")
    return key


def check_winner(board):
    for a, b, c in winning_combinations:
        if board[a] and board[a] == board[b] == board[c]:
            return board[a]

    if "" not in board:
        return "Draw"

    return None


def empty_cells(board):
    return [i for i, cell in enumerate(board) if cell == ""]


def winning_move_for(board, symbol):
    for i in empty_cells(board):
        board[i] = symbol
        is_winner = check_winner(board) == symbol
        board[i] = ""
        if is_winner:
            return i
    return None


def minimax(board, player, bot_symbol, human_symbol):
    winner = check_winner(board)
    if winner == bot_symbol:
        return 1
    if winner == human_symbol:
        return -1
    if winner == "Draw":
        return 0

    next_player = human_symbol if player == bot_symbol else bot_symbol
    scores = []
    for i in empty_cells(board):
        board[i] = player
        scores.append(minimax(board, next_player, bot_symbol, human_symbol))
        board[i] = ""

    return max(scores) if player == bot_symbol else min(scores)


def best_move(board, bot_symbol, human_symbol):
    best_score, best_index = None, None
    for i in empty_cells(board):
        board[i] = bot_symbol
        score = minimax(board, human_symbol, bot_symbol, human_symbol)
        board[i] = ""
        if best_score is None or score > best_score:
            best_score, best_index = score, i
    return best_index


def choose_bot_move(board, bot_symbol, human_symbol, difficulty):
    if difficulty == "easy":
        return random.choice(empty_cells(board))

    if difficulty == "medium":
        move = winning_move_for(board, bot_symbol)
        if move is None:
            move = winning_move_for(board, human_symbol)
        if move is None:
            move = random.choice(empty_cells(board))
        return move

    return best_move(board, bot_symbol, human_symbol)


def reset_round(game):
    game["board"] = [""] * 9
    game["current_player"] = "X"


def reset_match(game):
    reset_round(game)
    game["scores"] = {"X": 0, "O": 0, "Draw": 0}


def get_state(game, message=""):
    return {
        "type": "state",
        "board": game["board"],
        "currentPlayer": game["current_player"],
        "winner": check_winner(game["board"]),
        "scores": game["scores"],
        "playersConnected": len(game["connections"]),
        "message": message
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
        if human["symbol"] == "X":
            x_id, o_id = human["user_id"], game["bot_user_id"]
        else:
            x_id, o_id = game["bot_user_id"], human["user_id"]
    else:
        x_id = next(c["user_id"] for c in game["connections"].values() if c["symbol"] == "X")
        o_id = next(c["user_id"] for c in game["connections"].values() if c["symbol"] == "O")

    db_execute(
        "INSERT INTO game_results (mode, player_x_id, player_o_id, winner) VALUES (%s, %s, %s, %s)",
        (game["mode"], x_id, o_id, winner),
        commit=True,
    )


@router.websocket("/ws")
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
    player_symbol = "X" if "X" not in symbols_in_use else "O"
    game["connections"][websocket] = {"symbol": player_symbol, "display_name": display_name, "user_id": user_id}

    await websocket.accept()

    await websocket.send_text(json.dumps({
        "type": "player",
        "player": player_symbol,
        "mode": game["mode"],
        "key": game_key if game["mode"] == "private" else None,
        "difficulty": game["difficulty"] if game["mode"] == "bot" else None
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
                index = message["index"]
                player = game["connections"][websocket]["symbol"]

                if player != game["current_player"]:
                    continue

                if game["board"][index] != "":
                    continue

                if check_winner(game["board"]):
                    continue

                game["board"][index] = player

                winner = check_winner(game["board"])

                if winner:
                    record_result(game, winner)
                    await broadcast(game, f"{winner} wins this round!")

                    reset_round(game)
                    await broadcast(game, "New round started")

                else:
                    game["current_player"] = "O" if game["current_player"] == "X" else "X"
                    await broadcast(game)

                    if game["mode"] == "bot" and game["current_player"] != player:
                        bot_symbol = game["current_player"]
                        human_symbol = player

                        await asyncio.sleep(0.5)

                        bot_index = choose_bot_move(game["board"], bot_symbol, human_symbol, game["difficulty"])
                        game["board"][bot_index] = bot_symbol

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
