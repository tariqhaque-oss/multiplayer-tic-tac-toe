import json
import random
import asyncio
import secrets

from fastapi import APIRouter, WebSocket, WebSocketDisconnect

from config import KEY_RE, BOT_EMAILS, SESSION_COOKIE
from db import db_execute
from security import read_session_cookie

router = APIRouter()

SUITS = ["♠", "♥", "♦", "♣"]
RED_SUITS = {"♥", "♦"}
RANKS = [2, 3, 4, 5, 6, 7, 8, 9, 10, "J", "Q", "K", "A"]
RANK_VALUE = {2: 2, 3: 3, 4: 4, 5: 5, 6: 6, 7: 7, 8: 8, 9: 9, 10: 10, "J": 11, "Q": 12, "K": 13, "A": 14}

SEATS = ["P1", "P2", "P3", "P4"]
TEAM_OF = {"P1": "A", "P3": "A", "P2": "B", "P4": "B"}
PARTNER_OF = {"P1": "P3", "P3": "P1", "P2": "P4", "P4": "P2"}

games = {}  # key -> game state dict - separate from the other games' `games` dicts

_bot_user_id_cache = {}


def get_bot_user_id(difficulty):
    if difficulty not in _bot_user_id_cache:
        row = db_execute("SELECT id FROM users WHERE email = %s", (BOT_EMAILS[difficulty],), fetch="one")
        _bot_user_id_cache[difficulty] = row[0]
    return _bot_user_id_cache[difficulty]


def card_key(card):
    return card["suit"] + str(card["rank"])


def is_red(suit):
    return suit in RED_SUITS


def build_deck():
    deck = []
    for suit in SUITS:
        for rank in RANKS:
            deck.append({"suit": suit, "rank": rank, "value": RANK_VALUE[rank], "color": "red" if is_red(suit) else "black"})
    return deck


def shuffle_deck():
    deck = build_deck()
    random.shuffle(deck)
    return deck


def next_seat(seat):
    return SEATS[(SEATS.index(seat) + 1) % 4]


# ----------------------------------------------------------------------
# Round state machine (mirrors frontend/static/js/court-piece-engine.js -
# ported to Python here so the SERVER is authoritative; the browser never
# sees another seat's cards, unlike the old client-only mock version).
# ----------------------------------------------------------------------
def new_round_state(trump_caller_seat):
    deck = shuffle_deck()
    return {
        "phase": "dealing-first-five",
        "deck": deck,
        "hands": {"P1": [], "P2": [], "P3": [], "P4": []},
        "trump_caller_seat": trump_caller_seat,
        "trump_suit": None,
        "leader": None,
        "current_trick": [],  # [{"seat": ..., "card": {...}}]
        "led_suit": None,
        "tricks_played": 0,
        "trick_wins": {"A": 0, "B": 0},
        "last_trick_winner_seat": None,
        "pending_pile": [],  # [{"seat":..., "card": {...}}]
        "collected": {"A": [], "B": []},
        "last_trick_info": None,
        "winner": None,
    }


def deal_first_five(state):
    for seat in SEATS:
        state["hands"][seat] = state["deck"][:5]
        state["deck"] = state["deck"][5:]
    state["phase"] = "trump-selection"


def choose_bot_trump(hand):
    counts = {suit: 0 for suit in SUITS}
    for card in hand:
        counts[card["suit"]] += 1
    return max(SUITS, key=lambda s: counts[s])


def deal_remaining(state, trump_suit):
    state["trump_suit"] = trump_suit
    for seat in SEATS:
        state["hands"][seat] = state["hands"][seat] + state["deck"][:8]
        state["deck"] = state["deck"][8:]
    state["deck"] = []
    state["phase"] = "playing"
    state["leader"] = state["trump_caller_seat"]


def legal_moves(hand, led_suit):
    if not led_suit:
        return list(hand)
    following = [c for c in hand if c["suit"] == led_suit]
    return following if following else list(hand)


def is_legal_move(hand, led_suit, card):
    moves = legal_moves(hand, led_suit)
    return any(card_key(c) == card_key(card) for c in moves)


def resolve_trick(trick, led_suit, trump_suit):
    trump_plays = [t for t in trick if t["card"]["suit"] == trump_suit]
    pool = trump_plays if trump_plays else [t for t in trick if t["card"]["suit"] == led_suit]
    best = pool[0]
    for play in pool:
        if play["card"]["value"] > best["card"]["value"]:
            best = play
    return best["seat"]


