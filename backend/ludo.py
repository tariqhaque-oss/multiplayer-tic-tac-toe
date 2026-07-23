import json
import random
import asyncio
import secrets

from fastapi import APIRouter, WebSocket, WebSocketDisconnect

from config import KEY_RE, BOT_DIFFICULTIES, BOT_EMAILS, SESSION_COOKIE
from db import db_execute
from security import read_session_cookie

router = APIRouter()

COLORS = ["R", "G", "Y", "B"]
ENTRY_OFFSET = {"R": 0, "G": 13, "Y": 26, "B": 39}
# Safe cells ("rest stops"): the 4 start squares plus the 4 star cells 8 steps
# into each arm (standard board layout) - no capturing on any of these.
SAFE_CELLS = {0, 13, 26, 39, 8, 21, 34, 47}
TRACK_FINISH = 56  # position scale per token: -1 (yard), 0-50 (shared path), 51-56 (home stretch, 56 = home)

games = {}  # key -> game state dict - separate from the other games' `games` dicts

_bot_user_id_cache = {}


def get_bot_user_id(difficulty):
    if difficulty not in _bot_user_id_cache:
        row = db_execute("SELECT id FROM users WHERE email = %s", (BOT_EMAILS[difficulty],), fetch="one")
        _bot_user_id_cache[difficulty] = row[0]
    return _bot_user_id_cache[difficulty]


def new_tokens():
    return {c: [-1, -1, -1, -1] for c in COLORS}


def new_game_state(mode, difficulty=None):
    return {
        "mode": mode,               # "bot" | "random" | "private"
        "difficulty": difficulty,
        "tokens": new_tokens(),
        "connections": {},          # websocket -> {"colors": ["R", ...], "display_name": str, "user_id": int}
        "bot_seats": {},            # color -> {"user_id": int, "difficulty": str}
        "spectators": [],           # ordered list of websocket, oldest first (private mode overflow beyond 4 active seats)
        "seat_request": None,       # {"color": "R", "requester_ws": ws, "requester_name": str} or None
        "current_color": None,
        "dice": None,
        "legal_tokens": [],
        "consecutive_sixes": 0,
        "scores": {c: 0 for c in COLORS},
    }


def active_colors(game):
    """Colors currently held by a live connection or a bot seat, in fixed R/G/Y/B order."""
    colors = set(game["bot_seats"].keys())
    for conn in game["connections"].values():
        colors |= set(conn["colors"])
    return [c for c in COLORS if c in colors]


def next_color(game, after):
    occupied = active_colors(game)
    if not occupied:
        return None
    if after not in occupied:
        return occupied[0]
    return occupied[(occupied.index(after) + 1) % len(occupied)]


def ensure_current_color(game):
    occupied = active_colors(game)
    if not occupied:
        game["current_color"] = None
    elif game["current_color"] not in occupied:
        game["current_color"] = occupied[0]


def find_or_create_random_game():
    for key, game in games.items():
        if game["mode"] == "random" and len(active_colors(game)) < 4:
            return key

    key = "random-" + secrets.token_urlsafe(6)
    games[key] = new_game_state("random")
    return key


def global_cell(color, pos):
    return (ENTRY_OFFSET[color] + pos) % 52


def legal_moves(tokens, roll):
    moves = []
    for i, pos in enumerate(tokens):
        if pos == -1:
            if roll == 6:
                moves.append(i)
        elif pos + roll <= TRACK_FINISH:
            moves.append(i)
    return moves


def would_capture(game, color, new_pos):
    if new_pos > 50:
        return False
    cell = global_cell(color, new_pos)
    if cell in SAFE_CELLS:
        return False
    for other in COLORS:
        if other == color:
            continue
        for p in game["tokens"][other]:
            if 0 <= p <= 50 and global_cell(other, p) == cell:
                return True
    return False


def apply_move(game, color, token_index, roll):
    tokens = game["tokens"][color]
    pos = tokens[token_index]
    new_pos = 0 if pos == -1 else pos + roll
    tokens[token_index] = new_pos

    captured = False
    if new_pos <= 50:
        cell = global_cell(color, new_pos)
        if cell not in SAFE_CELLS:
            for other in COLORS:
                if other == color:
                    continue
                for i, p in enumerate(game["tokens"][other]):
                    if 0 <= p <= 50 and global_cell(other, p) == cell:
                        game["tokens"][other][i] = -1
                        captured = True

    finished = all(p == TRACK_FINISH for p in tokens)
    return finished, captured


