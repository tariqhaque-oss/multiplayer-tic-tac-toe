import secrets

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel

from db import db_execute
from security import get_session

router = APIRouter()

TEAM_OF = {"P1": "A", "P3": "A", "P2": "B", "P4": "B"}


class OfflineResult(BaseModel):
    difficulty: str  # unused (the bot AI has no difficulty levels) - kept
    # for payload-shape consistency with the other games' offline queue.
    my_symbol: str  # the human's seat, offline play always seats them at P1
    winner: str  # "A" or "B" - the winning team
    played_at: str | None = None


class SyncOfflineResultsBody(BaseModel):
    results: list[OfflineResult]


@router.get("/api/court-piece/stats")
def get_stats(request: Request):
    session = get_session(request)
    if not session:
        return JSONResponse({"error": "unauthorized"}, status_code=401)

    user_id = session["user_id"]

    rows = db_execute(
        "SELECT mode, winner, round_id FROM court_piece_results WHERE player_id = %s",
        (user_id,),
        fetch="all",
    )

    round_ids = [round_id for (_, _, round_id) in rows]
    opponents_by_round = {}
    if round_ids:
        opponent_rows = db_execute(
            """
            SELECT cpr.round_id, u.nickname
            FROM court_piece_results cpr
            JOIN users u ON u.id = cpr.player_id
            WHERE cpr.round_id = ANY(%s) AND cpr.player_id != %s
            ORDER BY cpr.round_id, u.nickname
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


@router.post("/api/court-piece/stats/sync-offline-results")
def sync_offline_results(request: Request, body: SyncOfflineResultsBody):
    session = get_session(request)
    if not session:
        return JSONResponse({"error": "unauthorized"}, status_code=401)

    user_id = session["user_id"]
    synced = 0

    for result in body.results:
        if result.my_symbol not in TEAM_OF:
            continue
        if result.winner not in ("A", "B"):
            continue

        won = result.winner == TEAM_OF[result.my_symbol]
        round_id = secrets.token_hex(8)

        if result.played_at:
            db_execute(
                "INSERT INTO court_piece_results (mode, round_id, player_id, seat, team, winner, played_at) "
                "VALUES ('bot', %s, %s, %s, %s, %s, %s)",
                (round_id, user_id, result.my_symbol, TEAM_OF[result.my_symbol], won, result.played_at),
                commit=True,
            )
        else:
            db_execute(
                "INSERT INTO court_piece_results (mode, round_id, player_id, seat, team, winner) VALUES ('bot', %s, %s, %s, %s, %s)",
                (round_id, user_id, result.my_symbol, TEAM_OF[result.my_symbol], won),
                commit=True,
            )
        synced += 1

    return JSONResponse({"ok": True, "synced": synced})