def current_turn_seat(state):
    if not state["current_trick"]:
        return state["leader"]
    return next_seat(state["current_trick"][-1]["seat"])


def remove_from_hand(hand, card):
    idx = next(i for i, c in enumerate(hand) if card_key(c) == card_key(card))
    hand.pop(idx)


def count_tens(cards):
    return sum(1 for c in cards if c["rank"] == 10)


def compute_round_winner(state):
    tens_a = count_tens(state["collected"]["A"])
    tens_b = count_tens(state["collected"]["B"])
    if tens_a >= 3:
        return "A"
    if tens_b >= 3:
        return "B"
    if state["trick_wins"]["A"] > state["trick_wins"]["B"]:
        return "A"
    if state["trick_wins"]["B"] > state["trick_wins"]["A"]:
        return "B"
    return None


def play_card(state, seat, card):
    hand = state["hands"][seat]
    if not is_legal_move(hand, state["led_suit"], card):
        raise ValueError("illegal move: must follow suit if possible")

    remove_from_hand(hand, card)
    state["current_trick"].append({"seat": seat, "card": card})
    if len(state["current_trick"]) == 1:
        state["led_suit"] = card["suit"]

    result = {"trick_completed": False, "round_completed": False, "trick_winner_seat": None, "collected": False}

    if len(state["current_trick"]) == 4:
        winner_seat = resolve_trick(state["current_trick"], state["led_suit"], state["trump_suit"])
        state["tricks_played"] += 1
        state["trick_wins"][TEAM_OF[winner_seat]] += 1
        state["pending_pile"].extend(state["current_trick"])

        is_final_trick = state["tricks_played"] == 13
        double_win = winner_seat == state["last_trick_winner_seat"]

        if double_win or is_final_trick:
            team = TEAM_OF[winner_seat]
            state["collected"][team].extend(p["card"] for p in state["pending_pile"])
            state["pending_pile"] = []
            result["collected"] = True

        state["last_trick_info"] = {"winner_seat": winner_seat, "cards_count": len(state["current_trick"])}
        state["last_trick_winner_seat"] = winner_seat
        state["current_trick"] = []
        state["led_suit"] = None
        state["leader"] = winner_seat

        result["trick_completed"] = True
        result["trick_winner_seat"] = winner_seat

        if is_final_trick:
            state["phase"] = "round-over"
            state["winner"] = compute_round_winner(state)
            result["round_completed"] = True

    return result


# ----------------------------------------------------------------------
# Bot AI (mirrors court-piece-engine.js's chooseBotCard)
# ----------------------------------------------------------------------
def choose_bot_card(hand, state):
    led_suit = state["led_suit"]
    trump_suit = state["trump_suit"]
    moves = legal_moves(hand, led_suit)

    if led_suit:
        following_suit = [c for c in moves if c["suit"] == led_suit]
        if following_suit:
            return max(following_suit, key=lambda c: c["value"])

    seat = state["leader"] if not state["current_trick"] else next_seat(state["current_trick"][-1]["seat"])
    partner_seat = PARTNER_OF[seat]
    partner_is_winning = bool(state["current_trick"]) and resolve_trick(state["current_trick"], state["led_suit"], trump_suit) == partner_seat

    if not led_suit:
        non_trump = [c for c in hand if c["suit"] != trump_suit]
        pool = non_trump if non_trump else hand
        return max(pool, key=lambda c: c["value"])

    trumps_in_hand = [c for c in hand if c["suit"] == trump_suit]
    trump_already_played = any(t["card"]["suit"] == trump_suit for t in state["current_trick"])

    if trumps_in_hand and not partner_is_winning:
        if not trump_already_played:
            return min(trumps_in_hand, key=lambda c: c["value"])
        highest_trump_in_trick = max(t["card"]["value"] for t in state["current_trick"] if t["card"]["suit"] == trump_suit)
        winning_trumps = [c for c in trumps_in_hand if c["value"] > highest_trump_in_trick]
        if winning_trumps:
            return min(winning_trumps, key=lambda c: c["value"])

    return min(hand, key=lambda c: c["value"])


