# GameHub Architecture

Two documents cover this app: this one explains *what exists and why*, in
full technical detail. `deployment guide.txt` explains *how to operate
it* (exact commands, cmd.exe walkthroughs, process management, and the
local-to-cloud migration plan) - the two overlap a little on purpose.

## Quick overview

```mermaid
flowchart TD
    You(["🧑 You<br/>your web browser"])
    Door["🚪 Front Door<br/>alaab.ai<br/>sends each request to the right place"]
    Website["🖥️ The Website<br/>the pages you see and click:<br/>login, sign up, game board"]
    Server["⚙️ The Game Server<br/>checks who you are, runs the games,<br/>keeps score"]
    Database[("🗄️ The Database<br/>remembers accounts, passwords,<br/>and game history")]
    Email["📧 Email<br/>sends verification and<br/>password-reset links"]

    You <--> Door
    Door <--> Website
    Door <--> Server
    Server <--> Database
    Server --> Email
    Email --> You
```

In plain terms: the **Website** is passive (just pages), the **Game
Server** is the brain (checks passwords, runs the games, decides
winners), the **Database** is the filing cabinet, **Email** is used only
for signup verification and password resets, and the **Front Door**
(Caddy) makes the Website and Game Server - two genuinely separate
programs - look like one site to your browser. Everything below explains
exactly how, with real file names, real ports, and real commands.

---

## How many of each thing are actually running

| Component  | How many | Notes |
|---|---|---|
| Backend (uvicorn/FastAPI) | **1 process, 1 worker** | No load balancing, no auto-restart on crash. Game/WebSocket state (a separate `games` dict in each of `game.py`, `connect4.py`, and `ludo.py`) lives only in this one process's memory - this is *why* it must stay at exactly one process; a second instance wouldn't share in-progress games. |
| Database (Postgres) | **1 cluster, 1 instance** | Self-managed, no replica, no automated backups. |
| Caddy (reverse proxy) | **1 process, 2 site blocks** | One process serves both the public `alaab.ai` domain and the local-only `:8080` block - see below. |
| Frontend | **0 processes** | It's static files (HTML/CSS/JS). No server of its own - Caddy serves the files directly from disk. |

Everything runs on one Windows laptop today (see `deployment guide.txt`
section 1 for the full network path from the internet down to this
machine, and section 3 for what a cloud move would change).

---

## Caddy - the traffic router (`infra/Caddyfile`)

Caddy is the only thing on this laptop with its ports open to the
internet (80 and 443). Its whole job is: look at the incoming request's
*path*, and either (a) hand it to the backend process, or (b) serve a
file straight off disk. It never runs any app logic itself.

The Caddyfile defines one reusable block of rules (a "snippet" called
`app_routes`) and imports it into two separate sites:

```
(app_routes) {
    handle /api/* { reverse_proxy localhost:8000 }
    handle /ws    { reverse_proxy localhost:8000 }
    handle /ws/connect4 { reverse_proxy localhost:8000 }
    handle /ws/ludo { reverse_proxy localhost:8000 }
    handle /static/* { root * ../frontend        file_server }
    handle            { root * ../frontend/pages file_server }
}

alaab.ai { redir / /games.html;  import app_routes }   # public, auto-HTTPS
:8080    { redir / /games.html;  import app_routes }   # local-only, plain HTTP
```

Routing rules, in the order Caddy actually checks them:

| Request path | Goes to | Example |
|---|---|---|
| `/api/*` | **Backend**, `reverse_proxy localhost:8000` | `/api/auth/login`, `/api/stats`, `/api/connect4/stats`, `/api/ludo/stats` |
| `/ws` | **Backend**, `reverse_proxy localhost:8000` (WebSocket upgrade) | the live Tic Tac Toe connection |
| `/ws/connect4` | **Backend**, `reverse_proxy localhost:8000` (WebSocket upgrade) | the live Connect Four connection - needs its own `handle` block since Caddy's `handle /ws` only matches that exact path, not sub-paths |
| `/ws/ludo` | **Backend**, `reverse_proxy localhost:8000` (WebSocket upgrade) | the live Ludo connection - same reason, needs its own `handle` block |
| `/static/*` | **Disk**, `frontend/` directory | `/static/css/style.css` → `frontend/static/css/style.css` |
| `/` (exactly) | **Redirect** to `/games.html` | `alaab.ai/` → `alaab.ai/games.html` |
| anything else | **Disk**, `frontend/pages/` directory | `/login.html` → `frontend/pages/login.html` |

