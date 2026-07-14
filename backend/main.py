import os
import re
import secrets
import hashlib
import smtplib
import ssl
import json
import random
import asyncio
from email.message import EmailMessage

import bcrypt
import psycopg2
import psycopg2.errors
import psycopg2.pool
from dotenv import load_dotenv
from fastapi import FastAPI, WebSocket, WebSocketDisconnect, Request, Form
from fastapi.staticfiles import StaticFiles
from fastapi.responses import FileResponse, RedirectResponse, JSONResponse

from itsdangerous import URLSafeTimedSerializer, BadSignature, SignatureExpired

load_dotenv(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".env"))

app = FastAPI()

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
STATIC_DIR = os.path.join(BASE_DIR, "static")

app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")


def hash_password(password):
    return bcrypt.hashpw(password.encode("utf-8"), bcrypt.gensalt()).decode("utf-8")


def verify_password(password, password_hash):
    return bcrypt.checkpw(password.encode("utf-8"), password_hash.encode("utf-8"))


def generate_token():
    return secrets.token_urlsafe(32)


def hash_token(token):
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


SESSION_SECRET = os.environ.get("SESSION_SECRET")
if not SESSION_SECRET:
    SESSION_SECRET = secrets.token_hex(32)
    print("WARNING: SESSION_SECRET not set, using a random key for this run. "
          "Existing sessions will be invalidated on every restart. "
          "Set the SESSION_SECRET env var for persistent sessions.")

serializer = URLSafeTimedSerializer(SESSION_SECRET)
SESSION_COOKIE = "session"
SESSION_MAX_AGE = 60 * 60 * 24 * 7  # 7 days

EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
NICKNAME_RE = re.compile(r"^[A-Za-z0-9_]{3,24}$")

GMAIL_SENDER = os.environ.get("GMAIL_SENDER")
GMAIL_APP_PASSWORD = os.environ.get("GMAIL_APP_PASSWORD")

db_pool = psycopg2.pool.SimpleConnectionPool(
    1, 10,
    host=os.environ.get("PGHOST", "localhost"),
    port=os.environ.get("PGPORT", "5432"),
    dbname=os.environ.get("PGDATABASE", "tictactoe"),
    user=os.environ.get("PGUSER", "tictactoe_app"),
    password=os.environ.get("PGPASSWORD"),
)


def db_execute(query, params=(), fetch=None, commit=False):
    conn = db_pool.getconn()
    try:
        with conn.cursor() as cur:
            cur.execute(query, params)
            result = None
            if fetch == "one":
                result = cur.fetchone()
            elif fetch == "all":
                result = cur.fetchall()
            if commit:
                conn.commit()
            return result
    finally:
        db_pool.putconn(conn)


def send_email(to_address, subject, body):
    if not GMAIL_SENDER or not GMAIL_APP_PASSWORD:
        print(f"WARNING: GMAIL_SENDER/GMAIL_APP_PASSWORD not set. Would have emailed {to_address}: {subject}\n{body}")
        return

    msg = EmailMessage()
    msg["Subject"] = subject
    msg["From"] = GMAIL_SENDER
    msg["To"] = to_address
    msg.set_content(body)

    context = ssl.create_default_context()
    with smtplib.SMTP("smtp.gmail.com", 587) as server:
        server.starttls(context=context)
        server.login(GMAIL_SENDER, GMAIL_APP_PASSWORD)
        server.send_message(msg)


def build_base_url(request: Request):
    host = request.headers.get("host", request.url.netloc)
    scheme = "http" if host.startswith("localhost") or host.startswith("127.0.0.1") else "https"
    return f"{scheme}://{host}"


def is_password_reused(user_id, current_hash, new_password):
    if verify_password(new_password, current_hash):
        return True

    rows = db_execute(
        "SELECT password_hash FROM password_history WHERE user_id = %s",
        (user_id,),
        fetch="all",
    )
    for (old_hash,) in rows:
        if verify_password(new_password, old_hash):
            return True

    return False


def create_session_cookie(user_id, email, nickname):
    return serializer.dumps({"user_id": user_id, "email": email, "nickname": nickname})


def read_session_cookie(token):
    if not token:
        return None
    try:
        data = serializer.loads(token, max_age=SESSION_MAX_AGE)
    except (BadSignature, SignatureExpired):
        return None
    if "user_id" not in data:
        return None
    return data


def get_session(request: Request):
    return read_session_cookie(request.cookies.get(SESSION_COOKIE))