# ----------------------------------------------------------------------
# Game/room state (seats, spectators, matchmaking) - separate from the
# round state machine above, which only knows about cards.
# ----------------------------------------------------------------------
def new_game_state(mode):
    return {
        "mode": mode,                # "bot" | "random" | "private"
        "round": None,                # a round-state dict once dealing starts, else None
        "connections": {},            # websocket -> {"seats": ["P1", ...], "display_name": str, "user_id": int}
        "bot_seats": set(),           # seats controlled by the single shared bot account
        "spectators": [],             # FIFO queue, oldest first: {"id": int, "name": str, "user_id": int}
        "seat_request": None,         # {"spectator_id", "spectator_name", "target_seat"} or None
        "trump_caller_seat": "P1",    # rotates to the next seat after each round
        "match_score": {"A": 0, "B": 0},
        "next_spectator_id": 1,
        "bot_user_id": None,          # the shared bot account's DB id, set when a bot occupies any seat
    }


def occupied_seats(game):
    seats = set(game["bot_seats"])
    for conn in game["connections"].values():
        seats |= set(conn["seats"])
    return [s for s in SEATS if s in seats]


def find_or_create_random_game():
    for key, game in games.items():
        if game["mode"] == "random" and len(occupied_seats(game)) < 4:
            return key
    key = "random-" + secrets.token_urlsafe(6)
    games[key] = new_game_state("random")
    return key


def seat_controller_name(game, seat):
    for conn in game["connections"].values():
        if seat in conn["seats"]:
            return conn["display_name"]
    if seat in game["bot_seats"]:
        return "Bot"
    return seat  # vacant (e.g. abandoned mid-round) - falls back to auto-play, see maybe_run_bot_turns


def is_seat_human(game, seat):
    return any(seat in conn["seats"] for conn in game["connections"].values())


async def send_json(websocket, payload):
    await websocket.send_text(json.dumps(payload))


async def reject(websocket, code):
    await websocket.accept()
    await websocket.close(code=code)


def public_round_view(game):
    """Info every connection (players and spectators alike) is allowed to see."""
    r = game["round"]
    if not r:
        return {
            "phase": None, "trumpSuit": None, "trumpCallerSeat": game["trump_caller_seat"],
            "currentTurnSeat": None, "ledSuit": None, "currentTrick": [],
            "pendingPileTricks": 0, "trickWins": {"A": 0, "B": 0}, "tensCollected": {"A": 0, "B": 0},
            "lastTrickWinnerSeat": None, "winner": None, "handCounts": {s: 0 for s in SEATS},
        }
    return {
        "phase": r["phase"],
        "trumpSuit": r["trump_suit"],
        "trumpCallerSeat": r["trump_caller_seat"],
        "currentTurnSeat": current_turn_seat(r) if r["phase"] == "playing" else None,
        "ledSuit": r["led_suit"],
        "currentTrick": r["current_trick"],
        "pendingPileTricks": len(r["pending_pile"]) // 4,
        "trickWins": r["trick_wins"],
        "tensCollected": {"A": count_tens(r["collected"]["A"]), "B": count_tens(r["collected"]["B"])},
        "lastTrickWinnerSeat": r["last_trick_info"]["winner_seat"] if r["last_trick_info"] else None,
        "winner": r["winner"],
        "handCounts": {s: len(r["hands"][s]) for s in SEATS},
    }


def build_state_for(game, my_seats, message="", winner_override=None):
    r = game["round"]
    view = public_round_view(game)
    if winner_override is not None:
        view["winner"] = winner_override

    my_hands = {}
    legal_for_me = {}
    if r:
        for seat in my_seats:
            my_hands[seat] = r["hands"][seat]
            if r["phase"] == "playing" and current_turn_seat(r) == seat:
                legal_for_me[seat] = legal_moves(r["hands"][seat], r["led_suit"])
            elif r["phase"] == "trump-selection" and r["trump_caller_seat"] == seat:
                legal_for_me[seat] = "choose_trump"

    return {
        "type": "state",
        **view,
        "occupied": occupied_seats(game),
        "seatNames": {s: seat_controller_name(game, s) for s in SEATS},
        "mySeats": my_seats,
        "myHands": my_hands,
        "legalForMe": legal_for_me,
        "matchScore": game["match_score"],
        "playersConnected": len(game["connections"]),
        "spectatorCount": len(game["spectators"]),
        "seatRequest": ({"seat": game["seat_request"]["target_seat"], "requesterName": game["seat_request"]["spectator_name"]}
                         if game["seat_request"] else None),
        "message": message,
    }