Because both the "website" files and the "API" are reachable under the
*same* address (`alaab.ai` or `localhost:8080`), the browser sees one
origin - that's what lets the frontend's JavaScript call the backend
with a plain `fetch()` and no special cross-site cookie configuration
(see `deployment guide.txt` section 3i for what would need to change if
that ever stopped being true).

Other things Caddy does automatically, with no config needed:
- **HTTPS certificates**: for `alaab.ai`, Caddy requests and renews a
  free Let's Encrypt certificate on its own (an "ACME HTTP-01 challenge"
  - it briefly answers a request from Let's Encrypt over port 80 to
  prove it controls the domain, then gets a real cert). The `:8080`
  local block has no TLS - it's plain HTTP, for testing on this machine
  without needing a domain at all.
- **HTTP → HTTPS redirect** on the public site.
- **Admin API** on `127.0.0.1:2019` - Caddy's own internal control port,
  not reachable from outside this machine, used for live config reloads
  (not something this app relies on directly).

Caddy's own logs (stdout/stderr when started by `deploy.py`) land in
`infra/caddy.log`.

---

## Backend - the API process (`backend/`)

A single FastAPI app (`main.py`) that returns **JSON and WebSocket
messages only - never HTML**. It has no idea the frontend exists; it just
checks a session cookie on each request.

| File | Responsibility |
|---|---|
| `main.py` | Creates the FastAPI app, includes the three routers below. That's it - 9 lines. |
| `config.py` | Loads `.env`, defines constants: DB connection settings, session cookie settings, email regex/nickname regex/private-game-code regex, bot account emails. |
| `db.py` | A `psycopg2` connection pool (1-10 connections) and one helper function, `db_execute()`, that every query in the app goes through. |
| `security.py` | Password hashing (`bcrypt`), token generation/hashing, and the signed session cookie (`itsdangerous` - the cookie is cryptographically signed so it can't be forged, using `SESSION_SECRET`). |
| `email_utils.py` | Sends email via Gmail SMTP; builds the `https://alaab.ai/...` base URL used in verification/reset links. |
| `auth_routes.py` | Everything under `/api/auth/*` - see endpoint table below. |
| `stats_routes.py` | `/api/stats` (Tic Tac Toe) only. |
| `game.py` | The `/ws` WebSocket endpoint, the tic-tac-toe rules (win/draw detection), the bot AI (minimax for "hard", simple heuristics for "easy"/"medium"), and the in-memory `games` dict that holds every live match. |
| `connect4_stats_routes.py` | `/api/connect4/stats` only. |
| `connect4.py` | The `/ws/connect4` WebSocket endpoint, Connect Four's rules (7x6 gravity board, 4-in-a-row detection in all 4 directions), the bot AI (depth-limited minimax with alpha-beta pruning and a heuristic evaluation for "hard", since Connect Four's search tree is far too large to solve exhaustively like tic-tac-toe's), and its own in-memory `games` dict - a separate object from `game.py`'s, so the two games share no runtime state. |
| `ludo_stats_routes.py` | `/api/ludo/stats` only. |
| `ludo.py` | The `/ws/ludo` WebSocket endpoint, Ludo's rules (2-4 player token race, dice rolls, captures, home stretches - see "Ludo specifics" below), a greedy heuristic bot AI (dice randomness makes deep search largely pointless, unlike Connect Four), and its own in-memory `games` dict, independent of the other two. |

### Every backend endpoint that exists

There is nothing else - no page routes, no admin panel, nothing. This is
the entire surface area:

| Method | Path | What it does |
|---|---|---|
| POST | `/api/auth/signup` | Create account, email a verification link |
| GET | `/api/auth/verify-email?token=` | Validates the emailed link, marks the account verified, **redirects** to `/login.html` (the one place the backend still issues a redirect, since it's answering a browser click from an email, not a `fetch()` call) |
| POST | `/api/auth/resend-verification` | Re-sends the verification email |
| POST | `/api/auth/login` | Checks credentials, sets the session cookie |
| POST | `/api/auth/logout` | Clears the session cookie |
| GET | `/api/auth/me` | Returns who's currently logged in (or `authenticated: false`) - this is what the frontend calls on page load to decide whether to redirect to the login page |
| POST | `/api/auth/forgot-password` | Emails a password reset link |
| POST | `/api/auth/reset-password` | Validates the reset token, sets a new password |
| GET | `/api/stats` | Per-player Tic Tac Toe win/loss/draw stats, broken down by opponent |
| WS | `/ws?intent=...` | The live Tic Tac Toe connection - moves, board state, scores, bot play |
| GET | `/api/connect4/stats` | Per-player Connect Four win/loss/draw stats, broken down by opponent (same shape as `/api/stats`, separate table) |
| WS | `/ws/connect4?intent=...` | The live Connect Four connection - column drops, board state, scores, bot play |
| GET | `/api/ludo/stats` | Per-player Ludo win/loss/draw stats, broken down by opponent(s) - a private round can have more than one opponent, so the "opponent" label is a joined list of nicknames when there's more than one |
| WS | `/ws/ludo?intent=...` | The live Ludo connection - dice rolls, token moves, board state, scores, bot play; up to 4 connections per game instead of 2 |

### Ludo specifics

Ludo needed a genuinely different design from the other two games, since it
supports 2-4 players instead of exactly 2:

- **Seats**: 4 fixed colors, Red/Green/Yellow/Blue, assigned in that order
  as connections arrive. Turn order is always R→G→Y→B, skipping colors
  with no seat filled - so a 2-human private game just alternates between
  those two colors, no bots involved.
- **"vs Bot" mode is a separate matchmaking path**, same as the other two
  games: the human always takes Red, and Green/Yellow/Blue are immediately
  filled by bots at the chosen difficulty (one bot account can occupy
  multiple color seats in the same game - it's just a `user_id` reference
  for recording results, not a live connection).
- **Board model**: each token's position is a single integer, -1 (in the
  yard) through 56 (home/finished). Positions 0-50 map onto the shared
  52-cell path via `(color's entry offset + position) % 52`; positions
  51-56 are that color's private 6-cell home stretch, immune to capture.
  A move that would overshoot past 56 is illegal (must roll the exact
  number to finish, the standard Ludo rule).
- **Bot AI**: unlike Connect Four's minimax, Ludo's bot doesn't search
  ahead - dice randomness makes multi-ply search far less useful. Instead
  it's a greedy heuristic per difficulty (easy: random legal token;
  medium/hard: prefer capturing an opponent, then finishing a token, then
  the token making the most progress; hard additionally penalizes ending
  its turn exposed on an unsafe shared-path cell).