def choose_bot_move(game, color, roll, difficulty):
    moves = legal_moves(game["tokens"][color], roll)
    if not moves:
        return None

    if difficulty == "easy":
        return random.choice(moves)

    def new_pos_for(i):
        pos = game["tokens"][color][i]
        return 0 if pos == -1 else pos + roll

    def score(i):
        pos = game["tokens"][color][i]
        new_pos = new_pos_for(i)
        value = new_pos
        if would_capture(game, color, new_pos):
            value += 50
        if pos == -1:
            value += 10
        if new_pos == TRACK_FINISH:
            value += 40
        if difficulty == "hard" and new_pos <= 50 and global_cell(color, new_pos) not in SAFE_CELLS:
            value -= 5
        return value

    return max(moves, key=score)


def reset_round(game):
    game["tokens"] = new_tokens()
    game["dice"] = None
    game["legal_tokens"] = []
    game["consecutive_sixes"] = 0


def reset_match(game):
    reset_round(game)
    game["scores"] = {c: 0 for c in COLORS}


def get_state(game, message="", winner=None):
    seat_request = None
    if game["seat_request"]:
        seat_request = {"color": game["seat_request"]["color"], "requesterName": game["seat_request"]["requester_name"]}

    return {
        "type": "state",
        "tokens": game["tokens"],
        "currentColor": game["current_color"],
        "occupied": active_colors(game),
        "dice": game["dice"],
        "legalTokens": game["legal_tokens"],
        "winner": winner,
        "scores": game["scores"],
        "playersConnected": len(game["connections"]),
        "spectatorCount": len(game["spectators"]),
        "seatRequest": seat_request,
        "message": message,
    }


async def broadcast(game, message="", winner=None):
    data = json.dumps(get_state(game, message, winner))
    for ws in list(game["connections"].keys()) + list(game["spectators"]):
        await ws.send_text(data)


async def send_player_msg(websocket, color_or_colors, game, game_key, role):
    colors = color_or_colors if isinstance(color_or_colors, list) else ([color_or_colors] if color_or_colors else [])
    await websocket.send_text(json.dumps({
        "type": "player",
        "colors": colors,
        "role": role,
        "mode": game["mode"],
        "key": game_key if game["mode"] == "private" else None,
        "difficulty": game["difficulty"] if game["mode"] == "bot" else None,
    }))


async def reject(websocket, code):
    await websocket.accept()
    await websocket.close(code=code)


def record_result(game, winner_color):
    game["scores"][winner_color] += 1
    round_id = secrets.token_hex(8)

    # De-dupe by user_id: one connection can control multiple colors (bot-mode
    # practice), and bot colors can share the same synthetic bot account - either
    # way a given account should get exactly one row per round, marked a win if
    # any color it controlled was the winner.
    by_user = {}
    for conn in game["connections"].values():
        for color in conn["colors"]:
            is_winner = color == winner_color
            if is_winner or conn["user_id"] not in by_user:
                by_user[conn["user_id"]] = {"color": color, "winner": is_winner}
    for color, bot in game["bot_seats"].items():
        is_winner = color == winner_color
        if is_winner or bot["user_id"] not in by_user:
            by_user[bot["user_id"]] = {"color": color, "winner": is_winner}

    for user_id, info in by_user.items():
        db_execute(
            "INSERT INTO ludo_results (mode, round_id, player_id, color, winner) VALUES (%s, %s, %s, %s, %s)",
            (game["mode"], round_id, user_id, info["color"], info["winner"]),
            commit=True,
        )


async def promote_next_spectator(game, game_key, color):
    """Fill a newly-empty active seat with the most recently joined spectator, if any."""
    if not game["spectators"]:
        return
    ws = game["spectators"].pop()  # most recently joined (appended last)
    conn = {"colors": [color], "display_name": ws.ludo_display_name, "user_id": ws.ludo_user_id}
    game["connections"][ws] = conn
    ensure_current_color(game)
    await send_player_msg(ws, [color], game, game_key, "player")


