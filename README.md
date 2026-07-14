# GameHub (Multiplayer Tic Tac Toe)

A real-time multiplayer game platform with email-based accounts, starting with Tic Tac Toe. Built with FastAPI (WebSockets) on the backend and plain HTML/CSS/vanilla JS on the frontend - no frontend framework or build step.

## Features

- Email signup with verification link, login, logout
- Forgot password flow (emailed reset link) with password-reuse prevention (a password can never be reused once changed)
- Unique display nickname chosen at signup - shown to other players instead of your email
- Game hub after login (`/games`) - a card grid to pick a game, ready for more games to be added later
- Tic Tac Toe: join a random opponent, create/join a private game behind a shared 5-character code, or play a bot
- Bot opponent with 3 difficulty levels - Easy (random), Medium (win/block heuristic), Hard (minimax search - provably never loses)
- Any number of games can run concurrently; each game is capped at exactly 2 players (or 1 player + bot)
- Live board, turn indicator, win/draw detection, running score per game
- Persistent per-player stats (games/wins/losses/draws), filterable by "All Games", "Random Games" (combined), a specific private-game opponent, or a specific bot difficulty

## Stack

- **Backend**: FastAPI + WebSockets, Python
- **Database**: PostgreSQL (accounts, password history, email verification/reset tokens, game results)
- **Email**: Gmail SMTP (via an App Password)
- **Frontend**: Raw HTML/CSS/vanilla JS served as static files - no framework, no build step
- **Deployment tooling** (`infra/`): Caddy (reverse proxy + automatic HTTPS) and a Cloudflare Dynamic DNS updater, for running this from a home server behind a normal residential IP

## Project structure

```
.
├── backend/
│   ├── main.py              Thin FastAPI entrypoint - creates the app, mounts routers
│   ├── config.py            Env loading, constants (DB config, session config, regex patterns, bot accounts)
│   ├── db.py                 Postgres connection pool + query helper
│   ├── security.py            Password hashing, tokens, session cookies
│   ├── email_utils.py          Gmail SMTP sending, base-URL helper
│   ├── auth_routes.py           Signup, login, logout, email verification, password reset
│   ├── page_routes.py            Home / games hub / tic-tac-toe page routes
│   ├── stats_routes.py            /api/stats
│   ├── game.py                     Tic-tac-toe engine, bot AI (minimax), and the /ws WebSocket handler
│   ├── requirements.txt
│   ├── migrations/                 Numbered SQL migrations, applied in order
│   │   ├── 001_initial_schema.sql
│   │   ├── 002_email_auth.sql
│   │   ├── 003_nicknames_history_and_stats.sql
│   │   └── 004_bot_accounts.sql
│   ├── .env.example                Template for required environment variables
│   └── static/
│       ├── style.css                   Shared design system (colors, buttons, panels, dark mode)
│       ├── games.html                  Game-selection hub (post-login landing page)
│       ├── index.html                  Tic-tac-toe lobby + board
│       ├── login.html
│       ├── signup.html
│       ├── forgot-password.html
│       └── reset-password.html
├── infra/
│   ├── Caddyfile             Reverse proxy config (automatic Let's Encrypt HTTPS)
│   ├── ddns_update.py         Keeps a Cloudflare DNS A record pointed at this machine's current public IP
│   └── .env.example           Template for Cloudflare API credentials
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
   ```
4. Install dependencies:
   ```
   cd backend
   python -m pip install -r requirements.txt
   ```
5. Run the server:
   ```
   python -m uvicorn main:app --host 0.0.0.0 --port 8000
   ```
6. Open `http://localhost:8000/signup` to create an account.

## Playing over the internet

**Quick/casual**: expose port 8000 with a tunnel (e.g. `ngrok http 8000`) and share the resulting HTTPS URL. Each person signs up/logs in with their own email, then picks a game from the hub.

**Self-hosted on a real domain**: see `infra/` - a Caddyfile reverse-proxies your domain to the app with automatic HTTPS, and `ddns_update.py` (run on a schedule) keeps your DNS pointed at your current public IP if your home connection doesn't have a static one. Requires forwarding ports 80/443 on your router to this machine.