- **Frontend board rendering is schematic, not a literal cross-shaped
  board**: the 52 shared-path cells render as a wrapped 13x4 grid in plain
  numeric order, with each color's yard and home stretch as separate
  labeled strips. This was a deliberate simplification to avoid needing
  hand-verified pixel/cell coordinate tables for the traditional 15x15
  cross layout - the game logic and turn order are unaffected either way.

### Request lifecycle example: logging in

1. Browser: `POST https://alaab.ai/api/auth/login` with `{email, password}` as JSON.
2. Caddy sees `/api/*`, reverse-proxies it to `localhost:8000` (untouched, same request).
3. `auth_routes.login()` looks up the user via `db_execute()`, checks the
   password with `security.verify_password()` (bcrypt comparison against
   the stored hash - the real password is never stored anywhere).
4. On success, `security.create_session_cookie()` signs `{user_id, email,
   nickname}` into a cookie; the response sets it and returns
   `{"ok": true}`.
5. Every later request from that browser (e.g. `GET /api/auth/me`, the
   `/ws` connection) carries that cookie, and `security.get_session()`
   verifies its signature to know who's asking - no database lookup
   needed just to check "are you logged in."

---

## Database (Postgres)

- Runs as a **separate, self-managed cluster** at `backend/pgdata`, port
  **5433**. (There's also an unrelated Windows service,
  `postgresql-x64-17`, installed on this machine on the default port
  5432 - it is not used by this app; ignore it.)
