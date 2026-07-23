# GameHub (Multiplayer Tic Tac Toe)

A real-time multiplayer game platform with email-based accounts, starting with Tic Tac Toe. Built with FastAPI (WebSockets) on the backend and plain HTML/CSS/vanilla JS on the frontend - no frontend framework or build step. Backend and frontend are two independently deployable services: the backend is a pure JSON + WebSocket API (no HTML), and the frontend is fully static files that call it - see "Architecture" below.

## Features

- Email signup with verification link, login, logout
- Forgot password flow (emailed reset link) with password-reuse prevention (a password can never be reused once changed)
- Unique display nickname chosen at signup - shown to other players instead of your email
- Game hub after login (`/games`) - a card grid to pick a game, ready for more games to be added later
- Tic Tac Toe: join a random opponent, create/join a private game behind a shared 5-character code, or play a bot
- Connect Four: same random/private/bot matchmaking as Tic Tac Toe, on a 7x6 gravity board - its own backend module, WebSocket endpoint, and results table, kept fully independent of Tic Tac Toe's code
- Ludo: 2-4 players racing 4 tokens each around a shared board (dice rolls, captures, home stretches) - random/private games support 2-4 human players with turn order skipping empty seats; "vs Bot" mode is always 1 human + 3 bots. Its own backend module, WebSocket endpoint, and results table (one row per participant per round, since a Ludo round can have more than 2 players)
- Court Piece: 4-player trick-taking card game, fixed partnerships (P1+P3 vs P2+P4), with a "Double Sar" consecutive-trick-win collection rule. Entirely client-side (no backend/database involvement, unlike the other three games) - local play against bots with strict seat-control guardrails (at least 2 seats always bot-controlled; a human may control one seat or their own partnership's two seats, never one from each team) plus fog-of-war hiding a human's second seat except on its own turn, or a simulated "Private Online Room" (mocked multiplayer/spectator system, no real network)
- Bot opponents with 3 difficulty levels per game - Easy (random), Medium (win/block heuristic), Hard (minimax search for Tic Tac Toe/Connect Four - depth-limited with a heuristic evaluation for Connect Four, since a full search tree is too large to solve outright; Ludo's "hard" bot is a greedy heuristic instead, since dice randomness makes deep search largely pointless). Court Piece's bots always follow suit and try to win the trick, independent of the difficulty concept used elsewhere
- Any number of games can run concurrently; each Tic Tac Toe/Connect Four game is capped at exactly 2 players (or 1 player + bot); each Ludo game supports up to 4 players (or 1 player + 3 bots); Court Piece is always exactly 4 seats (1-2 human, rest bot-controlled)
- Live board, turn indicator, win/draw detection, running score per game
- Persistent per-player stats (games/wins/losses/draws) per game, filterable by "All Games", "Random Games" (combined), a specific private-game opponent, or a specific bot difficulty

## Stack

- **Backend**: FastAPI + WebSockets, Python - a pure JSON/WebSocket API. Serves no HTML or static assets.
- **Database**: PostgreSQL (accounts, password history, email verification/reset tokens, game results)
- **Email**: Gmail SMTP (via an App Password)
- **Frontend**: Raw HTML/CSS/vanilla JS, fully static files - no framework, no build step. Talks to the backend exclusively via `fetch()` (`/api/...`) and WebSocket (`/ws`).
- **Reverse proxy** (`infra/Caddyfile`): sits in front of both. Routes `/api/*` and `/ws` to the backend process; serves everything else as static files straight from `frontend/`. This keeps browser requests same-origin (no CORS, no cross-site cookies needed) while backend and frontend remain two separate processes you can run, restart, or eventually host independently.
- **Deployment tooling** (`infra/`): Caddy (reverse proxy + automatic HTTPS) and a Cloudflare Dynamic DNS updater, for running this from a home server behind a normal residential IP

## Architecture

```
Browser
  |
  |  https://alaab.ai/...          (one origin, no CORS)
  v
Caddy  (infra/Caddyfile)
  |-- /api/*, /ws, /ws/connect4, /ws/ludo  -->  backend (uvicorn, :8000)   JSON + WebSocket only
  `-- everything else -->  frontend/  (static files, file_server)
```

The backend has no idea the frontend exists (no HTML responses, no page
routes, no session-gated redirects) - it just checks the session cookie on
each request via `security.get_session()`. The frontend has no idea the
backend is Python (no page ever waits on a server-side redirect) - each
protected page (`games.html`, `index.html`) calls `GET /api/auth/me` on
load via `frontend/static/js/auth-guard.js` and redirects to `/login.html`
client-side if unauthenticated. Auth forms (`login.html`, `signup.html`,
etc.) submit via `fetch()` to `/api/auth/...` and branch on the JSON
response instead of a server-side redirect.

## Project structure

Backend and frontend are fully separate top-level directories with no
shared files - the backend never reads from or serves `frontend/`.

```
.
├── backend/
│   ├── main.py              Thin FastAPI entrypoint - creates the app, mounts routers
│   ├── config.py            Env loading, constants (DB config, session config, regex patterns, bot accounts)
│   ├── db.py                 Postgres connection pool + query helper
│   ├── security.py            Password hashing, tokens, session cookies
│   ├── email_utils.py          Gmail SMTP sending, base-URL helper
│   ├── auth_routes.py           JSON API under /api/auth: signup, login, logout, /me, email verification, password reset
│   ├── stats_routes.py           /api/stats (Tic Tac Toe)
│   ├── game.py                     Tic-tac-toe engine, bot AI (minimax), and the /ws WebSocket handler
│   ├── connect4_stats_routes.py       /api/connect4/stats
│   ├── connect4.py                     Connect Four engine (gravity board, bot AI), and the /ws/connect4 WebSocket handler - fully separate from game.py, no shared state or code
│   ├── ludo_stats_routes.py              /api/ludo/stats
│   ├── ludo.py                             Ludo engine (2-4 player board, dice, captures, bot AI), and the /ws/ludo WebSocket handler - fully separate from game.py and connect4.py, no shared state or code
│   ├── requirements.txt
│   ├── migrations/                 Numbered SQL migrations, applied in order
│   │   ├── 001_initial_schema.sql
│   │   ├── 002_email_auth.sql
│   │   ├── 003_nicknames_history_and_stats.sql
│   │   ├── 004_bot_accounts.sql
│   │   ├── 005_connect4_results.sql
│   │   └── 006_ludo_results.sql
│   └── .env.example                Template for required environment variables
├── frontend/
│   ├── pages/                      Full HTML documents - static files, no backend involvement to serve them
│   │   ├── games.html                  Game-selection hub (post-login landing page)
│   │   ├── index.html                  Tic-tac-toe lobby + board
│   │   ├── login.html
│   │   ├── signup.html
│   │   ├── forgot-password.html
│   │   ├── reset-password.html
│   │   ├── connect4.html               Connect Four lobby + board
│   │   ├── ludo.html                     Ludo lobby + board
│   │   └── court-piece.html                Court Piece config menu + card table (no backend calls at all - purely client-side)
│   └── static/                     Mounted at /static - assets only, no page markup
│       ├── css/
│       │   ├── style.css               Shared design system (colors, buttons, panels, dark mode)
│       │   ├── login.css                Page-specific overrides
│       │   ├── games.css
│       │   ├── tic-tac-toe.css
│       │   ├── connect4.css
│       │   ├── ludo.css
│       │   └── court-piece.css
│       └── js/
│           ├── auth-guard.js           Shared: requireAuth() page gate + logout(), used by every game page
│           ├── login.js
│           ├── signup.js
│           ├── forgot-password.js
│           ├── reset-password.js
│           ├── tic-tac-toe.js          WebSocket client, board rendering, stats panel
│           ├── connect4.js             Same role as tic-tac-toe.js, for Connect Four - no shared code between the two
│           ├── ludo.js                 Same role, for Ludo - dice roll/move UI, 52-cell path + yard/home rendering
│           ├── court-piece-engine.js   Court Piece rules + bot AI - pure logic, no DOM access, dual Node/browser module (has its own test suite run under Node)
│           ├── court-piece-room.js     Court Piece's mock "Private Online Room" simulation - seat/spectator bookkeeping only, no card-game rules
│           └── court-piece-ui.js       Court Piece DOM rendering + event wiring - ties the engine and room modules to the page
├── infra/
│   ├── Caddyfile             Path-routes /api/* and /ws to the backend; serves frontend/ as static files for everything else
│   ├── ddns_update.py         Keeps a Cloudflare DNS A record pointed at this machine's current public IP
│   └── .env.example           Template for Cloudflare API credentials
├── deploy.py             Windows helper: status/start/stop/restart for Postgres, uvicorn, and Caddy
├── deployment guide.txt
└── .gitignore
```

## Setup

1. Install PostgreSQL and create a database/role for the app (or point `.env` at an existing instance).
2. Copy `backend/.env.example` to `backend/.env` and fill in real values:
   - `PG*` - your Postgres connection details
   - `SESSION_SECRET` - generate with `python -c "import secrets; print(secrets.token_urlsafe(32))"`
   - `GMAIL_SENDER` / `GMAIL_APP_PASSWORD` - a Gmail account and an [App Password](https://myaccount.google.com/apppasswords) (requires 2-Step Verification enabled on that account) used to send verification/reset emails
3. Run the schema migrations against your database, in order:
   ```
   psql -f backend/migrations/001_initial_schema.sql
   psql -f backend/migrations/002_email_auth.sql
   psql -f backend/migrations/003_nicknames_history_and_stats.sql
   psql -f backend/migrations/004_bot_accounts.sql
   psql -f backend/migrations/005_connect4_results.sql
   psql -f backend/migrations/006_ludo_results.sql
   ```
4. Install dependencies:
   ```
   cd backend
   python -m pip install -r requirements.txt
   ```
5. Run the backend API:
   ```
   python -m uvicorn main:app --host 0.0.0.0 --port 8000
   ```
6. Run Caddy (from `infra/`) so the frontend is actually served and routed to the API - the backend alone returns no HTML:
   ```
   cd infra
   caddy run --config Caddyfile
   ```
7. Open `http://localhost:8080/signup.html` to create an account (`:8080` is the plain-HTTP local site block in `infra/Caddyfile` - `alaab.ai` is the public one and needs its own DNS/TLS).

`deploy.py` at the repo root automates steps 5-6 (and Postgres) - see "deployment guide.txt".

## Playing over the internet

**Self-hosted on a real domain**: see `infra/` - `Caddyfile` reverse-proxies `/api/*` and `/ws` to the backend and serves `frontend/` directly for everything else, with automatic HTTPS for the domain. `ddns_update.py` (run on a schedule) keeps your DNS pointed at your current public IP if your home connection doesn't have a static one. Requires forwarding ports 80/443 on your router to this machine.

**Quick/casual**: tunnel Caddy's local port instead of the backend's - e.g. `ngrok http 8080` - and share the resulting HTTPS URL. Tunneling port 8000 directly won't work anymore, since the backend alone serves no HTML.