# Spectators need their own websocket->id mapping to receive broadcasts too;
# game["spectators"] holds the ordered queue of {id,name,user_id}, and this
# dict tracks which live websocket corresponds to which spectator id.
def _spectator_ws_map(game):
    return game.setdefault("_spectator_ws", {})


async def broadcast_all(game, message="", winner_override=None):
    for ws, conn in list(game["connections"].items()):
        await send_json(ws, build_state_for(game, conn["seats"], message, winner_override))
    for ws in list(_spectator_ws_map(game).keys()):
        await send_json(ws, build_state_for(game, [], message, winner_override))


def record_result(game, winner_team):
    game["match_score"][winner_team] += 1
    round_id = secrets.token_hex(8)

    by_user = {}
    for conn in game["connections"].values():
        for seat in conn["seats"]:
            is_winner = TEAM_OF[seat] == winner_team
            if is_winner or conn["user_id"] not in by_user:
                by_user[conn["user_id"]] = {"seat": seat, "winner": is_winner}
    # Truly abandoned seats (disconnected mid-round, no bot ever assigned)
    # have no account to credit and are skipped here on purpose.
    for seat in game["bot_seats"]:
        is_winner = TEAM_OF[seat] == winner_team
        if is_winner or game["bot_user_id"] not in by_user:
            by_user[game["bot_user_id"]] = {"seat": seat, "winner": is_winner}

    for user_id, info in by_user.items():
        db_execute(
            "INSERT INTO court_piece_results (mode, round_id, player_id, seat, team, winner) VALUES (%s, %s, %s, %s, %s, %s)",
            (game["mode"], round_id, user_id, info["seat"], TEAM_OF[info["seat"]], info["winner"]),
            commit=True,
        )


async def start_round_if_ready(game):
    if game["round"] is not None:
        return
    if len(occupied_seats(game)) != 4:
        return

    game["round"] = new_round_state(game["trump_caller_seat"])
    deal_first_five(game["round"])
    await broadcast_all(game, f"New round dealt. {game['trump_caller_seat']} is Eldest Hand and must call trump.")
    await maybe_bot_call_trump(game)


async def maybe_bot_call_trump(game):
    r = game["round"]
    caller = r["trump_caller_seat"]
    if is_seat_human(game, caller):
        return
    await asyncio.sleep(0.8)
    suit = choose_bot_trump(r["hands"][caller])
    deal_remaining(r, suit)
    await broadcast_all(game, f"{seat_controller_name(game, caller)} called {suit} as trump. Remaining cards dealt.")
    await maybe_run_bot_turns(game)


async def maybe_run_bot_turns(game):
    r = game["round"]
    # Covers both real bot seats and seats abandoned mid-round (a human
    # disconnected with no spectator to promote into their place) - either
    # way, nothing human is going to act for this seat, so it auto-plays.
    while r["phase"] == "playing" and not is_seat_human(game, current_turn_seat(r)):
        seat = current_turn_seat(r)
        await asyncio.sleep(0.7)

        card = choose_bot_card(r["hands"][seat], r)
        result = play_card(r, seat, card)
        note = f"{seat_controller_name(game, seat)} played {card['rank']} of {card['suit']}."

        if result["trick_completed"]:
            winner_seat = result["trick_winner_seat"]
            note += f" {seat_controller_name(game, winner_seat)} won the trick."
            if result["collected"]:
                note += " Team collects the pile!"

        await broadcast_all(game, note)

        if result["round_completed"]:
            record_result(game, r["winner"])
            await broadcast_all(game, f"Round over: Team {r['winner']} wins!", winner_override=r["winner"])
            return


