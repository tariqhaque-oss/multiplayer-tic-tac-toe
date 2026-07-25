import secrets

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel

from config import BOT_DIFFICULTIES
from db import db_execute
from ludo import COLORS, get_bot_user_id
from security import get_session

router = APIRouter()


class OfflineResult(BaseModel):
    difficulty: str
    my_symbol: str  # the human's color (R/G/Y/B) - named my_symbol for
    # consistency with the other games' offline-sync payload shape.
    winner: str  # "R"/"G"/"Y"/"B" if a token finished, or "None" if the
    # practice session was abandoned before anyone won (not currently
    # sent by the app, but accepted defensively).
    played_at: str | None = None


class SyncOfflineResultsBody(BaseModel):
    results: list[OfflineResult]


@router.get("/api/ludo/stats")
def get_stats(request: Request):
    session = get_session(request)
    if not session:
        return JSONResponse({"error": "unauthorized"}, status_code=401)

    user_id = session["user_id"]

    rows = db_execute(
        "SELECT mode, winner, round_id FROM ludo_results WHERE player_id = %s",
        (user_id,),
        fetch="all",
    )

    round_ids = [round_id for (_, _, round_id) in rows]
    opponents_by_round = {}
    if round_ids:
        opponent_rows = db_execute(
            """
            SELECT lr.round_id, u.nickname
            FROM ludo_results lr
            JOIN users u ON u.id = lr.player_id
            WHERE lr.round_id = ANY(%s) AND lr.player_id != %s
            ORDER BY lr.round_id, u.nickname
            """,
            (round_ids, user_id),
            fetch="all",
        )
        for round_id, nickname in opponent_rows:
            opponents_by_round.setdefault(round_id, []).append(nickname)

    def empty_bucket():
        return {"games": 0, "wins": 0, "losses": 0, "draws": 0}

    def tally(bucket, winner):
        bucket["games"] += 1
        if winner:
            bucket["wins"] += 1
        else:
            bucket["losses"] += 1

    overall = empty_bucket()
    random_bucket = empty_bucket()
    opponents = {}

    for mode, winner, round_id in rows:
        tally(overall, winner)

        if mode == "random":
            tally(random_bucket, winner)
        else:
            nicknames = opponents_by_round.get(round_id, [])
            if nicknames:
                label = ", ".join(nicknames)
                bucket = opponents.setdefault(label, empty_bucket())
                tally(bucket, winner)

    return JSONResponse({
        "overall": overall,
        "random": random_bucket,
        "opponents": [{"nickname": nickname, **bucket} for nickname, bucket in sorted(opponents.items())],
    })


@router.post("/api/ludo/stats/sync-offline-results")
def sync_offline_results(request: Request, body: SyncOfflineResultsBody):
    session = get_session(request)
    if not session:
        return JSONResponse({"error": "unauthorized"}, status_code=401)

    user_id = session["user_id"]
    synced = 0

    for result in body.results:
        difficulty = result.difficulty.strip().lower()
        if difficulty not in BOT_DIFFICULTIES:
            continue
        if result.my_symbol not in COLORS:
            continue

        won = result.winner == result.my_symbol
        round_id = secrets.token_hex(8)

        if result.played_at:
            db_execute(
                "INSERT INTO ludo_results (mode, round_id, player_id, color, winner, played_at) "
                "VALUES ('bot', %s, %s, %s, %s, %s)",
                (round_id, user_id, result.my_symbol, won, result.played_at),
                commit=True,
            )
        else:
            db_execute(
                "INSERT INTO ludo_results (mode, round_id, player_id, color, winner) VALUES ('bot', %s, %s, %s, %s)",
                (round_id, user_id, result.my_symbol, won),
                commit=True,
            )
        synced += 1

    return JSONResponse({"ok": True, "synced": synced})
