from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse

from db import db_execute
from security import get_session

router = APIRouter()


@router.get("/api/connect4/stats")
def get_stats(request: Request):
    session = get_session(request)
    if not session:
        return JSONResponse({"error": "unauthorized"}, status_code=401)

    user_id = session["user_id"]

    rows = db_execute(
        """
        SELECT mode, winner,
               CASE WHEN player_red_id = %s THEN 'R' ELSE 'Y' END AS my_symbol,
               CASE WHEN player_red_id = %s THEN player_yellow_id ELSE player_red_id END AS opponent_id
        FROM connect4_results
        WHERE player_red_id = %s OR player_yellow_id = %s
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