@app.get("/login")
def login_page():
    return FileResponse(os.path.join(STATIC_DIR, "login.html"))


@app.get("/signup")
def signup_page():
    return FileResponse(os.path.join(STATIC_DIR, "signup.html"))


@app.post("/signup")
def signup(request: Request, email: str = Form(...), nickname: str = Form(...),
           password: str = Form(...), confirm_password: str = Form(...)):
    email = email.strip().lower()
    nickname = nickname.strip()

    if not EMAIL_RE.match(email):
        return RedirectResponse("/signup?error=invalid_email", status_code=303)

    if not NICKNAME_RE.match(nickname):
        return RedirectResponse("/signup?error=invalid_nickname", status_code=303)

    if password != confirm_password:
        return RedirectResponse("/signup?error=mismatch", status_code=303)

    if len(password) < 8 or len(password.encode("utf-8")) > 72:
        return RedirectResponse("/signup?error=weak", status_code=303)

    password_hash = hash_password(password)

    existing = db_execute("SELECT 1 FROM users WHERE email = %s", (email,), fetch="one")
    if existing:
        return RedirectResponse("/signup?error=taken", status_code=303)

    existing_nickname = db_execute("SELECT 1 FROM users WHERE LOWER(nickname) = LOWER(%s)", (nickname,), fetch="one")
    if existing_nickname:
        return RedirectResponse("/signup?error=nickname_taken", status_code=303)

    try:
        row = db_execute(
            "INSERT INTO users (email, nickname, password_hash) VALUES (%s, %s, %s) RETURNING id",
            (email, nickname, password_hash),
            fetch="one",
            commit=True,
        )
    except psycopg2.errors.UniqueViolation:
        return RedirectResponse("/signup?error=taken", status_code=303)

    user_id = row[0]

    token = generate_token()
    db_execute(
        "INSERT INTO email_verification_tokens (user_id, token_hash, expires_at) "
        "VALUES (%s, %s, now() + interval '24 hours')",
        (user_id, hash_token(token)),
        commit=True,
    )

    verify_link = f"{build_base_url(request)}/verify-email?token={token}"
    send_email(
        email,
        "Verify your Tic Tac Toe account",
        f"Click the link below to verify your email and activate your account:\n\n{verify_link}\n\n"
        "This link expires in 24 hours.",
    )

    return RedirectResponse("/login?created=1", status_code=303)


@app.get("/verify-email")
def verify_email(token: str):
    token_hash = hash_token(token)
    row = db_execute(
        "SELECT user_id FROM email_verification_tokens WHERE token_hash = %s AND used_at IS NULL AND expires_at > now()",
        (token_hash,),
        fetch="one",
    )

    if not row:
        return RedirectResponse("/login?error=invalid_token", status_code=303)

    user_id = row[0]
    db_execute("UPDATE users SET email_verified = true WHERE id = %s", (user_id,), commit=True)
    db_execute("UPDATE email_verification_tokens SET used_at = now() WHERE token_hash = %s", (token_hash,), commit=True)

    return RedirectResponse("/login?verified=1", status_code=303)


@app.post("/resend-verification")
def resend_verification(request: Request, email: str = Form(...)):
    email = email.strip().lower()
    row = db_execute("SELECT id, email_verified FROM users WHERE email = %s", (email,), fetch="one")

    if row and not row[1]:
        user_id = row[0]
        token = generate_token()
        db_execute(
            "INSERT INTO email_verification_tokens (user_id, token_hash, expires_at) "
            "VALUES (%s, %s, now() + interval '24 hours')",
            (user_id, hash_token(token)),
            commit=True,
        )

        verify_link = f"{build_base_url(request)}/verify-email?token={token}"
        send_email(
            email,
            "Verify your Tic Tac Toe account",
            f"Click the link below to verify your email and activate your account:\n\n{verify_link}\n\n"
            "This link expires in 24 hours.",
        )

    return RedirectResponse("/login?resent=1", status_code=303)


@app.post("/login")
def login(email: str = Form(...), password: str = Form(...)):
    email = email.strip().lower()
    row = db_execute(
        "SELECT id, password_hash, email_verified, nickname FROM users WHERE email = %s",
        (email,),
        fetch="one",
    )

    if not row or len(password.encode("utf-8")) > 72 or not verify_password(password, row[1]):
        return RedirectResponse("/login?error=invalid", status_code=303)

    if not row[2]:
        return RedirectResponse("/login?error=unverified", status_code=303)

    user_id, nickname = row[0], row[3]

    redirect = RedirectResponse("/games", status_code=303)
    redirect.set_cookie(
        SESSION_COOKIE,
        create_session_cookie(user_id, email, nickname),
        max_age=SESSION_MAX_AGE,
        httponly=True,
        samesite="lax",
    )
    return redirect


