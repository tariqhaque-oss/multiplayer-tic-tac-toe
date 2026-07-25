from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel

from config import BOT_DIFFICULTIES
from db import db_execute
from game import get_bot_user_id
from security import get_session

router = APIRouter()


class OfflineResult(BaseModel):
    difficulty: str
    my_symbol: str
    winner: str
    played_at: str | None = None


class SyncOfflineResultsBody(BaseModel):
    results: list[OfflineResult]


@router.get("/api/stats")
def get_stats(request: Request):
    session = get_session(request)
    if not session:
        return JSONResponse({"error": "unauthorized"}, status_code=401)

    user_id = session["user_id"]

    rows = db_execute(
        """
        SELECT mode, winner,
               CASE WHEN player_x_id = %s THEN 'X' ELSE 'O' END AS my_symbol,
               CASE WHEN player_x_id = %s THEN player_o_id ELSE player_x_id END AS opponent_id
        FROM game_results
        WHERE player_x_id = %s OR player_o_id = %s
        """,
        (user_id, user_id, user_id, user_id),
        fetch="all",
    )

    opponent_ids = sorted({opponent_id for (_, _, _, opponent_id) in rows})
    nickname_map = {}
    if opponent_ids:
        nickname_rows = db_execute(
            "SELECT id, nickname FROM users WHERE id = ANY(%s)",
            (opponent_ids,),
            fetch="all",
        )
        nickname_map = {row_id: nickname for row_id, nickname in nickname_rows}

    def empty_bucket():
        return {"games": 0, "wins": 0, "losses": 0, "draws": 0}

    def tally(bucket, winner, my_symbol):
        bucket["games"] += 1
        if winner == my_symbol:
            bucket["wins"] += 1
        elif winner == "Draw":
            bucket["draws"] += 1
        else:
            bucket["losses"] += 1

    overall = empty_bucket()
    random_bucket = empty_bucket()
    opponents = {}

    for mode, winner, my_symbol, opponent_id in rows:
        tally(overall, winner, my_symbol)

        if mode == "random":
            tally(random_bucket, winner, my_symbol)
        else:
            nickname = nickname_map.get(opponent_id, "Unknown")
            bucket = opponents.setdefault(nickname, empty_bucket())
            tally(bucket, winner, my_symbol)

    return JSONResponse({
        "overall": overall,
        "random": random_bucket,
        "opponents": [{"nickname": nickname, **bucket} for nickname, bucket in sorted(opponents.items())],
    })


@router.post("/api/stats/sync-offline-results")
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
        if result.my_symbol not in ("X", "O"):
            continue
        if result.winner not in ("X", "O", "Draw"):
            continue

        bot_user_id = get_bot_user_id(difficulty)
        if result.my_symbol == "X":
            x_id, o_id = user_id, bot_user_id
        else:
            x_id, o_id = bot_user_id, user_id

        if result.played_at:
            db_execute(
                "INSERT INTO game_results (mode, player_x_id, player_o_id, winner, played_at) "
                "VALUES ('bot', %s, %s, %s, %s)",
                (x_id, o_id, result.winner, result.played_at),
                commit=True,
            )
        else:
            db_execute(
                "INSERT INTO game_results (mode, player_x_id, player_o_id, winner) VALUES ('bot', %s, %s, %s)",
                (x_id, o_id, result.winner),
                commit=True,
            )
        synced += 1

    return JSONResponse({"ok": True, "synced": synced})