async def handle_bot_turns(game):
    while game["current_color"] in game["bot_seats"]:
        color = game["current_color"]
        difficulty = game["bot_seats"][color]["difficulty"]

        await asyncio.sleep(0.6)

        roll = random.randint(1, 6)
        game["consecutive_sixes"] = game["consecutive_sixes"] + 1 if roll == 6 else 0

        if game["consecutive_sixes"] >= 3:
            game["consecutive_sixes"] = 0
            game["current_color"] = next_color(game, color)
            await broadcast(game, f"{color} (bot) rolled three 6s in a row - turn forfeited")
            continue

        moves = legal_moves(game["tokens"][color], roll)
        if not moves:
            if roll == 6:
                await broadcast(game, f"{color} (bot) rolled a 6 but has no legal move - rolls again")
                continue
            game["current_color"] = next_color(game, color)
            await broadcast(game, f"{color} (bot) rolled {roll} - no legal moves, turn passes")
            continue

        token_index = choose_bot_move(game, color, roll, difficulty)
        finished, captured = apply_move(game, color, token_index, roll)
        note = " and captured a token!" if captured else ""

        if finished:
            record_result(game, color)
            await broadcast(game, f"{color} (bot) wins! All tokens home.", winner=color)
            reset_round(game)
            await broadcast(game, "New round started")
            return

        if roll == 6:
            await broadcast(game, f"{color} (bot) rolled {roll} and moved token {token_index + 1}{note} - rolls again")
            continue

        game["current_color"] = next_color(game, color)
        await broadcast(game, f"{color} (bot) rolled {roll} and moved token {token_index + 1}{note}")


