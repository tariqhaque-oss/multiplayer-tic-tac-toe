from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse

from db import db_execute
from security import get_session

router = APIRouter()


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