- Schema is built from six numbered files in `backend/migrations/`,
  applied in order: `001_initial_schema.sql` (users table),
  `002_email_auth.sql` (verification/reset tokens), 
  `003_nicknames_history_and_stats.sql` (nicknames, password history,
  game results), `004_bot_accounts.sql` (synthetic bot user rows so bot
  games can be recorded like any other game), `005_connect4_results.sql`
  (Connect Four's own results table, deliberately separate from
  `game_results` rather than adding a "game type" column to it),
  `006_ludo_results.sql` (Ludo's results table - one row per participant
  per finished round, grouped by an app-generated `round_id` rather than a
  DB sequence/extension, since a round can have 2-4 participants instead
  of exactly 2).
- Tables: `users`, `password_history`, `email_verification_tokens`,
  `password_reset_tokens`, `game_results` (Tic Tac Toe), `connect4_results`
  (Connect Four), `ludo_results` (Ludo). All three games' result tables
  are independent - same `users` foreign keys, no shared rows.
- The backend never opens a raw connection per-request - `db.py` keeps a
  small pool open and hands connections out as needed.

---

## Frontend (`frontend/`)

Plain HTML/CSS/vanilla JS, no framework, no build step, no bundler. Caddy
serves these files exactly as they sit on disk.

| Folder | Contents |
|---|---|
| `frontend/pages/` | The 9 full HTML documents: `login.html`, `signup.html`, `forgot-password.html`, `reset-password.html`, `games.html` (the post-login hub), `index.html` (the tic-tac-toe board), `connect4.html` (the Connect Four board), `ludo.html` (the Ludo board), `court-piece.html` (the Court Piece config menu + card table) |
| `frontend/static/css/` | `style.css` (shared design system - colors, buttons, dark mode) plus one override file per page that needs extra styling: `login.css`, `games.css`, `tic-tac-toe.css`, `connect4.css`, `ludo.css`, `court-piece.css` |
| `frontend/static/js/` | One script per page (`login.js`, `signup.js`, `forgot-password.js`, `reset-password.js`, `tic-tac-toe.js`, `connect4.js`, `ludo.js` - each game's WebSocket client and board rendering, with no code shared between games), plus `auth-guard.js` (shared by every game page) and Court Piece's three-file split - `court-piece-engine.js`, `court-piece-room.js`, `court-piece-ui.js` (see "Court Piece is different" below) |

`auth-guard.js` is the piece that replaced server-side page protection:
on page load it calls `GET /api/auth/me`; if the answer is "not logged
in," it redirects the browser to `/login.html` with JavaScript. Because
this check happens *after* the page has already loaded (unlike the old
design, where the backend itself refused to send the page), there's a
brief flash of the page before the redirect fires for anyone not logged
in - a known, accepted tradeoff of making the frontend fully static.

### Court Piece is different: no backend at all

Every other game (Tic Tac Toe, Connect Four, Ludo) is a thin frontend
talking to a real backend module over `/ws` - the backend holds the
authoritative game state, and two browsers see the same match. Court
Piece does not do this. It's a self-contained client-side simulation:

- **No WebSocket, no route, no database table.** `court-piece.html` never
  calls `/api/*` or opens a socket - the whole game (rules, AI, "room"
  system) runs in the browser tab that loaded it.
- **The "Private Online Room" is a mock**, explicitly per spec
  ("Simulated Mock-Network Logic") - `court-piece-room.js` generates a
  fake room code and simulates other guests/spectators joining via
  `setTimeout`, all within the same tab. There is no way for a second
  real browser to join a Court Piece room; the room code is decorative.
  Every non-local seat, whether labeled a "guest" or shown as `[BOT]`, is
  actually driven by the same bot AI in `court-piece-engine.js` - there's
  no other real player to drive it.
- **Fog-of-war is a rendering rule, not a security boundary.** When one
  human controls two seats (their own partnership), the "hidden" seat's
  cards are simply not drawn - since everything runs in one page's
  JavaScript, a determined user could inspect `roundState` in devtools
  and see both hands anyway. This is adequate for its actual purpose
  (preventing a slip during normal play), the same way the plain
  local-mode "watch 4 bots" option is adequate without being adversarial.
- **Split into three files on purpose** (`court-piece-engine.js` /
  `court-piece-room.js` / `court-piece-ui.js`) so the rules engine and
  room simulation stay independently readable and testable - both are
  plain functions with no DOM access, written as dual Node/browser
  modules (`module.exports` under Node, `window.X` in the browser), and
  have their own Node-run test suites covering dealing, follow-suit
  legality, trick resolution, the "Double Sar" collection rule, bot trick-
  play, seat handoff, and FIFO spectator promotion. `court-piece-ui.js` is
  the only one of the three that touches `document` - it renders state and
  dispatches clicks, with no rules logic of its own.

---

## Everything outside the app itself

- **Email**: Gmail SMTP with an App Password (`backend/email_utils.py`),
  used only for signup verification and password-reset links.
- **DNS**: `alaab.ai`'s DNS record lives in Cloudflare. A Windows
  Scheduled Task (`TicTacToe-DDNS-Update`) runs `infra/ddns_update.py`
  every 5 minutes, checks this laptop's current public IP, and updates
  the Cloudflare record if it changed - this is what keeps the domain
  pointed at the right place even though a home internet connection's
  public IP isn't fixed.
- **Router**: forwards ports 80 and 443 from the internet to this
  laptop's LAN IP, and reserves that LAN IP for this laptop's network
  card via DHCP so the port forward never goes stale.

Full detail on all three (including the exact router settings) is in
`deployment guide.txt` section 1.

---

## Complete file inventory

```
backend/
  main.py              FastAPI app + router wiring
  config.py             Env/config constants
  db.py                  Postgres connection pool + query helper
  security.py             Password hashing, session cookies
  email_utils.py            Gmail SMTP sending
  auth_routes.py              /api/auth/* (see endpoint table above)
  stats_routes.py               /api/stats (Tic Tac Toe)
  game.py                         /ws, tic-tac-toe rules, bot AI
  connect4_stats_routes.py          /api/connect4/stats
  connect4.py                         /ws/connect4, Connect Four rules, bot AI
  ludo_stats_routes.py                  /api/ludo/stats
  ludo.py                                  /ws/ludo, Ludo rules, bot AI
  requirements.txt                           Python dependencies
  migrations/                                  Numbered SQL schema files, 001-006
  .env                                            Real secrets (gitignored, not in repo)
  .env.example                                      Template for .env
  pgdata/                                              Postgres data directory (gitignored)
  pglog.txt, uvicorn.log                                 Runtime logs (gitignored)

frontend/
  pages/            9 HTML documents (see table above)
  static/css/        7 stylesheets
  static/js/           11 scripts (includes Court Piece's engine/room/ui split - no backend calls)

infra/
  Caddyfile          Routing config (see Caddy section above)
  ddns_update.py      Cloudflare DDNS updater
  .env                  Real Cloudflare credentials (gitignored)
  .env.example           Template for .env
  caddy.log, ddns_update.log   Runtime logs (gitignored)

deploy.py         Status/start/stop/restart helper for Postgres, uvicorn, Caddy
README.md          Project overview, setup instructions
deployment guide.txt Full ops manual: commands, process management, cloud migration plan
ARCHITECTURE.md       This file
```

---

## Commands reference

This is a condensed cheat-sheet. For the exhaustive version - exact
cmd.exe syntax, how to check/kill processes manually, and what each
command's output looks like - see `deployment guide.txt` sections 4-7.

**Easiest path - the automation script, from the repo root:**
```
python deploy.py status      # is Postgres/uvicorn/Caddy running? which PIDs?
python deploy.py start       # start whichever of the three isn't running
python deploy.py stop        # stop all three (Postgres gracefully via pg_ctl)
python deploy.py restart     # stop, then start - use this after any code change
```

**Manual equivalent, one command per piece (three separate terminals):**
```
cd backend
"C:\Program Files\PostgreSQL\17\bin\pg_ctl.exe" -D pgdata -l pglog.txt start

cd backend
python -m uvicorn main:app --host 0.0.0.0 --port 8000

cd infra
"%LOCALAPPDATA%\Microsoft\WinGet\Links\caddy.exe" run --config Caddyfile
```

**Verifying it's actually working:**
```
curl http://localhost:8080/api/auth/me         # {"authenticated": false} when logged out
curl -o NUL -w "%{http_code}" http://localhost:8080/login.html   # 200
curl -o NUL -w "%{http_code}" https://alaab.ai/login.html        # 200
```

**Checking what's running without deploy.py** (from cmd.exe):
```
netstat -ano | findstr ":8000 "     # uvicorn
netstat -ano | findstr ":5433 "     # postgres
netstat -ano | findstr ":443 "      # caddy (also serves :80 and :8080)
tasklist /FI "PID eq <pid>"         # confirm what a PID actually is
```