@router.websocket("/ws/ludo")
async def websocket_endpoint(websocket: WebSocket, intent: str = "random", key: str = "",
                              difficulty: str = "medium", seats: int = 1):
    session = read_session_cookie(websocket.cookies.get(SESSION_COOKIE))
    if not session:
        await reject(websocket, 4401)
        return

    user_id = session["user_id"]
    display_name = session["nickname"]
    key = key.strip().upper()
    websocket.ludo_display_name = display_name
    websocket.ludo_user_id = user_id

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
        seats = max(1, min(4, seats))
        game_key = "bot-" + secrets.token_urlsafe(6)
        game = new_game_state("bot", difficulty=difficulty)
        human_colors = COLORS[:seats]
        bot_colors = COLORS[seats:]
        bot_uid = get_bot_user_id(difficulty) if bot_colors else None
        for color in bot_colors:
            game["bot_seats"][color] = {"user_id": bot_uid, "difficulty": difficulty}
        games[game_key] = game
    else:
        game_key = find_or_create_random_game()

    game = games[game_key]

    if intent == "bot":
        game["connections"][websocket] = {"colors": human_colors, "display_name": display_name, "user_id": user_id}
        ensure_current_color(game)
        await websocket.accept()
        await send_player_msg(websocket, human_colors, game, game_key, "player")
        bots_desc = f"{len(bot_colors)} bot(s)" if bot_colors else "no bots (solo practice)"
        await broadcast(game, f"{display_name} playing {', '.join(human_colors)} vs {bots_desc} ({difficulty.capitalize()})")
    else:
        occupied = active_colors(game)
        available_colors = [c for c in COLORS if c not in occupied]

        if available_colors:
            color = available_colors[0]
            game["connections"][websocket] = {"colors": [color], "display_name": display_name, "user_id": user_id}
            ensure_current_color(game)
            await websocket.accept()
            await send_player_msg(websocket, color, game, game_key, "player")
            await broadcast(game, f"{display_name} joined as {color}")
        elif game["mode"] == "private":
            game["spectators"].append(websocket)
            await websocket.accept()
            await send_player_msg(websocket, [], game, game_key, "spectator")
            await broadcast(game, f"{display_name} joined as a spectator")
        else:
            await reject(websocket, 4405)
            return

    await handle_bot_turns(game)

    try:
        while True:
            data = await websocket.receive_text()
            message = json.loads(data)

            conn = game["connections"].get(websocket)
            is_spectator = websocket in game["spectators"]

            if message["type"] == "roll" and conn:
                color = game["current_color"]
                if color not in conn["colors"] or game["dice"] is not None:
                    continue

                roll = random.randint(1, 6)
                game["consecutive_sixes"] = game["consecutive_sixes"] + 1 if roll == 6 else 0

                if game["consecutive_sixes"] >= 3:
                    game["consecutive_sixes"] = 0
                    game["current_color"] = next_color(game, color)
                    await broadcast(game, f"{color} rolled three 6s in a row - turn forfeited")
                    await handle_bot_turns(game)
                    continue

                moves = legal_moves(game["tokens"][color], roll)

                if not moves:
                    game["dice"] = None
                    if roll == 6:
                        await broadcast(game, f"{color} rolled a 6 but has no legal move - roll again")
                    else:
                        game["current_color"] = next_color(game, color)
                        await broadcast(game, f"{color} rolled {roll} - no legal moves, turn passes")
                    await handle_bot_turns(game)
                    continue

                game["dice"] = roll
                game["legal_tokens"] = moves
                await broadcast(game, f"{color} rolled {roll}")

            elif message["type"] == "move" and conn:
                color = game["current_color"]
                if color not in conn["colors"] or game["dice"] is None:
                    continue

                token_index = message["token"]
                if token_index not in game["legal_tokens"]:
                    continue

                roll = game["dice"]
                finished, captured = apply_move(game, color, token_index, roll)
                game["dice"] = None
                game["legal_tokens"] = []
                note = " and captured a token!" if captured else ""

                if finished:
                    record_result(game, color)
                    await broadcast(game, f"{color} wins! All tokens home.", winner=color)
                    reset_round(game)
                    await broadcast(game, "New round started")
                elif roll == 6:
                    await broadcast(game, f"{color} moved token {token_index + 1}{note} - rolls again")
                else:
                    game["current_color"] = next_color(game, color)
                    await broadcast(game, f"{color} moved token {token_index + 1}{note}")

                await handle_bot_turns(game)

            elif message["type"] == "reset" and conn:
                reset_match(game)
                ensure_current_color(game)
                await broadcast(game, "Match reset")
                await handle_bot_turns(game)

            elif message["type"] == "request_seat" and is_spectator and game["mode"] == "private":
                requested_color = message.get("color")
                if requested_color not in active_colors(game):
                    continue
                if game["seat_request"] is not None:
                    continue
                game["seat_request"] = {
                    "color": requested_color,
                    "requester_ws": websocket,
                    "requester_name": display_name,
                }
                await broadcast(game, f"{display_name} is requesting {requested_color}'s seat")

            elif message["type"] == "respond_seat_request" and conn:
                req = game["seat_request"]
                if not req or req["color"] not in conn["colors"]:
                    continue

                game["seat_request"] = None
                accept = bool(message.get("accept"))

                if not accept:
                    await broadcast(game, f"{conn['display_name']} declined to give up {req['color']}'s seat")
                    continue

                requester_ws = req["requester_ws"]
                color = req["color"]

                conn["colors"].remove(color)
                if requester_ws in game["spectators"]:
                    game["spectators"].remove(requester_ws)

                game["connections"][requester_ws] = {
                    "colors": [color], "display_name": req["requester_name"], "user_id": requester_ws.ludo_user_id,
                }

                if not conn["colors"]:
                    del game["connections"][websocket]
                    game["spectators"].append(websocket)

                ensure_current_color(game)
                await send_player_msg(requester_ws, [color], game, game_key, "player")
                if not conn["colors"]:
                    await send_player_msg(websocket, [], game, game_key, "spectator")
                await broadcast(game, f"{req['requester_name']} took over {color}'s seat")
                await handle_bot_turns(game)

    except WebSocketDisconnect:
        if websocket in game["spectators"]:
            game["spectators"].remove(websocket)
            if game["seat_request"] and game["seat_request"]["requester_ws"] == websocket:
                game["seat_request"] = None

        elif websocket in game["connections"]:
            exited_name = game["connections"][websocket]["display_name"]
            exited_colors = game["connections"][websocket]["colors"]
            del game["connections"][websocket]

            if game["seat_request"] and game["seat_request"]["color"] in exited_colors:
                game["seat_request"] = None

            if game["connections"]:
                reset_match(game)

                if game["mode"] == "private":
                    for color in exited_colors:
                        await promote_next_spectator(game, game_key, color)

                ensure_current_color(game)
                await broadcast(game, f"{exited_name} exited. Match reset.")
                await handle_bot_turns(game)
            else:
                games.pop(game_key, None)