@router.websocket("/ws/court-piece")
async def websocket_endpoint(websocket: WebSocket, intent: str = "random", key: str = "", team: str = "A"):
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
        if team not in ("A", "B"):
            await reject(websocket, 4407)
            return
        game_key = "bot-" + secrets.token_urlsafe(6)
        game = new_game_state("bot")
        human_seats = ["P1", "P3"] if team == "A" else ["P2", "P4"]

        game["bot_user_id"] = get_bot_user_id("medium")
        for s in SEATS:
            if s not in human_seats:
                game["bot_seats"].add(s)
        games[game_key] = game
    else:
        game_key = find_or_create_random_game()

    game = games[game_key]

    if intent == "bot":
        game["connections"][websocket] = {"seats": human_seats, "display_name": display_name, "user_id": user_id}
        await websocket.accept()
        await send_json(websocket, {"type": "player", "seats": human_seats, "role": "player",
                                     "mode": game["mode"], "key": None})
        await broadcast_all(game, f"{display_name} playing {', '.join(human_seats)} vs bots")
    else:
        available = [s for s in SEATS if s not in occupied_seats(game)]
        if available:
            chosen_seat = available[0]
            game["connections"][websocket] = {"seats": [chosen_seat], "display_name": display_name, "user_id": user_id}
            await websocket.accept()
            await send_json(websocket, {"type": "player", "seats": [chosen_seat], "role": "player",
                                         "mode": game["mode"], "key": game_key if game["mode"] == "private" else None})
            await broadcast_all(game, f"{display_name} joined as {chosen_seat}")
        elif game["mode"] == "private":
            spec_id = game["next_spectator_id"]
            game["next_spectator_id"] += 1
            game["spectators"].append({"id": spec_id, "name": display_name, "user_id": user_id})
            _spectator_ws_map(game)[websocket] = spec_id
            await websocket.accept()
            await send_json(websocket, {"type": "player", "seats": [], "role": "spectator",
                                         "mode": game["mode"], "key": game_key})
            await broadcast_all(game, f"{display_name} joined as a spectator")
        else:
            await reject(websocket, 4405)
            return

    await start_round_if_ready(game)

    try:
        while True:
            data = await websocket.receive_text()
            message = json.loads(data)

            conn = game["connections"].get(websocket)
            is_spectator = websocket in _spectator_ws_map(game)
            r = game["round"]

            if message["type"] == "choose_trump" and conn and r and r["phase"] == "trump-selection":
                if r["trump_caller_seat"] not in conn["seats"]:
                    continue
                suit = message.get("suit")
                if suit not in SUITS:
                    continue
                deal_remaining(r, suit)
                await broadcast_all(game, f"{conn['display_name']} called {suit} as trump. Remaining cards dealt - 13 each.")
                await maybe_run_bot_turns(game)

            elif message["type"] == "play_card" and conn and r and r["phase"] == "playing":
                turn_seat = current_turn_seat(r)
                if turn_seat not in conn["seats"]:
                    continue
                card = message.get("card")
                if not card or not is_legal_move(r["hands"][turn_seat], r["led_suit"], card):
                    continue

                result = play_card(r, turn_seat, card)
                note = f"{conn['display_name']} played {card['rank']} of {card['suit']}."
                if result["trick_completed"]:
                    winner_seat = result["trick_winner_seat"]
                    note += f" {seat_controller_name(game, winner_seat)} won the trick."
                    if result["collected"]:
                        note += " Team collects the pile!"

                if result["round_completed"]:
                    record_result(game, r["winner"])
                    await broadcast_all(game, note)
                    await broadcast_all(game, f"Round over: Team {r['winner']} wins!", winner_override=r["winner"])
                else:
                    await broadcast_all(game, note)
                    await maybe_run_bot_turns(game)

            elif message["type"] == "next_round" and conn:
                if not r or r["phase"] != "round-over":
                    continue
                game["trump_caller_seat"] = next_seat(game["trump_caller_seat"])
                game["round"] = None
                await start_round_if_ready(game)

            elif message["type"] == "request_seat" and is_spectator and game["mode"] == "private":
                target_seat = message.get("seat")
                if target_seat not in occupied_seats(game):
                    continue
                if game["seat_request"] is not None:
                    continue
                spec_id = _spectator_ws_map(game)[websocket]
                spec = next(s for s in game["spectators"] if s["id"] == spec_id)
                game["seat_request"] = {"spectator_id": spec_id, "spectator_name": spec["name"],
                                         "spectator_user_id": spec["user_id"], "target_seat": target_seat}
                await broadcast_all(game, f"{spec['name']} has requested to take {target_seat}'s seat.")

            elif message["type"] == "respond_seat_request" and conn:
                req = game["seat_request"]
                if not req or req["target_seat"] not in conn["seats"]:
                    continue
                game["seat_request"] = None
                accept = bool(message.get("accept"))

                if not accept:
                    await broadcast_all(game, f"{conn['display_name']} declined to give up {req['target_seat']}'s seat.")
                    continue

                target_seat = req["target_seat"]
                requester_ws = next((w for w, sid in _spectator_ws_map(game).items() if sid == req["spectator_id"]), None)
                if requester_ws is None:
                    continue

                conn["seats"].remove(target_seat)
                _spectator_ws_map(game).pop(requester_ws, None)
                game["spectators"] = [s for s in game["spectators"] if s["id"] != req["spectator_id"]]

                game["connections"][requester_ws] = {"seats": [target_seat], "display_name": req["spectator_name"], "user_id": req["spectator_user_id"]}

                became_spectator = not conn["seats"]
                if became_spectator:
                    del game["connections"][websocket]
                    new_spec_id = game["next_spectator_id"]
                    game["next_spectator_id"] += 1
                    game["spectators"].append({"id": new_spec_id, "name": conn["display_name"], "user_id": conn["user_id"]})
                    _spectator_ws_map(game)[websocket] = new_spec_id

                await send_json(requester_ws, {"type": "player", "seats": [target_seat], "role": "player",
                                                "mode": game["mode"], "key": key if game["mode"] == "private" else None})
                if became_spectator:
                    await send_json(websocket, {"type": "player", "seats": [], "role": "spectator",
                                                 "mode": game["mode"], "key": key if game["mode"] == "private" else None})
                await broadcast_all(game, f"{req['spectator_name']} took over {target_seat}'s seat.")

            elif message["type"] == "leave_table" and conn:
                seats_to_vacate = list(conn["seats"])
                del game["connections"][websocket]

                new_spec_id = game["next_spectator_id"]
                game["next_spectator_id"] += 1
                game["spectators"].append({"id": new_spec_id, "name": display_name, "user_id": user_id})
                _spectator_ws_map(game)[websocket] = new_spec_id
                await send_json(websocket, {"type": "player", "seats": [], "role": "spectator",
                                             "mode": game["mode"], "key": key if game["mode"] == "private" else None})

                for s in seats_to_vacate:
                    if game["mode"] == "private" and game["spectators"]:
                        promoted = game["spectators"].pop(0)  # FIFO: first (oldest) in queue
                        promoted_ws = next((w for w, sid in _spectator_ws_map(game).items() if sid == promoted["id"]), None)
                        if promoted_ws is not None:
                            _spectator_ws_map(game).pop(promoted_ws, None)
                            game["connections"][promoted_ws] = {"seats": [s], "display_name": promoted["name"], "user_id": promoted["user_id"]}
                            await send_json(promoted_ws, {"type": "player", "seats": [s], "role": "player",
                                                           "mode": game["mode"], "key": key if game["mode"] == "private" else None})

                await broadcast_all(game, f"{display_name} left the table.")
                await start_round_if_ready(game)

    except WebSocketDisconnect:
        if websocket in _spectator_ws_map(game):
            spec_id = _spectator_ws_map(game).pop(websocket)
            game["spectators"] = [s for s in game["spectators"] if s["id"] != spec_id]
            if game["seat_request"] and game["seat_request"]["spectator_id"] == spec_id:
                game["seat_request"] = None

        elif websocket in game["connections"]:
            exited_seats = game["connections"][websocket]["seats"]
            exited_name = game["connections"][websocket]["display_name"]
            del game["connections"][websocket]

            if game["seat_request"] and game["seat_request"]["target_seat"] in exited_seats:
                game["seat_request"] = None

            if not game["connections"]:
                games.pop(game_key, None)
            else:
                for s in exited_seats:
                    if game["mode"] == "private" and game["spectators"]:
                        promoted = game["spectators"].pop(0)
                        promoted_ws = next((w for w, sid in _spectator_ws_map(game).items() if sid == promoted["id"]), None)
                        if promoted_ws is not None:
                            _spectator_ws_map(game).pop(promoted_ws, None)
                            game["connections"][promoted_ws] = {"seats": [s], "display_name": promoted["name"], "user_id": promoted["user_id"]}
                            await send_json(promoted_ws, {"type": "player", "seats": [s], "role": "player",
                                                           "mode": game["mode"], "key": key if game["mode"] == "private" else None})
                await broadcast_all(game, f"{exited_name} disconnected.")
                if game["round"] is None:
                    await start_round_if_ready(game)
