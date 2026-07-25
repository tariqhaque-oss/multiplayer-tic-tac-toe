# GameHub

A real-time multiplayer game platform with email-based accounts - Tic Tac Toe, Connect Four, Ludo, and Court Piece, playable on the web or the native mobile app. Built with FastAPI (WebSockets) on the backend and plain HTML/CSS/vanilla JS on the frontend - no frontend framework or build step. The backend is a pure JSON + WebSocket API (no HTML) and the frontend is fully static files that call it, but both are packaged into one container and deployed together as a single Cloud Run service - see "Architecture" below.

## Features

- Email signup with verification link, login, logout
- Forgot password flow (emailed reset link) with password-reuse prevention (a password can never be reused once changed)
- Unique display nickname chosen at signup - shown to other players instead of your email
- Game hub after login (`/games`) - a card grid to pick a game, ready for more games to be added later
- Tic Tac Toe: join a random opponent, create/join a private game behind a shared 5-character code, or play a bot
- Connect Four: same random/private/bot matchmaking as Tic Tac Toe, on a 7x6 gravity board - its own backend module, WebSocket endpoint, and results table, kept fully independent of Tic Tac Toe's code
- Ludo: 2-4 players racing 4 tokens each around a shared board (dice rolls, captures, home stretches) - random/private games support 2-4 human players with turn order skipping empty seats; "vs Bot" mode is always 1 human + 3 bots. Its own backend module, WebSocket endpoint, and results table (one row per participant per round, since a Ludo round can have more than 2 players)
- Court Piece: 4-player trick-taking card game, fixed partnerships (P1+P3 vs P2+P4), with a "Double Sar" consecutive-trick-win collection rule. Same random/private/bot matchmaking pattern as the other games, plus its own seat-control guardrails for bot mode (at least 2 seats always bot-controlled; a human may control one seat or their own partnership's two seats, never one from each team) and FIFO spectator promotion in private games (the "first" - i.e. longest-waiting - spectator gets promoted, the opposite of Ludo's "most recent" rule). Fog-of-war is enforced by the backend itself, not just hidden in the UI - a connection is never sent another seat's actual cards, only a count
- Bot opponents with 3 difficulty levels per game - Easy (random), Medium (win/block heuristic), Hard (minimax search for Tic Tac Toe/Connect Four - depth-limited with a heuristic evaluation for Connect Four, since a full search tree is too large to solve outright; Ludo's "hard" bot is a greedy heuristic instead, since dice randomness makes deep search largely pointless). Court Piece's bots have no difficulty tiers at all - one "simple rule-following AI" per its spec (follow suit, try to win the trick, otherwise discard low)
- Any number of games can run concurrently; each Tic Tac Toe/Connect Four game is capped at exactly 2 players (or 1 player + bot); each Ludo game supports up to 4 players (or 1 player + 3 bots); Court Piece is always exactly 4 seats, with bot mode capped at 1-2 human-controlled seats (rest bot-controlled) and random/private modes supporting up to 4 real players (private-mode overflow spectates)
- Live board, turn indicator, win/draw detection, running score per game
- Persistent per-player stats (games/wins/losses/draws) per game, filterable by "All Games", "Random Games" (combined), a specific private-game opponent, or a specific bot difficulty

## Stack

- **Backend**: FastAPI + WebSockets, Python - a pure JSON/WebSocket API. Serves no HTML or static assets.
- **Database**: PostgreSQL (accounts, password history, email verification/reset tokens, game results)
- **Email**: Gmail SMTP (via an App Password)
- **Frontend**: Raw HTML/CSS/vanilla JS, fully static files - no framework, no build step. Talks to the backend exclusively via `fetch()` (`/api/...`) and WebSocket (`/ws`).
- **Reverse proxy** (`Caddyfile`): sits in front of both inside the same Cloud Run container. Routes `/api/*` and the `/ws*` endpoints to the backend process (uvicorn, bound to localhost only); serves everything else as static files straight from `frontend/`. This keeps browser requests same-origin (no CORS, no cross-site cookies needed).
- **Mobile**: a native Flutter app (`mobile/`) talks to the same backend over the same JSON/WebSocket API, with an offline-first mode (SQLite-queued bot games, synced once online) for guests and no-connectivity play.

## Architecture

```
Browser / mobile app
  |
  |  https://alaab.ai/...          (one origin, no CORS)
  v
Caddy  (Caddyfile, inside the Cloud Run container)
  |-- /api/*, /ws, /ws/connect4, /ws/ludo, /ws/court-piece  -->  backend (uvicorn, localhost:8000)   JSON + WebSocket only
  `-- everything else -->  frontend/  (static files, file_server)
```

Deployed as a single container image (backend + frontend + Caddy) on Cloud
Run, backed by Cloud SQL (Postgres) - see `deployment guide to gcp.txt` for
the full walkthrough and `gcloud` commands.

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
shared files or shared code - the backend never reads from or serves
`frontend/` directly (Caddy does that) - even though both end up in the
same container image at build time.

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
│   ├── court_piece_stats_routes.py           /api/court-piece/stats
│   ├── court_piece.py                          Court Piece engine (trick-taking, trump, "Double Sar"), a rule-following bot AI, and the /ws/court-piece WebSocket handler - broadcasts a different payload per connection so fog-of-war is enforced server-side, not just hidden in the UI
│   ├── requirements.txt
│   ├── migrations/                 Numbered SQL migrations, applied in order
│   │   ├── 001_initial_schema.sql
│   │   ├── 002_email_auth.sql
│   │   ├── 003_nicknames_history_and_stats.sql
│   │   ├── 004_bot_accounts.sql
│   │   ├── 005_connect4_results.sql
│   │   ├── 006_ludo_results.sql
│   │   └── 007_court_piece_results.sql
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
│   │   └── court-piece.html                Court Piece config menu + card table
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
│           └── court-piece-ui.js       Same role, for Court Piece - renders whatever per-connection state the server sends, no rules logic of its own
├── mobile/                     Native Flutter app (Android) - same backend, same JSON/WebSocket API, plus an offline-first mode for guests/no-connectivity play
│   ├── lib/
│   │   ├── api/                    HTTP + WebSocket clients (api_client.dart, game_socket.dart)
│   │   ├── engine/                    Pure-Dart ports of each game's rules/bot AI, used only for offline play
│   │   ├── screens/                      One screen per game, plus auth/hub/stats screens
│   │   └── storage/                        SQLite offline-results queue + multi-account session store
│   └── android/                Keystore-signed release config (see mobile/android/key.properties, gitignored)
├── Caddyfile                Path-routes /api/* and /ws* to the backend; serves frontend/ as static files for everything else - baked into the Cloud Run container
├── docker-entrypoint.sh     Starts uvicorn + Caddy inside the container, with a readiness wait so Cloud Run doesn't route traffic before uvicorn is up
├── Dockerfile, .dockerignore       Container image for the Cloud Run deployment
├── deployment guide to gcp.txt   Full Cloud Run + Cloud SQL deploy walkthrough
└── .gitignore
```

## Setup

This runs as a single container on Cloud Run, backed by Cloud SQL - see
`deployment guide to gcp.txt` for the full walkthrough (project setup,
`gcloud` commands, secrets, custom domain). Broad strokes:

1. Create a Cloud SQL Postgres instance and run the schema migrations against it, in order:
   ```
   psql -f backend/migrations/001_initial_schema.sql
   psql -f backend/migrations/002_email_auth.sql
   psql -f backend/migrations/003_nicknames_history_and_stats.sql
   psql -f backend/migrations/004_bot_accounts.sql
   psql -f backend/migrations/005_connect4_results.sql
   psql -f backend/migrations/006_ludo_results.sql
   psql -f backend/migrations/007_court_piece_results.sql
   ```
2. Set `SESSION_SECRET`, `GMAIL_SENDER`, `GMAIL_APP_PASSWORD`, and the `PG*` connection details as Cloud Run env vars / Secret Manager entries (see `backend/.env.example` for the full list).
3. Build and deploy the container:
   ```
   gcloud builds submit --tag <artifact-registry-image> --project=<project>
   gcloud run deploy gamehub --image=<artifact-registry-image> --region=<region> --project=<project>
   ```

For the mobile app, see `mobile/` - `flutter build appbundle --release` produces the Play Console upload, signed with the keystore at `mobile/android/app/android.keystore` (gitignored, back it up separately).