@app.get("/logout")
def logout():
    redirect = RedirectResponse("/login?logged_out=1", status_code=303)
    redirect.delete_cookie(SESSION_COOKIE)
    return redirect


@app.get("/forgot-password")
def forgot_password_page():
    return FileResponse(os.path.join(STATIC_DIR, "forgot-password.html"))


@app.post("/forgot-password")
def forgot_password(request: Request, email: str = Form(...)):
    email = email.strip().lower()
    row = db_execute("SELECT id FROM users WHERE email = %s", (email,), fetch="one")

    if row:
        user_id = row[0]
        token = generate_token()
        db_execute(
            "INSERT INTO password_reset_tokens (user_id, token_hash, expires_at) "
            "VALUES (%s, %s, now() + interval '1 hour')",
            (user_id, hash_token(token)),
            commit=True,
        )

        reset_link = f"{build_base_url(request)}/reset-password?token={token}"
        send_email(
            email,
            "Reset your Tic Tac Toe password",
            f"Click the link below to choose a new password:\n\n{reset_link}\n\n"
            "This link expires in 1 hour. If you didn't request this, you can ignore this email.",
        )

    return RedirectResponse("/login?reset_requested=1", status_code=303)


@app.get("/reset-password")
def reset_password_page():
    return FileResponse(os.path.join(STATIC_DIR, "reset-password.html"))


@app.post("/reset-password")
def reset_password(token: str = Form(...), new_password: str = Form(...), confirm_new_password: str = Form(...)):
    token_hash = hash_token(token)
    row = db_execute(
        "SELECT user_id FROM password_reset_tokens WHERE token_hash = %s AND used_at IS NULL AND expires_at > now()",
        (token_hash,),
        fetch="one",
    )

    if not row:
        return RedirectResponse("/login?error=invalid_reset_link", status_code=303)

    user_id = row[0]

    if new_password != confirm_new_password:
        return RedirectResponse(f"/reset-password?token={token}&error=mismatch", status_code=303)

    if len(new_password) < 8 or len(new_password.encode("utf-8")) > 72:
        return RedirectResponse(f"/reset-password?token={token}&error=weak", status_code=303)

    current_hash = db_execute("SELECT password_hash FROM users WHERE id = %s", (user_id,), fetch="one")[0]

    if is_password_reused(user_id, current_hash, new_password):
        return RedirectResponse(f"/reset-password?token={token}&error=reused", status_code=303)

    new_hash = hash_password(new_password)

    db_execute("INSERT INTO password_history (user_id, password_hash) VALUES (%s, %s)", (user_id, current_hash), commit=True)
    db_execute("UPDATE users SET password_hash = %s WHERE id = %s", (new_hash, user_id), commit=True)
    db_execute("UPDATE password_reset_tokens SET used_at = now() WHERE token_hash = %s", (token_hash,), commit=True)

    return RedirectResponse("/login?reset_done=1", status_code=303)


@app.get("/")
def home(request: Request):
    session = get_session(request)
    if not session:
        return RedirectResponse("/login")
    return RedirectResponse("/games")


@app.get("/games")
def games_hub(request: Request):
    session = get_session(request)
    if not session:
        return RedirectResponse("/login")
    return FileResponse(os.path.join(STATIC_DIR, "games.html"))


@app.get("/games/tic-tac-toe")
def tic_tac_toe_page(request: Request):
    session = get_session(request)
    if not session:
        return RedirectResponse("/login")
    return FileResponse(os.path.join(STATIC_DIR, "index.html"))


@app.get("/api/stats")
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


winning_combinations = [
    [0,1,2], [3,4,5], [6,7,8],
    [0,3,6], [1,4,7], [2,5,8],
    [0,4,8], [2,4,6]
]

KEY_RE = re.compile(r"^[A-Za-z0-9]{5}$")

games = {}  # key -> game state dict, at most 2 connections each

BOT_DIFFICULTIES = {"easy", "medium", "hard"}
BOT_EMAILS = {
    "easy": "bot-easy@system.local",
    "medium": "bot-medium@system.local",
    "hard": "bot-hard@system.local",
}
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


@app.websocket("/ws")
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
